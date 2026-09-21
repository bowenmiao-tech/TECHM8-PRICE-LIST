-- Zero-dollar sales and exchanges must remain atomic and idempotent.
-- Every fixture write is rolled back.
begin;
do $test$
declare
  token text := gen_random_uuid()::text;
  store_row public.store_locations%rowtype;
  shift_row public.pos_store_shifts%rowtype;
  staff_row public.staff_directory%rowtype;
  customer_code_value text := 'TEST-EXCHANGE-' || gen_random_uuid()::text;
  customer_id_value bigint;
  original_order_id bigint;
  original_line_id bigint;
  original_order_code text := 'TEST-EXCHANGE-ORIGINAL-' || gen_random_uuid()::text;
  zero_order_code text := 'TEST-ZERO-' || gen_random_uuid()::text;
  exchange_order_code text := 'TEST-EXCHANGE-NEW-' || gen_random_uuid()::text;
  result jsonb;
  refund_count integer;
  payment_count integer;
  balance_value numeric(12,2);
begin
  select shift_record.* into shift_row
  from public.pos_store_shifts shift_record
  where shift_record.status = 'open'
    and shift_record.business_date = (now() at time zone 'Australia/Brisbane')::date
    and shift_record.opening_confirmed_at is not null
  order by shift_record.id desc
  limit 1;
  if shift_row.id is null then raise exception 'No open shift available for checkout test'; end if;
  select * into store_row from public.store_locations where id = shift_row.store_id;

  select staff.* into staff_row
  from public.staff_directory staff
  where staff.active
    and lower(staff.display_name) = lower(shift_row.current_staff_name)
    and public.staff_has_store_access(staff.id, store_row.id)
  limit 1;
  if staff_row.id is null then raise exception 'Open-shift staff is unavailable for checkout test'; end if;

  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
  values (
    staff_row.id,
    extensions.crypt(token, extensions.gen_salt('bf')),
    encode(extensions.digest(token, 'sha256'), 'hex'),
    now() + interval '5 minutes'
  );

  insert into public.pos_customers(
    customer_code, store_id, first_name, phone, normalized_phone,
    created_by, updated_by
  ) values (
    customer_code_value, store_row.id, 'Exchange Test', '0499000001',
    '0499000001', staff_row.display_name, staff_row.display_name
  ) returning id into customer_id_value;

  insert into public.pos_sales_orders(
    order_code, invoice_number, store_id, business_date, staff_name, shift_id,
    customer_name, customer_phone, payment_method, total, amount_paid, order_payload
  ) values (
    original_order_code, 990000000000 + floor(random() * 100000000)::bigint,
    store_row.id, shift_row.business_date, staff_row.display_name, shift_row.shift_code,
    'Exchange Test', '0499000001', 'Card', 35, 35,
    jsonb_build_object('customer_code', customer_code_value)
  ) returning id into original_order_id;

  insert into public.pos_sales_order_lines(
    sales_order_id, line_number, line_type, product_id, sku, name,
    category, quantity, unit_price, line_total
  ) values (
    original_order_id, 1, 'special', 'special-test-return', 'SPECIAL',
    'Returned test item', 'Special Products', 1, 35, 35
  ) returning id into original_line_id;

  result := public.save_pos_sales_order_for_store(token, jsonb_build_object(
    'id', zero_order_code,
    'store_code', store_row.store_code,
    'staff_name', staff_row.display_name,
    'shift_id', shift_row.shift_code,
    'customer_name', 'Walk-in Customer',
    'payment_method', 'No Charge',
    'payments', '[]'::jsonb,
    'total', 0,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', 'special-zero-test', 'sku', 'SPECIAL',
      'name', 'Zero test item', 'category', 'Special Products',
      'qty', 1, 'unit_price', 0, 'line_total', 0, 'is_special', true
    ))
  ));
  assert result #>> '{order,total}' = '0.00', 'Zero-dollar order total was not saved';
  assert result #>> '{order,payment_method}' = 'No Charge', 'Zero-dollar order used a fake payment method';
  select count(*) into payment_count
  from public.pos_sales_order_payments payment
  join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id
  where sales_order.order_code = zero_order_code;
  assert payment_count = 0, 'Zero-dollar order created a payment row';

  perform public.save_pos_sales_order_for_store(token, jsonb_build_object(
    'id', zero_order_code, 'store_code', store_row.store_code,
    'staff_name', staff_row.display_name, 'shift_id', shift_row.shift_code,
    'customer_name', 'Walk-in Customer', 'payment_method', 'No Charge',
    'payments', '[]'::jsonb, 'total', 0,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', 'special-zero-test', 'name', 'Zero test item',
      'qty', 1, 'unit_price', 0, 'line_total', 0, 'is_special', true
    ))
  ));
  assert (select count(*) from public.pos_sales_orders where order_code = zero_order_code) = 1,
    'Retry duplicated the zero-dollar invoice';

  result := public.save_pos_exchange_order_for_store(token, jsonb_build_object(
    'id', exchange_order_code,
    'store_code', store_row.store_code,
    'staff_name', staff_row.display_name,
    'shift_id', shift_row.shift_code,
    'customer_name', 'Exchange Test',
    'customer_phone', '0499000001',
    'customer_code', customer_code_value,
    'payment_method', 'Exchange Credit',
    'payments', jsonb_build_array(jsonb_build_object('method', 'Exchange Credit', 'amount', 20)),
    'total', 20,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', 'special-replacement-test', 'sku', 'SPECIAL',
      'name', 'Replacement test item', 'category', 'Special Products',
      'qty', 1, 'unit_price', 20, 'line_total', 20, 'is_special', true
    )),
    'exchange_refund', jsonb_build_object(
      'order_id', original_order_code,
      'customer_code', customer_code_value,
      'reason', 'Atomic exchange test',
      'lines', jsonb_build_array(jsonb_build_object(
        'line_id', original_line_id, 'amount', 35, 'quantity', 0
      ))
    )
  ));
  assert result #>> '{order,total}' = '20.00', 'Replacement invoice total is wrong';
  assert result->>'exchange_credit_issued' = '35.00', 'Return credit amount is wrong';
  assert result->>'exchange_credit_used' = '20.00', 'Applied exchange credit is wrong';
  assert result->>'store_credit_remaining' = '15.00', 'Remaining exchange credit is wrong';

  select count(*) into refund_count
  from public.pos_sales_refunds where sales_order_id = original_order_id;
  assert refund_count = 1, 'Exchange did not create exactly one refund';
  select account.balance into balance_value
  from public.pos_store_credit_accounts account where account.customer_id = customer_id_value;
  assert balance_value = 15, 'Exchange did not leave the unused return value as Store Credit';

  perform public.save_pos_exchange_order_for_store(token, jsonb_build_object(
    'id', exchange_order_code,
    'exchange_refund', jsonb_build_object(
      'customer_code', customer_code_value,
      'lines', jsonb_build_array(jsonb_build_object('line_id', original_line_id, 'amount', 35, 'quantity', 0))
    )
  ));
  select count(*) into refund_count
  from public.pos_sales_refunds where sales_order_id = original_order_id;
  assert refund_count = 1, 'Retry issued the return credit twice';
  select account.balance into balance_value
  from public.pos_store_credit_accounts account where account.customer_id = customer_id_value;
  assert balance_value = 15, 'Retry changed the Store Credit balance';
end;
$test$;
rollback;
select 'PASS: zero sales and exchange refund/replacement checkout are atomic and idempotent.' as result;
