-- The reworked buyback intake: unpriced purchases, per-store buyback numbers,
-- the seller as a customer, and where a bank transfer went.
-- Run against the staff/POS project. Every fixture write is rolled back.
begin;
do $test$
declare
  intake_key_value uuid := extensions.gen_random_uuid();
  second_intake_key uuid := extensions.gen_random_uuid();
  third_intake_key uuid := extensions.gen_random_uuid();
  token text := extensions.gen_random_uuid()::text;
  staff_id_value bigint;
  staff_name_value text;
  store_id_value bigint;
  store_code_value text;
  shift_code_value text;
  seller_phone_value text := '04' || lpad((floor(random() * 100000000)::bigint)::text, 8, '0');
  imei_value text := '99' || lpad((floor(random() * 10000000000000)::bigint)::text, 13, '0');
  second_imei_value text := '98' || lpad((floor(random() * 10000000000000)::bigint)::text, 13, '0');
  base_payload jsonb;
  result jsonb;
  device_code_value text;
  second_device_code text;
  customer_id_value bigint;
  first_number bigint;
  second_number bigint;
  checklist_keys text[];
  refused boolean;
  refusal text;
begin
  select staff.id, staff.display_name, store.id, store.store_code
    into staff_id_value, staff_name_value, store_id_value, store_code_value
    from public.staff_directory staff
    join public.store_locations store on store.id = staff.default_store_id
    where staff.active and store.active and store.store_code <> 'warehouse'
    limit 1;
  if staff_id_value is null then raise exception 'No active staff with a default store'; end if;

  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
    values (
      staff_id_value,
      extensions.crypt(token, extensions.gen_salt('bf')),
      encode(extensions.digest(token, 'sha256'), 'hex'),
      now() + interval '5 minutes'
    );

  select shift_code into shift_code_value from public.pos_store_shifts
    where store_id = store_id_value and status = 'open' limit 1;
  if shift_code_value is null then
    shift_code_value := 'TEST-SHIFT-' || extensions.gen_random_uuid()::text;
    insert into public.pos_store_shifts(shift_code, store_id, business_date, status, opened_by, current_staff_name, last_staff_name)
      values (shift_code_value, store_id_value, current_date, 'open', staff_name_value, staff_name_value, staff_name_value);
  end if;

  -- 1. The phone checklist is the paper list plus wireless charging and the
  --    camera button, and nothing the paper list does not carry.
  select array_agg(item_key order by position) into checklist_keys
  from public.pos_used_device_inspection_items where category = 'Phone' and active;
  assert array_length(checklist_keys, 1) = 21,
    format('Phone checklist has %s items, expected 21', array_length(checklist_keys, 1));
  assert checklist_keys @> array['wireless_charging', 'camera_button']
    and not (checklist_keys && array['power', 'housing', 'battery', 'liquid']),
    format('Unexpected phone checklist: %s', checklist_keys);

  insert into public.pos_used_device_intake_uploads(id,store_id,intake_key,stage,storage_path,author)
  values (extensions.gen_random_uuid(),store_id_value,intake_key_value,'intake',
    store_id_value||'/'||intake_key_value||'/'||extensions.gen_random_uuid()||'.jpg',staff_name_value);

  base_payload := jsonb_build_object(
    'intake_key', intake_key_value,
    'store_code', store_code_value,
    'staff_name', staff_name_value,
    'shift_id', shift_code_value,
    'seller_name', 'Buyback Rework Seller',
    'seller_phone', seller_phone_value,
    'seller_email', 'rework.seller@example.test',
    'seller_address', '1 Test Street, Brisbane',
    'seller_id_type', 'Driver Licence',
    'seller_id_reference', 'TEST-000',
    'seller_age_confirmed', 'true',
    'seller_is_owner', 'true',
    'ownership_declaration', 'true',
    'category', 'Phone',
    'brand', 'Apple',
    'model', 'iPhone 13',
    'storage', '128GB',
    'imei', imei_value,
    'clean_check_status', 'Clean',
    'purchase_cost', '300',
    'payout_method', 'Cash',
    'status', 'inspection'
  );

  -- 2. A purchase saves without a condition, a sale price or a check
  --    reference, and is numbered.
  result := public.create_pos_used_device_acquisition(token, base_payload);
  assert (result->>'ok')::boolean;
  device_code_value := result#>>'{device,device_code}';
  assert (select condition_grade = 'Good' and sale_price = 0
          from public.pos_used_devices where device_code = device_code_value),
    'An unpriced purchase was not stored as Good at zero';
  select acquisition.buyback_number, acquisition.customer_id
    into first_number, customer_id_value
    from public.pos_used_device_acquisitions acquisition
    join public.pos_used_devices device on device.acquisition_id = acquisition.id
    where device.device_code = device_code_value;
  assert first_number is not null and first_number > 0, 'The purchase was not numbered';
  assert (result#>>'{device,acquisition,buyback_number}')::bigint = first_number,
    'The device payload did not carry the buyback number';

  -- 3. The seller is a customer, matched by phone number on the next purchase.
  assert customer_id_value is not null, 'The seller was not recorded as a customer';
  assert (select normalized_phone = regexp_replace(seller_phone_value, '[^0-9]', '', 'g')
          from public.pos_customers where id = customer_id_value),
    'The customer record does not carry the seller phone number';

  insert into public.pos_used_device_intake_uploads(id,store_id,intake_key,stage,storage_path,author)
  values (extensions.gen_random_uuid(),store_id_value,second_intake_key,'intake',
    store_id_value||'/'||second_intake_key||'/'||extensions.gen_random_uuid()||'.jpg',staff_name_value);
  result := public.create_pos_used_device_acquisition(token, base_payload || jsonb_build_object(
    'intake_key', second_intake_key,
    'imei', second_imei_value,
    'model', 'iPhone 14',
    'payout_method', 'Bank Transfer',
    'payout_reference_type', 'PayID',
    'payout_payid', 'rework.seller@example.test'
  ));
  second_device_code := result#>>'{device,device_code}';
  select acquisition.buyback_number into second_number
    from public.pos_used_device_acquisitions acquisition
    join public.pos_used_devices device on device.acquisition_id = acquisition.id
    where device.device_code = second_device_code;
  assert second_number = first_number + 1,
    format('Buyback numbers did not run in sequence: %s then %s', first_number, second_number);
  assert (select count(distinct customer_id) = 1
          from public.pos_used_device_acquisitions
          where buyback_number in (first_number, second_number) and store_id = store_id_value),
    'The same seller was recorded as two customers';

  -- 4. A transfer has to say where the money went.
  insert into public.pos_used_device_intake_uploads(id,store_id,intake_key,stage,storage_path,author)
  values (extensions.gen_random_uuid(),store_id_value,third_intake_key,'intake',
    store_id_value||'/'||third_intake_key||'/'||extensions.gen_random_uuid()||'.jpg',staff_name_value);
  refused := false;
  begin
    perform public.create_pos_used_device_acquisition(token, base_payload || jsonb_build_object(
      'intake_key', third_intake_key,
      'imei', '',
      'serial_number', 'TEST-NO-PAYOUT-' || extensions.gen_random_uuid()::text,
      'payout_method', 'Bank Transfer'
    ));
  exception when others then refused := true; refusal := sqlerrm;
  end;
  assert refused, 'A bank transfer was saved without a destination';

  refused := false;
  begin
    perform public.create_pos_used_device_acquisition(token, base_payload || jsonb_build_object(
      'intake_key', third_intake_key,
      'imei', '',
      'serial_number', 'TEST-SHORT-BSB-' || extensions.gen_random_uuid()::text,
      'payout_method', 'Bank Transfer',
      'payout_reference_type', 'Bank Account',
      'payout_bsb', '12345',
      'payout_account_number', '12345678',
      'payout_account_name', 'Buyback Rework Seller'
    ));
  exception when others then refused := true; refusal := sqlerrm;
  end;
  assert refused, 'A five-digit BSB was accepted';

  -- Only the destination that was chosen is kept.
  assert (select payout_payid = 'rework.seller@example.test'
            and payout_reference_type = 'PayID'
            and payout_bsb = '' and payout_account_number = '' and payout_account_name = ''
          from public.pos_used_device_acquisitions acquisition
          join public.pos_used_devices device on device.acquisition_id = acquisition.id
          where device.device_code = second_device_code),
    'The PayID payout did not store cleanly';

  -- 5. A device cannot reach the shelf unpriced, even once it has passed.
  -- Sellability comes from a pre-sale test, never from the purchase inspection.
  perform public.record_pos_used_device_sale_test(token, store_code_value, device_code_value,
    jsonb_build_object('answers', (select jsonb_object_agg(item_key, 'pass')
      from public.pos_used_device_inspection_items where category = 'Phone' and active)));
  refused := false;
  begin
    perform public.update_pos_used_device(token, jsonb_build_object(
      'store_code', store_code_value,
      'staff_name', staff_name_value,
      'device_code', device_code_value,
      'status', 'ready_for_sale',
      'clean_check_status', 'Clean',
      'activation_lock_removed', 'true',
      'data_erased_confirmed', 'true'
    ));
  exception when others then refused := true; refusal := sqlerrm;
  end;
  assert refused and refusal like '%sale price%', format('An unpriced device reached the shelf: %s', refusal);

  -- Pricing it during inspection is allowed and does not need a status change.
  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value,
    'staff_name', staff_name_value,
    'device_code', device_code_value,
    'sale_price', '500',
    'condition_grade', 'As New'
  ));
  assert (select sale_price = 500 and condition_grade = 'As New'
          from public.pos_used_devices where device_code = device_code_value),
    'The listing step could not price or grade the device';

  -- 6. The customer's buyback history reads back both purchases.
  result := public.get_pos_customer_buybacks(
    token,
    store_code_value,
    (select customer_code from public.pos_customers where id = customer_id_value),
    seller_phone_value,
    100
  );
  assert (result->>'ok')::boolean;
  assert jsonb_array_length(result->'buybacks') = 2,
    format('Customer buyback history returned %s rows', jsonb_array_length(result->'buybacks'));
  assert (result#>>'{buybacks,0,buyback_number}')::bigint = second_number,
    'Customer buyback history is not newest first';
  assert (result#>>'{buybacks,0,devices,0,model}') = 'iPhone 14',
    'Customer buyback history did not carry the device';
  assert not (result->'buybacks'->0) ? 'payout_amount',
    'Customer buyback history exposed what the shop paid';

  raise notice 'buyback_intake_rework: all checks passed';
end;
$test$;
rollback;
