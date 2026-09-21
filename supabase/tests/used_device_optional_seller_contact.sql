-- A seller's phone and email are optional. Run against the staff/POS project.
-- Every fixture write is rolled back.
begin;
do $test$
declare
  staff_token text := extensions.gen_random_uuid()::text;
  admin_token text := extensions.gen_random_uuid()::text;
  admin_id bigint;
  staff_id_value bigint;
  staff_name_value text;
  store_id_value bigint;
  store_code_value text;
  shift_code_value text;
  id_reference_value text := 'NOPHONE-' || extensions.gen_random_uuid()::text;
  intake_key_value uuid;
  result jsonb;
  base_payload jsonb;
  no_contact_device text;
  email_device text;
  alerts jsonb;
  visit integer;
begin
  select staff.id, staff.display_name, store.id, store.store_code
    into staff_id_value, staff_name_value, store_id_value, store_code_value
    from public.staff_directory staff
    join public.store_locations store on store.id = staff.default_store_id
    where staff.active and store.active and store.store_code <> 'warehouse'
    limit 1;
  select id into admin_id from public.admin_users where active order by id limit 1;
  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
    values (staff_id_value, extensions.crypt(staff_token, extensions.gen_salt('bf')),
            encode(extensions.digest(staff_token, 'sha256'), 'hex'), now() + interval '5 minutes');
  insert into public.admin_sessions(admin_user_id, session_hash, expires_at)
    values (admin_id, extensions.crypt(admin_token, extensions.gen_salt('bf')), now() + interval '5 minutes');
  select shift_code into shift_code_value from public.pos_store_shifts
    where store_id = store_id_value and status = 'open' limit 1;
  if shift_code_value is null then
    shift_code_value := 'TEST-SHIFT-' || extensions.gen_random_uuid()::text;
    insert into public.pos_store_shifts(shift_code, store_id, business_date, status, opened_by, current_staff_name, last_staff_name)
      values (shift_code_value, store_id_value, current_date, 'open', staff_name_value, staff_name_value, staff_name_value);
  end if;

  base_payload := jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'shift_id', shift_code_value,
    'seller_name', 'No Contact Seller', 'seller_address', '1 Test Street',
    'seller_id_type', 'Driver Licence', 'seller_id_reference', id_reference_value,
    'seller_age_confirmed', 'true', 'seller_is_owner', 'true', 'ownership_declaration', 'true',
    'category', 'Phone', 'brand', 'Apple', 'model', 'iPhone 13', 'storage', '128GB',
    'clean_check_status', 'Clean', 'purchase_cost', '300', 'payout_method', 'Cash', 'status', 'inspection');

  -- 1. Three purchases from the same ID, none with a phone or email, all save.
  for visit in 1..3 loop
    intake_key_value := extensions.gen_random_uuid();
    insert into public.pos_used_device_intake_uploads(id, store_id, intake_key, stage, storage_path, author)
    values (extensions.gen_random_uuid(), store_id_value, intake_key_value, 'intake',
            store_id_value || '/' || intake_key_value || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value);
    result := public.create_pos_used_device_acquisition(staff_token, base_payload || jsonb_build_object(
      'intake_key', intake_key_value, 'imei', '', 'serial_number', 'NOPHONE-' || extensions.gen_random_uuid()::text));
    if visit = 1 then no_contact_device := result#>>'{device,device_code}'; end if;
  end loop;

  -- With nothing to match a return visit on, no duplicate customer is made.
  assert (select acquisition.seller_phone = '' and acquisition.seller_email = '' and acquisition.customer_id is null
          from public.pos_used_device_acquisitions acquisition
          join public.pos_used_devices device on device.acquisition_id = acquisition.id
          where device.device_code = no_contact_device),
    'A purchase without contact details was not saved unlinked';

  -- 2. Email alone is enough to become a customer.
  intake_key_value := extensions.gen_random_uuid();
  insert into public.pos_used_device_intake_uploads(id, store_id, intake_key, stage, storage_path, author)
  values (extensions.gen_random_uuid(), store_id_value, intake_key_value, 'intake',
          store_id_value || '/' || intake_key_value || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value);
  result := public.create_pos_used_device_acquisition(staff_token, base_payload || jsonb_build_object(
    'intake_key', intake_key_value, 'imei', '', 'serial_number', 'EMAIL-' || extensions.gen_random_uuid()::text,
    'seller_name', 'Email Only Seller', 'seller_email', 'email.only@example.test',
    'seller_id_reference', 'EMAIL-' || extensions.gen_random_uuid()::text));
  email_device := result#>>'{device,device_code}';
  assert (select customer.email = 'email.only@example.test' and customer.phone = ''
          from public.pos_used_device_acquisitions acquisition
          join public.pos_used_devices device on device.acquisition_id = acquisition.id
          join public.pos_customers customer on customer.id = acquisition.customer_id
          where device.device_code = email_device),
    'An email-only seller was not saved as a customer';

  -- 3. Leaving the phone blank does not hide a repeat seller: the ID counts.
  alerts := public.get_admin_used_device_alerts(admin_token, 90);
  assert exists (
    select 1 from jsonb_array_elements(alerts->'alerts') alert
    where alert->>'kind' = 'repeat_seller' and alert->>'message' like 'No Contact Seller%'
  ), 'A repeat seller without a phone was not flagged';

  raise notice 'used_device_optional_seller_contact: all checks passed';
end;
$test$;
rollback;
