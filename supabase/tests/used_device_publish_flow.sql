-- One-press publishing from the POS, the public listing text, and admin-only
-- repair pricing. Run against the staff/POS project. Every fixture write is
-- rolled back.
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
  result jsonb;
  panel jsonb;
  device_code_value text;
  device_id_value bigint;
  cost_line uuid := extensions.gen_random_uuid();
  refused boolean;
  refusal text;
  listing jsonb;
  staff_costs jsonb;
  admin_detail jsonb;
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
  select shift.shift_code into shift_code_value from public.pos_store_shifts shift
    where shift.store_id = store_id_value and shift.status = 'open' limit 1;
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
    'shift_id', shift_code_value, 'seller_name', 'Publish Flow Seller', 'seller_address', '1 Test Street',
    'seller_id_type', 'Passport', 'seller_id_reference', 'PUB-' || extensions.gen_random_uuid()::text,
    'seller_age_confirmed', 'true', 'seller_is_owner', 'true', 'ownership_declaration', 'true',
    'category', 'Phone', 'brand', 'Samsung Galaxy S', 'model', 'Galaxy S24 Ultra', 'storage', '256GB',
    'color', 'Titanium Grey', 'battery_health', '78', 'imei', '',
    'serial_number', 'PUB-' || extensions.gen_random_uuid()::text,
    'clean_check_status', 'Clean', 'activation_lock_removed', 'true', 'data_erased_confirmed', 'true',
    'purchase_cost', '500', 'payout_method', 'Cash', 'status', 'inspection'));
  device_code_value := result#>>'{device,device_code}';
  select id into device_id_value from public.pos_used_devices where device_code = device_code_value;

  -- 1. An unfinished device: the panel lists what is missing and the button refuses.
  panel := public.get_pos_used_device_website_status(staff_token, store_code_value, device_code_value);
  assert not (panel->>'can_publish')::boolean, 'An unfinished device could be published';
  assert (panel->'blockers')::text like '%pre-sale test%' and (panel->'blockers')::text like '%sale price%'
    and (panel->'blockers')::text like '%listing photo%', format('Unexpected blockers: %s', panel->'blockers');
  refused := false;
  begin
    perform public.request_pos_used_device_publish(staff_token, jsonb_build_object(
      'store_code', store_code_value, 'device_code', device_code_value, 'action', 'publish'));
  exception when others then refused := true; refusal := sqlerrm;
  end;
  assert refused and refusal like 'Not ready for the website yet:%', format('Unexpected refusal: %s', refusal);

  -- 2. Staff record what was done; an amount they send is ignored and never shown.
  perform public.add_pos_used_device_cost(staff_token, store_code_value, device_code_value, jsonb_build_object(
    'id', cost_line, 'kind', 'part', 'description', 'Replaced the back glass', 'amount', '120'));
  assert (select amount is null from public.pos_used_device_costs where id = cost_line), 'Staff set an amount';
  staff_costs := public.get_pos_used_device_costs(staff_token, store_code_value, device_code_value);
  assert (staff_costs#>>'{costs,0,description}') = 'Replaced the back glass', 'Staff cannot see what was done';
  assert (staff_costs#>'{costs,0,amount}') = 'null'::jsonb and (staff_costs->'refurb_cost') = 'null'::jsonb,
    'Staff can see an amount';

  -- 3. The admin prices it; it counts in the cost, and staff still do not see it.
  result := public.save_admin_used_device_cost(admin_token, jsonb_build_object('cost_id', cost_line, 'amount', '120'));
  assert (result->>'refurb_cost')::numeric = 120, 'The admin amount did not count';
  admin_detail := public.get_admin_used_device_detail(admin_token, device_code_value);
  assert (admin_detail#>>'{costs,0,amount}')::numeric = 120 and (admin_detail#>>'{device,total_cost}')::numeric = 620,
    'The admin detail did not include the amount';
  staff_costs := public.get_pos_used_device_costs(staff_token, store_code_value, device_code_value);
  assert (staff_costs#>'{costs,0,amount}') = 'null'::jsonb, 'Staff saw the admin amount';

  -- 4. The public listing: under 85% is "Good battery", and the title says the line once.
  listing := public.pos_used_device_listing_payload(device_id_value);
  assert listing->'battery_health' = 'null'::jsonb, 'A battery under 85% was sent to the website';
  assert (listing->'highlights')::text like '%Good battery%' and (listing->'highlights')::text not like '%78%',
    format('Unexpected battery highlights: %s', listing->'highlights');
  assert listing->>'title' = 'Samsung Galaxy S24 Ultra 256GB Titanium Grey', format('Unexpected title: %s', listing->>'title');

  -- 5. Finished: one press puts it on sale and queues the website.
  perform public.record_pos_used_device_sale_test(staff_token, store_code_value, device_code_value,
    jsonb_build_object('answers', (select jsonb_object_agg(item_key, 'pass')
      from public.pos_used_device_inspection_items where category = 'Phone' and active)));
  insert into public.pos_used_device_updates(id, device_id, kind, stage, storage_path, author)
  values (extensions.gen_random_uuid(), device_id_value, 'photo', 'listing',
          store_id_value || '/' || device_id_value || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value);
  perform public.update_pos_used_device(staff_token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'sale_price', '899'));
  panel := public.get_pos_used_device_website_status(staff_token, store_code_value, device_code_value);
  assert (panel->>'can_publish')::boolean, format('A finished device could not be published: %s', panel->'blockers');

  result := public.request_pos_used_device_publish(staff_token, jsonb_build_object(
    'store_code', store_code_value, 'device_code', device_code_value, 'action', 'publish'));
  assert result->>'status' = 'ready_for_sale', 'Publishing did not put the device on sale';
  assert exists (select 1 from public.pos_used_device_publish_queue
                 where device_id = device_id_value and completed_at is null and action = 'publish'), 'Nothing was queued';

  raise notice 'used_device_publish_flow: all checks passed';
end;
$test$;
rollback;
