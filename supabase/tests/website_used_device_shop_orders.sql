-- Second-hand devices sold through the website shop: the product mirror, the
-- `used-` slug, and order holds. Run against the website/product project after
-- 20260921170000_sell_used_devices_in_the_shop. Every fixture write is rolled back.
begin;
do $test$
declare
  customer_a uuid;
  customer_b uuid;
  result jsonb;
  listing_row public.used_device_listings%rowtype;
  product_row public.products%rowtype;
  order_a bigint;
  order_b bigint;
  order_c bigint;
  order_d bigint;
  refused text;
  holds jsonb;

  -- One pending card order (or unpaid pay-in-store order) holding one line.
  function_order_sql constant text := $sql$
    insert into public.orders (order_code, customer_name, phone, email, store_slug, auth_user_id,
      payment_status, status, fulfillment_status, fulfillment_method, subtotal_amount, total_amount)
    values ($1, 'Shop Test', '0400000000', 'shop-test@example.com', 'park-ridge', $2, $3, 'submitted', 'new',
      'pickup', $4, $4)
    returning id
  $sql$;
begin
  select id into customer_a from auth.users order by created_at limit 1;
  select id into customer_b from auth.users where id <> customer_a order by created_at limit 1;

  -- 1. Publishing writes a product in the Second Hand Devices category.
  result := public.upsert_used_device_listing(jsonb_build_object(
    'device_code', 'USED-SHOPTEST01', 'device_category', 'Phone', 'store_code', 'parkridge',
    'store_name', 'Park Ridge Town Centre', 'title', 'Apple iPhone 15 128GB Black', 'brand', 'Apple iPhone',
    'model', 'iPhone 15', 'storage', '128GB', 'color', 'Black', 'condition_grade', 'Good',
    'condition_summary', 'Light signs of use.', 'battery_health', 88, 'price', 700,
    'description', 'Tested in store.', 'highlights', '["Battery health 88%"]'::jsonb,
    'images', '[{"url": "https://example.com/1.jpg", "position": 1}, {"url": "https://example.com/2.jpg", "position": 2}]'::jsonb,
    'status', 'published', 'source_version', 1));
  select * into listing_row from public.used_device_listings where device_code = 'USED-SHOPTEST01';
  select * into product_row from public.products where id = listing_row.product_id;
  assert listing_row.slug like 'used-%', format('Slug without the used- prefix: %s', listing_row.slug);
  assert product_row.slug = listing_row.slug and product_row.sku = 'USED-SHOPTEST01', 'Product does not mirror the listing';
  assert product_row.is_visible and not product_row.is_pos_visible, 'Product visibility is wrong';
  assert product_row.brand = 'Apple' and product_row.retail_price = 700 and product_row.stock_quantity = 1,
    format('Product fields are wrong: %s %s %s', product_row.brand, product_row.retail_price, product_row.stock_quantity);
  assert (select category_name || '/' || subcategory_name from public.pos_category_taxonomy where id = product_row.pos_category_id)
    = 'Second Hand Devices/Used Phones', 'Product is not in Second Hand Devices / Used Phones';
  assert (select count(*) from public.product_images where product_id = product_row.id) = 2, 'Gallery was not copied';
  assert (public.get_used_device_listing(listing_row.slug)->'listing'->>'store_name') = 'Park Ridge Town Centre',
    'Device location is missing from the public listing';
  assert (public.get_used_device_listing(replace(listing_row.slug, 'used-', ''))->>'ok')::boolean,
    'A link from before the used- prefix no longer finds the device';

  -- 2. A card checkout claims it. The device stays visible while the customer
  -- is on the payment page, and the POS is given the hold.
  execute function_order_sql into order_a using 'TM8-SHOPTEST-A', customer_a, 'pending', 700;
  insert into public.order_items (order_id, product_id, product_name, quantity, unit_price, line_total)
  values (order_a, product_row.id, product_row.name, 1, 700, 700);
  result := public.claim_used_devices_for_order(order_a);
  assert jsonb_array_length(result->'devices') = 1 and result->>'hold_kind' = 'checkout', format('Claim A: %s', result);
  assert (select is_visible from public.products where id = product_row.id), 'A checkout hid the device';
  holds := public.get_used_device_order_holds(array['USED-SHOPTEST01']);
  assert holds#>>'{devices,0,hold,kind}' = 'checkout' and holds#>>'{devices,0,hold,order_code}' = 'TM8-SHOPTEST-A',
    format('Holds after A: %s', holds);

  -- 3. Another customer cannot claim it meanwhile.
  execute function_order_sql into order_b using 'TM8-SHOPTEST-B', customer_b, 'pending', 700;
  insert into public.order_items (order_id, product_id, product_name, quantity, unit_price, line_total)
  values (order_b, product_row.id, product_row.name, 1, 700, 700);
  refused := null;
  begin
    perform public.claim_used_devices_for_order(order_b);
  exception when others then refused := sqlerrm;
  end;
  assert refused like 'USED_DEVICE_HELD: Another customer is paying%', format('B was not refused: %s', refused);

  -- 4. The same customer going back and trying again replaces their checkout.
  execute function_order_sql into order_c using 'TM8-SHOPTEST-C', customer_a, 'pending', 700;
  insert into public.order_items (order_id, product_id, product_name, quantity, unit_price, line_total)
  values (order_c, product_row.id, product_row.name, 1, 700, 700);
  result := public.claim_used_devices_for_order(order_c);
  assert result#>>'{superseded,0,order_code}' = 'TM8-SHOPTEST-A', format('A was not superseded: %s', result);
  update public.orders set payment_status = 'expired', status = 'abandoned', fulfillment_status = 'not_started'
  where id = order_a;
  holds := public.get_used_device_order_holds(array['USED-SHOPTEST01']);
  assert holds#>>'{devices,0,hold,order_code}' = 'TM8-SHOPTEST-C', format('Holds after C: %s', holds);

  -- 5. Paid: hidden from the shop and the device page, and the POS is told it sold.
  update public.orders set payment_status = 'paid', status = 'confirmed', fulfillment_status = 'queued',
    amount_paid = 700, paid_at = now() where id = order_c;
  assert not (select is_visible from public.products where id = product_row.id), 'A paid device is still in the shop';
  assert not (public.get_used_device_listing(listing_row.slug)->>'ok')::boolean, 'A paid device still has a page';
  holds := public.get_used_device_order_holds(array['USED-SHOPTEST01', 'USED-ZZNOTLISTED']);
  assert holds#>>'{devices,0,hold,kind}' = 'sold' and (holds#>>'{devices,0,hold,amount}')::numeric = 700,
    format('Sold hold: %s', holds);
  assert holds#>'{devices,1,hold}' = 'null'::jsonb, 'A device not on the website has a hold';

  -- 6. Pay in store reserves and hides; cancelling frees it.
  result := public.upsert_used_device_listing(jsonb_build_object(
    'device_code', 'USED-SHOPTEST02', 'device_category', 'Tablet', 'store_code', 'fairfield',
    'title', 'Apple iPad 10 64GB Blue', 'brand', 'Apple iPad', 'model', 'iPad 10', 'condition_grade', 'Good',
    'price', 300, 'images', '[{"url": "https://example.com/3.jpg", "position": 1}]'::jsonb,
    'status', 'published', 'source_version', 1));
  select * into listing_row from public.used_device_listings where device_code = 'USED-SHOPTEST02';
  execute function_order_sql into order_d using 'TM8-SHOPTEST-D', customer_b, 'unpaid', 300;
  insert into public.order_items (order_id, product_id, product_name, quantity, unit_price, line_total)
  values (order_d, listing_row.product_id, 'iPad', 1, 300, 300);
  result := public.claim_used_devices_for_order(order_d);
  assert result->>'hold_kind' = 'reserved' and result->'hold_until' = 'null'::jsonb, format('Claim D: %s', result);
  assert not (select is_visible from public.products where id = listing_row.product_id), 'A reserved device is still in the shop';
  update public.orders set status = 'cancelled', fulfillment_status = 'cancelled' where id = order_d;
  assert (select is_visible from public.products where id = listing_row.product_id), 'Cancelling did not free the device';

  -- 7. Two of one device, or a stale price, is refused.
  update public.order_items set quantity = 2 where order_id = order_d;
  update public.orders set status = 'submitted' where id = order_d;
  refused := null;
  begin
    perform public.claim_used_devices_for_order(order_d);
  exception when others then refused := sqlerrm;
  end;
  assert refused like 'USED_DEVICE_QUANTITY:%', format('Quantity 2 was not refused: %s', refused);
  update public.order_items set quantity = 1, unit_price = 250 where order_id = order_d;
  refused := null;
  begin
    perform public.claim_used_devices_for_order(order_d);
  exception when others then refused := sqlerrm;
  end;
  assert refused like 'USED_DEVICE_PRICE:%', format('A stale price was not refused: %s', refused);

  -- 8. Withdrawing from the POS takes it out of the shop.
  perform public.withdraw_used_device_listing(jsonb_build_object(
    'device_code', 'USED-SHOPTEST02', 'status', 'withdrawn', 'source_version', 2));
  assert not (select is_visible from public.products where id = listing_row.product_id), 'A withdrawn device is still in the shop';

  -- 9. The devices already live got their products.
  assert not exists (
    select 1 from public.used_device_listings listing
    where listing.status = 'published' and listing.product_id is null
  ), 'A published listing has no product';

  raise notice 'website_used_device_shop_orders: all checks passed';
end;
$test$;
rollback;
