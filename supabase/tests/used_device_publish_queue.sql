-- The website publish queue and the generated listing.
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
  batch jsonb;
  item jsonb;
  answers jsonb;
  listing_text text;
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
    'seller_name', 'Publish Regression Seller', 'seller_phone', '0400000000', 'seller_address', '1 Test Street',
    'seller_id_type', 'Driver Licence', 'seller_id_reference', 'TEST-000', 'seller_age_confirmed', 'true',
    'seller_is_owner', 'true', 'ownership_declaration', 'true',
    'category', 'Phone', 'brand', 'Apple', 'model', 'iPhone 13', 'storage', '128GB',
    'imei', imei_value, 'color', 'Blue', 'battery_health', '89',
    'condition_grade', 'Good', 'clean_check_status', 'Pending', 'purchase_cost', '300',
    'sale_price', '649', 'payout_method', 'Cash'));
  device_code_value := result#>>'{device,device_code}';
  select id into device_id_value from public.pos_used_devices where device_code = device_code_value;

  insert into public.pos_used_device_updates(id, device_id, kind, stage, storage_path, author)
  values (extensions.gen_random_uuid(), device_id_value, 'photo', 'listing',
          store_id_value || '/' || device_id_value || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value);

  select jsonb_object_agg(item_key, 'pass') into answers
  from public.pos_used_device_inspection_items where category = 'Phone' and active;

  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'status', 'ready_for_sale', 'clean_check_status', 'Clean', 'clean_check_reference', 'AMTA-TEST',
    'activation_lock_removed', 'true', 'data_erased_confirmed', 'true', 'inspection', answers));

  assert (select website_status = 'queued' from public.pos_used_devices where id = device_id_value),
    'Going ready did not queue a publish';
  assert (select count(*) = 1 from public.pos_used_device_publish_queue
          where device_id = device_id_value and completed_at is null and action = 'publish'),
    'The publish intention was not queued exactly once';

  -- A price change replaces the pending intention rather than adding another.
  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'sale_price', '629'));
  assert (select count(*) = 1 from public.pos_used_device_publish_queue
          where device_id = device_id_value and completed_at is null),
    'A price change queued a second pending intention';

  batch := public.claim_pos_used_device_publish_batch(10);
  select entry into item from jsonb_array_elements(batch->'items') entry
    where entry#>>'{listing,device_code}' = device_code_value;
  assert item is not null, 'The queued device was not claimed';
  assert item#>>'{listing,title}' = 'Apple iPhone 13 128GB Blue',
    format('Unexpected title: %s', item#>>'{listing,title}');
  assert (item#>>'{listing,price}')::numeric = 629, 'The listing carried a stale price';
  assert jsonb_array_length(item#>'{listing,images}') = 1, 'The listing photo was not carried';
  assert (item#>>'{listing,description}') like '%Good condition%', 'The description was not generated';
  assert jsonb_array_length(item#>'{listing,highlights}') >= 4, 'The highlights were not generated';

  -- Nothing identifying may leave the building.
  listing_text := (item->'listing')::text;
  assert position(imei_value in listing_text) = 0, 'The listing payload carried the IMEI';
  assert position('Publish Regression Seller' in listing_text) = 0, 'The listing payload carried the seller';
  assert not (item->'listing' ? 'purchase_cost'), 'The listing payload carried the purchase price';

  perform public.complete_pos_used_device_publish(jsonb_build_object(
    'queue_id', item->>'queue_id', 'ok', 'true', 'slug', 'apple-iphone-13-128gb-blue-abc123'));
  assert (select website_status = 'published' and website_slug = 'apple-iphone-13-128gb-blue-abc123'
          from public.pos_used_devices where id = device_id_value), 'The device was not marked published';

  -- Taking it off the shelf queues a withdrawal without staff having to think.
  perform public.update_pos_used_device(token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'status', 'inspection', 'change_note', 'Back for another look'));
  assert (select count(*) = 1 from public.pos_used_device_publish_queue
          where device_id = device_id_value and completed_at is null and action = 'withdraw'),
    'Leaving the shelf did not queue a withdrawal';

  raise notice 'used_device_publish_queue: all checks passed';
end;
$test$;
rollback;
