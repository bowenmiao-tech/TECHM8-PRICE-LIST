-- Run against the website project after the restore migration. All writes roll back.
begin;
do $test$
declare
  listing_row public.used_device_listings%rowtype;
  first_order_id bigint;
  paid_order_id bigint;
  result jsonb;
  refused text;
begin
  perform public.upsert_used_device_listing(jsonb_build_object(
    'device_code', 'USED-RESTORETEST01', 'device_category', 'Phone',
    'store_code', 'parkridge', 'store_name', 'Park Ridge Town Centre',
    'title', 'Test phone for reservation restore', 'brand', 'Apple iPhone',
    'model', 'iPhone 15', 'storage', '128GB', 'color', 'Black',
    'condition_grade', 'Good', 'condition_summary', 'Test fixture.',
    'price', 700, 'description', 'Test fixture.',
    'images', '[{"url":"https://example.com/test.jpg","position":1}]'::jsonb,
    'status', 'published', 'source_version', 1
  ));
  select * into listing_row from public.used_device_listings
  where device_code = 'USED-RESTORETEST01';

  insert into public.orders (
    order_code, customer_name, phone, email, store_slug, status,
    payment_status, payment_method_code, fulfillment_method, fulfillment_status,
    subtotal_amount, total_amount
  ) values (
    'TM8-RESTORETEST-A', 'Restore Test', '0400000000', 'test@example.com', 'park-ridge',
    'submitted', 'unpaid', 'pay_in_store', 'pickup', 'new', 700, 700
  ) returning id into first_order_id;
  insert into public.order_items (order_id, product_id, product_name, quantity, unit_price, line_total)
  values (first_order_id, listing_row.product_id, 'Test phone', 1, 700, 700);
  perform public.claim_used_devices_for_order(first_order_id);
  assert not (select is_visible from public.products where id = listing_row.product_id),
    'The unpaid order did not hide the product';

  result := public.cancel_unpaid_used_device_reservation(
    'USED-RESTORETEST01', 'TM8-RESTORETEST-A', 'parkridge', 'Test Staff');
  assert result->>'cancelled' = 'true', format('Cancel result: %s', result);
  assert (select status = 'cancelled' and fulfillment_status = 'cancelled'
    from public.orders where id = first_order_id), 'The unpaid order was not cancelled';
  assert (select is_visible from public.products where id = listing_row.product_id),
    'The product did not return to the website';
  assert exists (select 1 from public.order_events where order_id = first_order_id
    and event_key = 'used_device_restored:USED-RESTORETEST01'), 'Cancellation was not audited';
  result := public.cancel_unpaid_used_device_reservation(
    'USED-RESTORETEST01', 'TM8-RESTORETEST-A', 'parkridge', 'Test Staff');
  assert result->>'already_cancelled' = 'true', 'A retry was not idempotent';

  insert into public.orders (
    order_code, customer_name, phone, email, store_slug, status,
    payment_status, payment_method_code, fulfillment_method, fulfillment_status,
    subtotal_amount, total_amount
  ) values (
    'TM8-RESTORETEST-B', 'Restore Test', '0400000000', 'test@example.com', 'park-ridge',
    'submitted', 'unpaid', 'pay_in_store', 'pickup', 'new', 700, 700
  ) returning id into paid_order_id;
  insert into public.order_items (order_id, product_id, product_name, quantity, unit_price, line_total)
  values (paid_order_id, listing_row.product_id, 'Test phone', 1, 700, 700);
  perform public.claim_used_devices_for_order(paid_order_id);
  update public.orders set payment_status = 'paid', amount_paid = 700, paid_at = now()
  where id = paid_order_id;
  refused := null;
  begin
    perform public.cancel_unpaid_used_device_reservation(
      'USED-RESTORETEST01', 'TM8-RESTORETEST-B', 'parkridge', 'Test Staff');
  exception when others then refused := sqlerrm;
  end;
  assert refused like '%may have a payment%', format('A paid order was cancelled: %s', refused);

  raise notice 'website_used_device_restore: all checks passed';
end;
$test$;
rollback;
