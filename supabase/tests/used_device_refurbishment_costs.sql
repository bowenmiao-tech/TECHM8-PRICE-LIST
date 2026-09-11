-- Refurbishment costs and below-cost pricing.
-- Run against the staff/POS project. Every fixture write is rolled back.
begin;
do $test$
declare
  token text := extensions.gen_random_uuid()::text;
  staff_id_value bigint;
  staff_name_value text;
  store_id_value bigint;
  store_code_value text;
  shift_code_value text := 'TEST-SHIFT-' || extensions.gen_random_uuid()::text;
  intake_key_value uuid := extensions.gen_random_uuid();
  imei_value text := '99' || lpad((floor(random() * 10000000000000)::bigint)::text, 13, '0');
  cost_id uuid := extensions.gen_random_uuid();
  result jsonb;
  device_code_value text;
  refused boolean;
  refusal text;
  ledger jsonb;
  costs jsonb;
begin
  select staff.id, staff.display_name, store.id, store.store_code
    into staff_id_value, staff_name_value, store_id_value, store_code_value
    from public.staff_directory staff
    join public.store_locations store on store.id = staff.default_store_id
    where staff.active and store.active and store.store_code <> 'warehouse'
    limit 1;

  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
    values (staff_id_value, extensions.crypt(token, extensions.gen_salt('bf')),
            encode(extensions.digest(token, 'sha256'), 'hex'), now() + interval '5 minutes');
  insert into public.pos_store_shifts(shift_code, store_id, business_date, status, opened_by, current_staff_name, last_staff_name)
    values (shift_code_value, store_id_value, current_date, 'open', staff_name_value, staff_name_value, staff_name_value);
  insert into public.pos_used_device_intake_uploads(id, store_id, intake_key, stage, storage_path, author)
  select extensions.gen_random_uuid(), store_id_value, intake_key_value, 'intake',
         store_id_value || '/' || intake_key_value || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value
  from generate_series(1, 3);

  result := public.create_pos_used_device_acquisition(token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'shift_id', shift_code_value,
    'intake_key', intake_key_value::text,
    'seller_name', 'Cost Regression Seller', 'seller_phone', '0400000000', 'seller_address', '1 Test Street',
    'seller_id_type', 'Driver Licence', 'seller_id_reference', 'TEST-000', 'seller_age_confirmed', 'true',
    'seller_is_owner', 'true', 'ownership_declaration', 'true',
    'category', 'Phone', 'brand', 'Apple', 'model', 'iPhone 13', 'storage', '128GB', 'imei', imei_value,
    'condition_grade', 'Good', 'clean_check_status', 'Pending', 'purchase_cost', '300',
    'sale_price', '500', 'payout_method', 'Cash'));
  device_code_value := result#>>'{device,device_code}';
  assert (result#>>'{device,total_cost}')::numeric = 300, 'A new device should cost only its purchase price';

  perform public.add_pos_used_device_cost(token, store_code_value, device_code_value, jsonb_build_object(
    'id', cost_id::text, 'kind', 'part', 'description', 'Replacement screen', 'amount', '120'));
  perform public.add_pos_used_device_cost(token, store_code_value, device_code_value, jsonb_build_object(
    'id', extensions.gen_random_uuid()::text, 'kind', 'labour', 'description', 'Bench time', 'amount', '40'));

  -- A retry of the same cost ID must not charge the device twice.
  perform public.add_pos_used_device_cost(token, store_code_value, device_code_value, jsonb_build_object(
    'id', cost_id::text, 'kind', 'part', 'description', 'Replacement screen', 'amount', '120'));
  costs := public.get_pos_used_device_costs(token, store_code_value, device_code_value);
  assert jsonb_array_length(costs->'costs') = 2, 'A repeated cost ID was recorded twice';
  assert (costs->>'refurb_cost')::numeric = 160, 'Refurbishment cost did not add up';

  -- Below the 460 this device has now cost, with no reason given.
  refused := false;
  begin
    perform public.update_pos_used_device(token, jsonb_build_object(
      'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
      'sale_price', '420'));
  exception when others then refused := true; refusal := sqlerrm;
  end;
  assert refused, 'A below-cost price was accepted without a reason';
  assert refusal like '%below the 460.00%', format('Unexpected refusal: %s', refusal);

  result := public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'sale_price', '420', 'below_cost_reason', 'Screen still has a mark, clearing it'));
  assert (result#>>'{device,total_cost}')::numeric = 460, 'Total cost did not include the repairs';
  assert (result#>>'{device,refurb_cost}')::numeric = 160, 'Refurbishment cost was not reported';

  select ledger.transaction_payload into ledger
    from public.pos_used_device_transactions ledger
    join public.pos_used_devices device on device.id = ledger.device_id
    where device.device_code = device_code_value and ledger.transaction_type = 'price_change'
    order by ledger.id desc limit 1;
  assert (ledger->>'below_cost')::boolean, 'The ledger did not record that the price was below cost';
  assert ledger->>'below_cost_reason' = 'Screen still has a mark, clearing it', 'The reason was not recorded';

  -- An unrelated update must not be blocked by the now under-water price.
  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'notes', 'Waiting on a back cover'));

  raise notice 'used_device_refurbishment_costs: all checks passed';
end;
$test$;
rollback;
