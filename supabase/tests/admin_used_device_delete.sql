-- Admin hard deletion and signed-document cascade. Run against the staff/POS project.
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
  intake_key_value uuid := extensions.gen_random_uuid();
  draft_key_value uuid := extensions.gen_random_uuid();
  imei_value text := '96' || lpad((floor(random() * 10000000000000)::bigint)::text, 13, '0');
  result jsonb;
  device_code_value text;
  device_id_value bigint;
  first_intake uuid;
  second_intake uuid := extensions.gen_random_uuid();
  listing_one uuid := extensions.gen_random_uuid();
  listing_two uuid := extensions.gen_random_uuid();
  seller_id_photo uuid := extensions.gen_random_uuid();
  draft_upload uuid := extensions.gen_random_uuid();
  refused boolean;
  refusal text;
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

  insert into public.pos_used_device_intake_uploads(id, store_id, intake_key, stage, storage_path, author)
  values (extensions.gen_random_uuid(), store_id_value, intake_key_value, 'intake',
          store_id_value || '/' || intake_key_value || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value);

  result := public.create_pos_used_device_acquisition(staff_token, jsonb_build_object(
    'intake_key', intake_key_value, 'store_code', store_code_value, 'staff_name', staff_name_value,
    'shift_id', shift_code_value, 'seller_name', 'Photo Removal Seller', 'seller_phone', '0400000002',
    'seller_address', '1 Test Street', 'seller_id_type', 'Passport', 'seller_id_reference', 'TEST',
    'seller_age_confirmed', 'true', 'seller_is_owner', 'true', 'ownership_declaration', 'true',
    'category', 'Phone', 'brand', 'Apple', 'model', 'iPhone 13', 'storage', '128GB', 'imei', imei_value,
    'clean_check_status', 'Clean', 'activation_lock_removed', 'true', 'data_erased_confirmed', 'true',
    'purchase_cost', '300', 'payout_method', 'Cash', 'status', 'inspection'));
  device_code_value := result#>>'{device,device_code}';
  select id into device_id_value from public.pos_used_devices where device_code = device_code_value;

  insert into public.pos_used_device_buyback_documents(document_code,acquisition_id,device_id,store_id,pdf_path,pdf_sha256,signature_path,signed_seller_name,terms_version,terms_text,document_snapshot,witnessed_by)
  select 'DELETE-TEST-'||device_code_value,acquisition_id,id,store_id,'delete-test/'||device_code_value||'.pdf',repeat('a',64),'delete-test/'||device_code_value||'.png','Test Seller',(select version from public.pos_used_device_buyback_terms where active limit 1),'Test terms','{}',staff_name_value
  from public.pos_used_devices where id=device_id_value;
  begin
    perform public.delete_admin_used_device(staff_token,device_code_value,device_code_value);
    raise exception 'TEST: staff deleted device';
  exception when others then assert sqlerrm like '%Administrator access%',sqlerrm; end;
  begin
    perform public.delete_admin_used_device(admin_token,device_code_value,'WRONG');
    raise exception 'TEST: wrong confirmation deleted device';
  exception when others then assert sqlerrm like '%exact device code%',sqlerrm; end;
  begin
    delete from public.pos_used_device_buyback_documents where device_id=device_id_value;
    raise exception 'TEST: standalone signed document deletion succeeded';
  exception when others then assert sqlerrm like '%immutable%',sqlerrm; end;
  result := public.delete_admin_used_device(admin_token,device_code_value,device_code_value);
  assert (result->>'ok')::boolean;
  assert not exists(select 1 from public.pos_used_devices where id=device_id_value);
  assert not exists(select 1 from public.pos_used_device_buyback_documents where device_id=device_id_value);
  assert not exists(select 1 from public.pos_used_device_transactions where device_id=device_id_value);
  assert not exists(select 1 from public.pos_used_device_update_records where device_id=device_id_value);
  result := public.delete_admin_used_device(admin_token,device_code_value,device_code_value);
  assert (result->>'already_deleted')::boolean;
end;
$test$;
rollback;
