-- The purchase inspection is locked; the pre-sale test decides sellability.
-- Run against the staff/POS project. Every fixture write is rolled back.
begin;
do $test$
declare
  intake_key_value uuid := extensions.gen_random_uuid();
  token text := extensions.gen_random_uuid()::text;
  staff_id_value bigint;
  staff_name_value text;
  store_id_value bigint;
  store_code_value text;
  shift_code_value text;
  imei_value text := '97' || lpad((floor(random() * 10000000000000)::bigint)::text, 13, '0');
  result jsonb;
  device_code_value text;
  device_id_value bigint;
  purchase_inspection jsonb;
  all_pass jsonb;
  one_fail jsonb;
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
    values (staff_id_value, extensions.crypt(token, extensions.gen_salt('bf')),
            encode(extensions.digest(token, 'sha256'), 'hex'), now() + interval '5 minutes');

  select shift_code into shift_code_value from public.pos_store_shifts
    where store_id = store_id_value and status = 'open' limit 1;
  if shift_code_value is null then
    shift_code_value := 'TEST-SHIFT-' || extensions.gen_random_uuid()::text;
    insert into public.pos_store_shifts(shift_code, store_id, business_date, status, opened_by, current_staff_name, last_staff_name)
      values (shift_code_value, store_id_value, current_date, 'open', staff_name_value, staff_name_value, staff_name_value);
  end if;

  insert into public.pos_used_device_intake_uploads(id,store_id,intake_key,stage,storage_path,author)
  values (extensions.gen_random_uuid(), store_id_value, intake_key_value, 'intake',
    store_id_value||'/'||intake_key_value||'/'||extensions.gen_random_uuid()||'.jpg', staff_name_value);

  select jsonb_object_agg(item_key, 'pass') into all_pass
  from public.pos_used_device_inspection_items where category = 'Phone' and active;
  one_fail := all_pass || jsonb_build_object('touch', 'fail');

  -- Bought with a failed touch screen and a 78% battery.
  result := public.create_pos_used_device_acquisition(token, jsonb_build_object(
    'intake_key', intake_key_value, 'store_code', store_code_value, 'staff_name', staff_name_value,
    'shift_id', shift_code_value, 'seller_name', 'Sale Test Seller', 'seller_phone', '0400000001',
    'seller_address', '1 Test Street', 'seller_id_type', 'Passport', 'seller_id_reference', 'TEST',
    'seller_age_confirmed', 'true', 'seller_is_owner', 'true', 'ownership_declaration', 'true',
    'category', 'Phone', 'brand', 'Apple', 'model', 'iPhone 13', 'storage', '128GB',
    'imei', imei_value, 'condition_grade', 'Faulty', 'battery_health', '78',
    'inspection', jsonb_build_object('touch', 'fail'), 'clean_check_status', 'Clean',
    'activation_lock_removed', 'true', 'data_erased_confirmed', 'true',
    'purchase_cost', '300', 'payout_method', 'Cash', 'status', 'inspection'));
  device_code_value := result#>>'{device,device_code}';
  select id, inspection into device_id_value, purchase_inspection
  from public.pos_used_devices where device_code = device_code_value;

  -- 1. What it was bought as is captured and cannot be rewritten by anyone.
  assert (select intake_condition_grade = 'Faulty' and intake_battery_health = 78
          from public.pos_used_devices where id = device_id_value),
    'The purchase-time condition and battery were not captured';
  refused := false;
  begin
    update public.pos_used_devices set inspection = all_pass where id = device_id_value;
  exception when others then refused := true;
  end;
  assert refused, 'The purchase inspection could be rewritten directly';
  refused := false;
  begin
    update public.pos_used_devices set intake_battery_health = 100 where id = device_id_value;
  exception when others then refused := true;
  end;
  assert refused, 'The purchase-time battery could be rewritten directly';

  -- A save from the shop floor that still sends an inspection is accepted and
  -- ignores it.
  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'notes', 'Screen replaced', 'inspection', all_pass));
  assert (select inspection = purchase_inspection from public.pos_used_devices where id = device_id_value),
    'A device save rewrote the purchase inspection';

  -- 2. Without a pre-sale test the device cannot reach the shelf.
  refused := false;
  begin
    perform public.update_pos_used_device(token, jsonb_build_object(
      'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
      'status', 'ready_for_sale', 'sale_price', '600'));
  exception when others then refused := true; refusal := sqlerrm;
  end;
  assert refused and refusal like '%pre-sale test%', format('Unexpected ready refusal: %s', refusal);

  -- 3. An incomplete run is refused; a complete failing run is kept but does
  --    not make the device sellable.
  refused := false;
  begin
    perform public.record_pos_used_device_sale_test(token, store_code_value, device_code_value,
      jsonb_build_object('answers', jsonb_build_object('touch', 'pass')));
  exception when others then refused := true;
  end;
  assert refused, 'An incomplete pre-sale test was accepted';

  result := public.record_pos_used_device_sale_test(token, store_code_value, device_code_value,
    jsonb_build_object('answers', one_fail));
  assert not (result->>'passed')::boolean, 'A run with a failed check passed';
  assert not public.pos_used_device_sale_test_passed(device_id_value), 'A failed run made the device sellable';

  -- 4. A passing run records the battery measured now, leaves the purchase
  --    record alone, and opens the way to the shelf.
  result := public.record_pos_used_device_sale_test(token, store_code_value, device_code_value,
    jsonb_build_object('answers', all_pass, 'battery_health', '100', 'notes', 'New screen and battery'));
  assert (result->>'passed')::boolean, 'A clean run did not pass';
  assert (select battery_health = 100 and intake_battery_health = 78 and inspection = purchase_inspection
          from public.pos_used_devices where id = device_id_value),
    'The pre-sale test did not keep the purchase record apart from the current state';
  assert (select count(*) = 2 from public.pos_used_device_sale_tests where device_id = device_id_value),
    'Test runs were not all kept';
  assert not exists (
    select 1 from unnest(public.pos_used_device_listing_blockers(device_id_value)) blocker
    where blocker like '%pre-sale test%'
  ), 'A passed device was still blocked on its pre-sale test';

  -- 5. The listing reads the pre-sale test, not the purchase inspection.
  insert into public.pos_used_device_updates(id, device_id, kind, stage, storage_path, author)
  values (extensions.gen_random_uuid(), device_id_value, 'photo', 'listing',
    store_id_value||'/'||device_id_value||'/'||extensions.gen_random_uuid()||'.jpg', staff_name_value);
  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'status', 'ready_for_sale', 'sale_price', '600'));
  assert (select status = 'ready_for_sale' from public.pos_used_devices where id = device_id_value),
    'A tested device could not reach the shelf';

  -- 6. A failed retest takes it straight back off sale.
  result := public.record_pos_used_device_sale_test(token, store_code_value, device_code_value,
    jsonb_build_object('answers', one_fail));
  assert (result->>'withdrawn')::boolean, 'A failed retest left the device on sale';
  assert (select status = 'inspection' from public.pos_used_devices where id = device_id_value),
    'The device is still ready for sale after failing its retest';

  raise notice 'used_device_sale_test: all checks passed';
end;
$test$;
rollback;
