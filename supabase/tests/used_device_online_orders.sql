-- Website orders for second-hand devices, as the POS sees them: reserving,
-- the counter and repricing guards, and catching up with how the order went.
-- Run against the staff/POS project. Every fixture write is rolled back.
begin;
do $test$
declare
  staff_token text := extensions.gen_random_uuid()::text;
  staff_id_value bigint;
  staff_name_value text;
  store_id_value bigint;
  store_code_value text;
  shift_code_value text;
  intake_key_value uuid := extensions.gen_random_uuid();
  result jsonb;
  device_code_value text;
  device_row public.pos_used_devices%rowtype;
  refused text;
  listing jsonb;
begin
  select staff.id, staff.display_name, store.id, store.store_code
    into staff_id_value, staff_name_value, store_id_value, store_code_value
    from public.staff_directory staff
    join public.store_locations store on store.id = staff.default_store_id
    where staff.active and store.active and store.store_code <> 'warehouse'
    limit 1;
  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
    values (staff_id_value, extensions.crypt(staff_token, extensions.gen_salt('bf')),
            encode(extensions.digest(staff_token, 'sha256'), 'hex'), now() + interval '5 minutes');
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

  -- A device ready for sale, as staff would leave it.
  result := public.create_pos_used_device_acquisition(staff_token, jsonb_build_object(
    'intake_key', intake_key_value, 'store_code', store_code_value, 'staff_name', staff_name_value,
    'shift_id', shift_code_value, 'seller_name', 'Online Order Seller', 'seller_address', '1 Test Street',
    'seller_id_type', 'Passport', 'seller_id_reference', 'ONL-' || extensions.gen_random_uuid()::text,
    'seller_age_confirmed', 'true', 'seller_is_owner', 'true', 'ownership_declaration', 'true',
    'category', 'Phone', 'brand', 'Apple iPhone', 'model', 'iPhone 15', 'storage', '128GB',
    'color', 'Black', 'battery_health', '90', 'imei', '',
    'serial_number', 'ONL-' || extensions.gen_random_uuid()::text,
    'clean_check_status', 'Clean', 'activation_lock_removed', 'true', 'data_erased_confirmed', 'true',
    'purchase_cost', '400', 'payout_method', 'Cash', 'status', 'inspection'));
  device_code_value := result#>>'{device,device_code}';
  select * into device_row from public.pos_used_devices where device_code = device_code_value;
  perform public.record_pos_used_device_sale_test(staff_token, store_code_value, device_code_value,
    jsonb_build_object('answers', (select jsonb_object_agg(item_key, 'pass')
      from public.pos_used_device_inspection_items where category = 'Phone' and active)));
  insert into public.pos_used_device_updates(id, device_id, kind, stage, storage_path, author)
  values (extensions.gen_random_uuid(), device_row.id, 'photo', 'listing',
          store_id_value || '/' || device_row.id || '/' || extensions.gen_random_uuid() || '.jpg', staff_name_value);
  perform public.update_pos_used_device(staff_token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'sale_price', '700', 'status', 'ready_for_sale'));

  -- 1. The listing no longer carries the inspection count or the store line;
  -- the store travels on its own.
  listing := public.pos_used_device_listing_payload(device_row.id);
  assert (listing->'highlights')::text not like '%inspection checks%', format('Inspection count still listed: %s', listing->'highlights');
  assert (listing->'highlights')::text not like '%In stock at%', format('Store still a highlight: %s', listing->'highlights');
  assert coalesce(listing->>'store_name', '') <> '', 'The store name is not sent';

  -- 2. A checkout reserves it, and a second order cannot.
  result := public.hold_pos_used_devices_online(jsonb_build_object(
    'order_code', 'TM8-POSTEST-A', 'hold_kind', 'checkout', 'device_codes', jsonb_build_array(device_code_value),
    'customer_name', 'Web Buyer', 'fulfillment_method', 'pickup', 'store_slug', 'park-ridge'));
  select * into device_row from public.pos_used_devices where device_code = device_code_value;
  assert device_row.online_order_code = 'TM8-POSTEST-A' and device_row.online_hold_until > now(), 'No reservation was recorded';
  assert exists (select 1 from public.pos_used_device_transactions
                 where device_id = device_row.id and transaction_type = 'online_hold'), 'The reservation is not in the history';
  refused := null;
  begin
    perform public.hold_pos_used_devices_online(jsonb_build_object(
      'order_code', 'TM8-POSTEST-B', 'hold_kind', 'checkout', 'device_codes', jsonb_build_array(device_code_value)));
  exception when others then refused := sqlerrm;
  end;
  assert refused like 'USED_DEVICE_HELD:%', format('A second order was not refused: %s', refused);

  -- 3. While reserved, staff cannot reprice it or take it off sale, and the
  -- counter sale is refused.
  refused := null;
  begin
    perform public.update_pos_used_device(staff_token, jsonb_build_object(
      'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
      'sale_price', '650', 'below_cost_reason', 'test'));
  exception when others then refused := sqlerrm;
  end;
  assert refused like '%reserved for website order TM8-POSTEST-A%', format('A reserved device was repriced: %s', refused);
  assert position('pos_used_device_online_hold_active' in
    pg_get_functiondef('public.prepare_pos_used_device_sale_line()'::regprocedure)) > 0,
    'The counter sale does not check the reservation';
  assert (public.pos_used_device_payload(device_row)#>>'{online_order,order_code}') = 'TM8-POSTEST-A',
    'Staff are not shown the reservation';

  -- 4. The same customer trying again takes the reservation over.
  perform public.hold_pos_used_devices_online(jsonb_build_object(
    'order_code', 'TM8-POSTEST-C', 'hold_kind', 'checkout', 'device_codes', jsonb_build_array(device_code_value),
    'replaces', jsonb_build_array('TM8-POSTEST-A')));
  assert (select online_order_code from public.pos_used_devices where device_code = device_code_value) = 'TM8-POSTEST-C',
    'The same customer could not take their checkout over';

  -- 5. The website says nobody holds it: back on sale.
  result := public.apply_pos_used_device_online_sync(jsonb_build_object('devices', jsonb_build_array(
    jsonb_build_object('device_code', device_code_value, 'listing_status', 'published', 'hold', null))));
  assert result->'released' @> to_jsonb(array[device_code_value]), format('Not released: %s', result);
  assert (select online_order_code is null from public.pos_used_devices where device_code = device_code_value), 'Still reserved';
  assert exists (select 1 from public.pos_used_device_transactions
                 where device_id = device_row.id and transaction_type = 'online_release'), 'The release is not in the history';

  -- 6. A checkout past its time no longer blocks staff.
  perform public.hold_pos_used_devices_online(jsonb_build_object(
    'order_code', 'TM8-POSTEST-D', 'hold_kind', 'checkout', 'device_codes', jsonb_build_array(device_code_value)));
  update public.pos_used_devices set online_hold_until = now() - interval '1 minute' where device_code = device_code_value;
  perform public.update_pos_used_device(staff_token, jsonb_build_object(
    'store_code', store_code_value, 'staff_name', staff_name_value, 'device_code', device_code_value,
    'sale_price', '690', 'below_cost_reason', 'test'));

  -- 7. Paid online: a sale here, with the website order on it, and the listing
  -- comes down.
  result := public.apply_pos_used_device_online_sync(jsonb_build_object('devices', jsonb_build_array(
    jsonb_build_object('device_code', device_code_value, 'listing_status', 'published', 'hold', jsonb_build_object(
      'kind', 'sold', 'order_code', 'TM8-POSTEST-E', 'amount', 690, 'customer_name', 'Web Buyer',
      'customer_phone', '0400000000', 'payment_method', 'Card & wallets', 'fulfillment_method', 'pickup',
      'paid_at', now())))));
  assert result->'sold' @> to_jsonb(array[device_code_value]), format('Not sold: %s', result);
  select * into device_row from public.pos_used_devices where device_code = device_code_value;
  assert device_row.status = 'sold' and device_row.sold_online_order_code = 'TM8-POSTEST-E'
    and device_row.online_order_code is null, 'The online sale was not recorded on the device';
  assert (select amount from public.pos_used_device_transactions
          where device_id = device_row.id and transaction_type = 'sale') = 690, 'The sale is not in the history at its price';
  assert exists (select 1 from public.pos_used_device_publish_queue
                 where device_id = device_row.id and completed_at is null and action = 'sold'), 'The listing was not taken down';
  assert (public.pos_used_device_payload(device_row)->>'sold_online_order_code') = 'TM8-POSTEST-E',
    'Staff are not shown the website order';

  -- 8. Told again, nothing changes; a different paid order is a conflict, not a second sale.
  result := public.apply_pos_used_device_online_sync(jsonb_build_object('devices', jsonb_build_array(
    jsonb_build_object('device_code', device_code_value, 'hold', jsonb_build_object('kind', 'sold', 'order_code', 'TM8-POSTEST-E')),
    jsonb_build_object('device_code', device_code_value, 'hold', jsonb_build_object('kind', 'sold', 'order_code', 'TM8-POSTEST-F')))));
  assert jsonb_array_length(result->'sold') = 0 and jsonb_array_length(result->'conflicts') = 1,
    format('Repeat sync: %s', result);

  raise notice 'used_device_online_orders: all checks passed';
end;
$test$;
rollback;
