-- The ready-for-sale gate against the per-category checklist.
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
  result jsonb;
  device_code_value text;
  device_id_value bigint;
  refused boolean;
  full_answers jsonb;
  checklists jsonb;
  phone_items integer;
begin
  select count(*) into phone_items
  from public.pos_used_device_inspection_items where category = 'Phone' and active;
  assert phone_items = 23, format('The phone checklist has %s items, expected 23', phone_items);

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

  -- Intake evidence is required once 20260910235000 is applied.
  insert into public.pos_used_device_intake_uploads(id, store_id, intake_key, stage, storage_path, author)
  select extensions.gen_random_uuid(), store_id_value, intake_key_value, 'intake',
         store_id_value || '/' || intake_key_value || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value
  from generate_series(1, 3);

  result := public.create_pos_used_device_acquisition(token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'shift_id', shift_code_value,
    'intake_key', intake_key_value::text,
    'seller_name', 'Checklist Regression Seller', 'seller_phone', '0400000000',
    'seller_address', '1 Test Street', 'seller_id_type', 'Driver Licence', 'seller_id_reference', 'TEST-000',
    'seller_age_confirmed', 'true', 'seller_is_owner', 'true', 'ownership_declaration', 'true',
    'category', 'Phone', 'brand', 'Apple', 'model', 'iPhone 13', 'storage', '128GB',
    'imei', imei_value, 'condition_grade', 'Good', 'clean_check_status', 'Pending',
    'purchase_cost', '300', 'sale_price', '500', 'payout_method', 'Cash'));
  device_code_value := result#>>'{device,device_code}';
  select id into device_id_value from public.pos_used_devices where device_code = device_code_value;

  insert into public.pos_used_device_updates(id, device_id, kind, stage, storage_path, author)
  values (extensions.gen_random_uuid(), device_id_value, 'photo', 'listing',
          store_id_value || '/' || device_id_value || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value);

  -- Eight passes used to be enough for a twenty-three item phone checklist.
  refused := false;
  begin
    perform public.update_pos_used_device(token, jsonb_build_object(
      'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
      'status', 'ready_for_sale', 'clean_check_status', 'Clean', 'clean_check_reference', 'AMTA-TEST',
      'activation_lock_removed', 'true', 'data_erased_confirmed', 'true',
      'inspection', jsonb_build_object('power','pass','touch','pass','display_lcd','pass','back_glass','pass',
        'housing','pass','power_button','pass','volume_buttons','pass','vibrate','pass')));
  exception when others then refused := true;
  end;
  assert refused, 'Eight answers still shelved a twenty-three item phone';

  select jsonb_object_agg(item.item_key, 'pass') into full_answers
  from public.pos_used_device_inspection_items item where item.category = 'Phone' and item.active;

  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'status', 'ready_for_sale', 'clean_check_status', 'Clean', 'clean_check_reference', 'AMTA-TEST',
    'activation_lock_removed', 'true', 'data_erased_confirmed', 'true', 'inspection', full_answers));
  assert (select status = 'ready_for_sale' from public.pos_used_devices where device_code = device_code_value),
    'A fully answered checklist could not be shelved';

  -- One failed item is enough to take it back off the shelf.
  refused := false;
  begin
    perform public.update_pos_used_device(token, jsonb_build_object(
      'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
      'status', 'ready_for_sale', 'inspection', full_answers || jsonb_build_object('rear_camera', 'fail')));
  exception when others then refused := true;
  end;
  assert refused, 'A failed inspection item was allowed on the shelf';

  checklists := public.get_pos_used_device_inspection_items(token);
  assert jsonb_array_length(checklists#>'{checklists,Phone}') = 23, 'The POS checklist feed is incomplete';
  assert jsonb_array_length(checklists#>'{checklists,Laptop}') = 18, 'The laptop checklist feed is incomplete';

  raise notice 'used_device_inspection_checklist: all checks passed';
end;
$test$;
rollback;
