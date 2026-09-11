-- Buyback evidence gates. Run against the staff/POS project.
-- Every fixture write is rolled back.
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
  base_payload jsonb;
  result jsonb;
  device_code_value text;
  device_id_value bigint;
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

  insert into public.pos_store_shifts(shift_code, store_id, business_date, status, opened_by, current_staff_name, last_staff_name)
    values (shift_code_value, store_id_value, current_date, 'open', staff_name_value, staff_name_value, staff_name_value);

  base_payload := jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'shift_id', shift_code_value,
    'seller_name', 'Evidence Regression Seller', 'seller_phone', '0400000000',
    'seller_address', '1 Test Street, Brisbane', 'seller_id_type', 'Driver Licence',
    'seller_id_reference', 'TEST-000', 'seller_age_confirmed', 'true', 'seller_is_owner', 'true',
    'ownership_declaration', 'true', 'category', 'Phone', 'brand', 'Apple', 'model', 'iPhone 13',
    'storage', '128GB', 'imei', imei_value, 'condition_grade', 'Good',
    'clean_check_status', 'Pending', 'purchase_cost', '300', 'sale_price', '500',
    'payout_method', 'Cash'
  );

  -- 1. No intake key at all: the purchase is refused before any money moves.
  refused := false;
  begin
    perform public.create_pos_used_device_acquisition(token, base_payload);
  exception when others then refused := true; refusal := sqlerrm;
  end;
  assert refused, 'A purchase without photo evidence was saved';
  assert refusal like '%Photograph the device%', format('Unexpected refusal: %s', refusal);

  -- 2. Too few intake photos is still refused.
  insert into public.pos_used_device_intake_uploads(id, store_id, intake_key, stage, storage_path, author)
  select extensions.gen_random_uuid(), store_id_value, intake_key_value, 'intake',
         store_id_value || '/' || intake_key_value || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value
  from generate_series(1, 2);

  refused := false;
  begin
    perform public.create_pos_used_device_acquisition(token, base_payload || jsonb_build_object('intake_key', intake_key_value::text));
  exception when others then refused := true; refusal := sqlerrm;
  end;
  assert refused, 'A purchase with two photos was saved';
  assert refusal like '%three intake photos%', format('Unexpected refusal: %s', refusal);

  -- 3. The third photo lets the purchase through, and the photos become this
  --    device's intake evidence.
  insert into public.pos_used_device_intake_uploads(id, store_id, intake_key, stage, storage_path, author)
  values (extensions.gen_random_uuid(), store_id_value, intake_key_value, 'intake',
          store_id_value || '/' || intake_key_value || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value);

  result := public.create_pos_used_device_acquisition(token, base_payload || jsonb_build_object('intake_key', intake_key_value::text));
  device_code_value := result#>>'{device,device_code}';
  select id into device_id_value from public.pos_used_devices where device_code = device_code_value;
  assert result#>>'{device,status}' = 'inspection', 'A purchase did not start in inspection';
  assert (select count(*) = 3 from public.pos_used_device_updates
          where device_id = device_id_value and kind = 'photo' and stage = 'intake'),
    'Intake photos were not attached to the device';
  assert (select count(*) = 0 from public.pos_used_device_intake_uploads
          where intake_key = intake_key_value and claimed_device_id is null),
    'Claimed intake photos are still available to another purchase';

  -- 4. The same photos cannot be claimed by a second purchase.
  refused := false;
  begin
    perform public.create_pos_used_device_acquisition(
      token,
      base_payload || jsonb_build_object(
        'intake_key', intake_key_value::text,
        'imei', '',
        'serial_number', 'TEST-SECOND-' || extensions.gen_random_uuid()::text
      )
    );
  exception when others then refused := true;
  end;
  assert refused, 'Intake photos were reused by a second purchase';

  -- 5. Ready for sale needs a listing photo.
  refused := false;
  begin
    perform public.update_pos_used_device(token, jsonb_build_object(
      'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
      'status', 'ready_for_sale', 'clean_check_status', 'Clean', 'clean_check_reference', 'AMTA-TEST',
      'activation_lock_removed', 'true', 'data_erased_confirmed', 'true',
      'inspection', jsonb_build_object('power','pass','touch','pass','display_lcd','pass','back_glass','pass',
        'housing','pass','power_button','pass','volume_buttons','pass','vibrate','pass')));
  exception when others then refused := true; refusal := sqlerrm;
  end;
  assert refused, 'A device reached the shelf without a listing photo';
  assert refusal like '%listing photo%', format('Unexpected refusal: %s', refusal);

  insert into public.pos_used_device_updates(id, device_id, kind, stage, storage_path, author)
  values (extensions.gen_random_uuid(), device_id_value, 'photo', 'listing',
          store_id_value || '/' || device_id_value || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value);

  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'status', 'ready_for_sale', 'clean_check_status', 'Clean', 'clean_check_reference', 'AMTA-TEST',
    'activation_lock_removed', 'true', 'data_erased_confirmed', 'true',
    'inspection', jsonb_build_object('power','pass','touch','pass','display_lcd','pass','back_glass','pass',
      'housing','pass','power_button','pass','volume_buttons','pass','vibrate','pass')));
  assert (select status = 'ready_for_sale' from public.pos_used_devices where device_code = device_code_value),
    'A photographed device could not be marked ready';

  raise notice 'used_device_evidence: all checks passed';
end;
$test$;
rollback;
