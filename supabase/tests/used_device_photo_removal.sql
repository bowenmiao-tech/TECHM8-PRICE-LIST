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
  select id into first_intake from public.pos_used_device_updates
    where device_id = device_id_value and kind = 'photo' and stage = 'intake';

  insert into public.pos_used_device_updates(id, device_id, kind, stage, storage_path, author) values
    (listing_one, device_id_value, 'photo', 'listing', store_id_value || '/' || device_id_value || '/' || listing_one || '.jpg', staff_name_value),
    (listing_two, device_id_value, 'photo', 'listing', store_id_value || '/' || device_id_value || '/' || listing_two || '.jpg', staff_name_value),
    (seller_id_photo, device_id_value, 'photo', 'seller_id', store_id_value || '/' || device_id_value || '/' || seller_id_photo || '.jpg', staff_name_value);

  -- 1. The only intake photo of a purchase stays.
  refused := false;
  begin
    perform public.remove_pos_used_device_photo(staff_token, store_code_value, device_code_value, first_intake);
  exception when others then refused := true; refusal := sqlerrm;
  end;
  assert refused and refusal like '%at least one intake photo%', format('Unexpected intake refusal: %s', refusal);

  -- Once the right photo is added, the wrong one can go.
  insert into public.pos_used_device_updates(id, device_id, kind, stage, storage_path, author)
  values (second_intake, device_id_value, 'photo', 'intake',
          store_id_value || '/' || device_id_value || '/' || second_intake || '.jpg', staff_name_value);
  perform public.remove_pos_used_device_photo(staff_token, store_code_value, device_code_value, first_intake);

  -- 2. A removed photo leaves every view but stays on record and on the history.
  assert not exists (select 1 from public.pos_used_device_updates where id = first_intake),
    'A removed photo is still visible';
  assert exists (select 1 from public.pos_used_device_update_records
                 where id = first_intake and removed_at is not null and removed_by = staff_name_value),
    'A removed photo was not kept on record with who removed it';
  assert exists (select 1 from public.pos_used_device_transactions
                 where device_id = device_id_value and transaction_type = 'photo_removed'),
    'The removal is not on the device history';
  assert (public.get_pos_used_device_updates(staff_token, store_code_value, device_code_value)->'updates')::text
    not like '%' || first_intake || '%', 'A removed photo came back through the device updates';

  -- 3. Seller ID photos: the admin, not staff.
  refused := false;
  begin
    perform public.remove_pos_used_device_photo(staff_token, store_code_value, device_code_value, seller_id_photo);
  exception when others then refused := true;
  end;
  assert refused, 'Staff removed a seller ID photo';
  perform public.remove_pos_used_device_photo(admin_token, store_code_value, device_code_value, seller_id_photo);
  assert exists (select 1 from public.pos_used_device_update_records
                 where id = seller_id_photo and removed_by_admin), 'The admin removal was not marked as such';

  -- 4. A device on sale keeps at least one listing photo, and losing one sends
  --    the listing to the website again.
  perform public.record_pos_used_device_sale_test(staff_token, store_code_value, device_code_value,
    jsonb_build_object('answers', (select jsonb_object_agg(item_key, 'pass')
      from public.pos_used_device_inspection_items where category = 'Phone' and active)));
  perform public.update_pos_used_device(staff_token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'status', 'ready_for_sale', 'sale_price', '600'));
  update public.pos_used_device_publish_queue set completed_at = now()
    where device_id = device_id_value and completed_at is null;

  result := public.remove_pos_used_device_photo(admin_token, store_code_value, device_code_value, listing_one);
  assert (result->>'republished')::boolean, 'Removing a listing photo did not republish';
  assert exists (select 1 from public.pos_used_device_publish_queue
                 where device_id = device_id_value and completed_at is null and action = 'publish'),
    'No republish was queued';
  refused := false;
  begin
    perform public.remove_pos_used_device_photo(admin_token, store_code_value, device_code_value, listing_two);
  exception when others then refused := true; refusal := sqlerrm;
  end;
  assert refused and refusal like '%at least one listing photo%', format('Unexpected listing refusal: %s', refusal);

  -- 5. A draft photo on the buy form is deleted outright; a claimed one cannot be.
  insert into public.pos_used_device_intake_uploads(id, store_id, intake_key, stage, storage_path, author)
  values (draft_upload, store_id_value, draft_key_value, 'intake',
          store_id_value || '/' || draft_key_value || '/' || draft_upload || '.jpg', staff_name_value);
  result := public.remove_pos_used_device_intake_upload(staff_token, store_code_value, draft_key_value, draft_upload);
  assert result->>'storage_path' like '%' || draft_upload || '.jpg', 'The draft path was not returned for deletion';
  assert not exists (select 1 from public.pos_used_device_intake_uploads where id = draft_upload), 'The draft is still there';
  refused := false;
  begin
    perform public.remove_pos_used_device_intake_upload(staff_token, store_code_value, intake_key_value,
      (select id from public.pos_used_device_intake_uploads where intake_key = intake_key_value limit 1));
  exception when others then refused := true;
  end;
  assert refused, 'A photo already claimed by a purchase was deleted as a draft';

  raise notice 'used_device_photo_removal: all checks passed';
end;
$test$;
rollback;
