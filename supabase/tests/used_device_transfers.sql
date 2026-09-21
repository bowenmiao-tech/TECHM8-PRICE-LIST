-- Removing device photos taken by mistake. Run against the staff/POS project.
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
  target_staff bigint;
  target_name text;
  target_store bigint;
  target_code text;
  receiver_token text := extensions.gen_random_uuid()::text;
  receipt_key uuid := extensions.gen_random_uuid();
  receipt_photo uuid := extensions.gen_random_uuid();
  transfer_code text;
  detail jsonb;
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

  select staff.id, staff.display_name, store.id, store.store_code
    into target_staff, target_name, target_store, target_code
    from public.staff_directory staff join public.store_locations store on store.id=staff.default_store_id
    where staff.active and store.active and store.id <> store_id_value and store.store_code <> 'warehouse' limit 1;
  assert target_staff is not null, 'A second store is required';
  insert into public.staff_sessions(staff_id,session_hash,token_digest,expires_at)
    values(target_staff,extensions.crypt(receiver_token,extensions.gen_salt('bf')),encode(extensions.digest(receiver_token,'sha256'),'hex'),now()+interval '5 minutes');
  perform public.record_pos_used_device_sale_test(staff_token,store_code_value,device_code_value,
    jsonb_build_object('answers',(select jsonb_object_agg(item_key,'pass') from public.pos_used_device_inspection_items where category='Phone' and active)));
  insert into public.pos_used_device_updates(id,device_id,kind,stage,storage_path,author)
    values(extensions.gen_random_uuid(),device_id_value,'photo','listing','transfer-test/listing.jpg',staff_name_value);
  update public.pos_used_devices set status='ready_for_sale',sale_price=500,ready_at=now() where id=device_id_value;
  result := public.send_pos_used_device_transfer(staff_token,jsonb_build_object('store_code',store_code_value,'staff_name',staff_name_value,'device_code',device_code_value,'to_store_code',target_code));
  transfer_code := result#>>'{transfer,transfer_code}';
  assert (select store_id=store_id_value from public.pos_used_devices where id=device_id_value), 'Moved before receipt';
  begin
    perform public.receive_pos_used_device_transfer(receiver_token,jsonb_build_object('store_code',target_code,'staff_name',target_name,'transfer_code',transfer_code));
    raise exception 'TEST: no-photo receipt succeeded';
  exception when others then assert sqlerrm like '%at least one receipt photo%', sqlerrm;
  end;
  insert into public.pos_used_device_intake_uploads(id,store_id,intake_key,stage,storage_path,author)
    values(receipt_photo,target_store,receipt_key,'intake',target_store||'/'||receipt_key||'/'||receipt_photo||'.jpg',target_name);
  begin
    perform public.receive_pos_used_device_transfer(staff_token,jsonb_build_object('store_code',store_code_value,'staff_name',staff_name_value,'transfer_code',transfer_code,'receipt_intake_key',receipt_key));
    raise exception 'TEST: sender received device';
  exception when others then assert sqlerrm like '%not sent to your store%', sqlerrm;
  end;
  result := public.receive_pos_used_device_transfer(receiver_token,jsonb_build_object('store_code',target_code,'staff_name',target_name,'transfer_code',transfer_code,'receipt_intake_key',receipt_key));
  assert result#>>'{transfer,status}'='received';
  assert (select store_id=target_store and status='ready_for_sale' from public.pos_used_devices where id=device_id_value), 'Store not updated';
  assert (select claimed_device_id=device_id_value from public.pos_used_device_intake_uploads where id=receipt_photo), 'Photo not claimed';
  assert (select device_id=device_id_value from public.pos_used_device_updates where id=receipt_photo), 'Photo not attached';
  begin
    perform public.remove_pos_used_device_photo(admin_token,target_code,device_code_value,receipt_photo);
    raise exception 'TEST: last receipt photo removed';
  exception when others then assert sqlerrm like '%at least one receipt photo%', sqlerrm;
  end;
  detail := public.get_admin_used_device_detail(admin_token,device_code_value);
  assert detail#>>'{transfers,0,from_store_code}'=store_code_value;
  assert detail#>>'{transfers,0,to_store_code}'=target_code;
  assert detail#>>'{transfers,0,receipt_photo_ids,0}'=receipt_photo::text, 'Admin receipt photo missing';
  result := public.get_pos_used_device_updates(admin_token,target_code,device_code_value);
  assert exists(select 1 from jsonb_array_elements(result->'updates') p where p->>'id'=receipt_photo::text), 'Admin cannot read receipt photo';
  perform public.receive_pos_used_device_transfer(receiver_token,jsonb_build_object('store_code',target_code,'staff_name',target_name,'transfer_code',transfer_code,'receipt_intake_key',receipt_key));
  assert (select count(*)=1 from public.pos_used_device_transactions where device_id=device_id_value and transaction_type='transfer_in'), 'Duplicate receipt ledger';
end;
$test$;
rollback;
