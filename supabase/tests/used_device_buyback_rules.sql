-- Buyback intake and inventory rules. Run against the staff/POS project.
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
  imei_value text := '99' || lpad((floor(random() * 10000000000000)::bigint)::text, 13, '0');
  base_payload jsonb;
  result jsonb;
  device_code_value text;
  first_ready timestamptz;
  refused boolean;
  ledger_note text;
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
    'store_code', store_code_value,
    'staff_name', staff_name_value,
    'shift_id', shift_code_value,
    'seller_name', 'Buyback Regression Seller',
    'seller_phone', '0400000000',
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
    'condition_grade', 'Good',
    'clean_check_status', 'Pending',
    'purchase_cost', '300',
    'sale_price', '500',
    'payout_method', 'Cash',
    'status', 'inspection'
  );

  -- 1. A missing acquisition note is stored as an empty string rather than
  --    breaking on the not-null column.
  result := public.create_pos_used_device_acquisition(token, base_payload);
  assert (result->>'ok')::boolean;
  device_code_value := result#>>'{device,device_code}';
  assert (select acquisition_statement = ''
          from public.pos_used_device_acquisitions acquisition
          join public.pos_used_devices device on device.acquisition_id = acquisition.id
          where device.device_code = device_code_value),
    'Missing acquisition note was not stored as an empty string';

  -- 2. A device that failed the lost-or-stolen check cannot be bought at all.
  refused := false;
  begin
    perform public.create_pos_used_device_acquisition(
      token,
      base_payload
        || jsonb_build_object('clean_check_status', 'Blocked', 'imei', '', 'serial_number', 'TEST-BLOCKED-' || extensions.gen_random_uuid()::text)
    );
  exception when others then refused := true;
  end;
  assert refused, 'A blocked device was still bought';
  assert (select count(*) = 0
          from public.pos_used_devices
          where store_id = store_id_value and clean_check_status = 'Blocked' and acquired_at > now() - interval '1 minute'),
    'A blocked device reached inventory';

  -- 3. `change_note` explains one change without touching the device memo.
  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value,
    'staff_name', staff_name_value,
    'device_code', device_code_value,
    'sale_price', '450',
    'notes', 'Screen has a hairline scratch',
    'change_note', 'Repriced after the market check'
  ));
  select ledger.notes into ledger_note
    from public.pos_used_device_transactions ledger
    join public.pos_used_devices device on device.id = ledger.device_id
    where device.device_code = device_code_value and ledger.transaction_type = 'price_change'
    order by ledger.id desc
    limit 1;
  assert ledger_note = 'Repriced after the market check', 'Price ledger did not use the change note';
  assert (select notes = 'Screen has a hairline scratch' from public.pos_used_devices where device_code = device_code_value),
    'Device memo was overwritten by the change note';

  -- An omitted change note falls back to the standard ledger text instead of
  -- republishing the memo.
  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value,
    'staff_name', staff_name_value,
    'device_code', device_code_value,
    'sale_price', '460'
  ));
  select ledger.notes into ledger_note
    from public.pos_used_device_transactions ledger
    join public.pos_used_devices device on device.id = ledger.device_id
    where device.device_code = device_code_value and ledger.transaction_type = 'price_change'
    order by ledger.id desc
    limit 1;
  assert ledger_note = 'Sale price updated', 'Missing change note did not fall back to the standard text';

  -- 4. `ready_at` is the first time the device reached the shelf and survives a
  --    return to inspection.
  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value,
    'staff_name', staff_name_value,
    'device_code', device_code_value,
    'status', 'ready_for_sale',
    'clean_check_status', 'Clean',
    'clean_check_reference', 'AMTA-TEST',
    'activation_lock_removed', 'true',
    'data_erased_confirmed', 'true',
    'inspection', jsonb_build_object(
      'power', 'pass', 'touch', 'pass', 'display_lcd', 'pass', 'back_glass', 'pass',
      'housing', 'pass', 'power_button', 'pass', 'volume_buttons', 'pass', 'vibrate', 'pass'
    )
  ));
  select ready_at into first_ready from public.pos_used_devices where device_code = device_code_value;
  assert first_ready is not null, 'Ready timestamp was not recorded';

  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value,
    'staff_name', staff_name_value,
    'device_code', device_code_value,
    'status', 'inspection',
    'change_note', 'Back for a second look'
  ));
  assert (select ready_at = first_ready from public.pos_used_devices where device_code = device_code_value),
    'Returning to inspection erased the first ready date';

  raise notice 'used_device_buyback_rules: all checks passed';
end;
$test$;
rollback;
