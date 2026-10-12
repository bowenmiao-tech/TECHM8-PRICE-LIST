-- A deposit balance checked out with new cart items must be one transaction:
-- new items paid first, the rest on the earlier invoice, retries idempotent,
-- and a stale or short checkout must leave nothing behind.
-- Every fixture write is rolled back.
begin;
do $test$
declare
  token text := gen_random_uuid()::text;
  store_row public.store_locations%rowtype;
  shift_row public.pos_store_shifts%rowtype;
  staff_row public.staff_directory%rowtype;
  repair_order_code text := 'TEST-BALANCE-REPAIR-' || gen_random_uuid()::text;
  second_order_code text := 'TEST-BALANCE-SECOND-' || gen_random_uuid()::text;
  sale_code text := 'TEST-BALANCE-SALE-' || gen_random_uuid()::text;
  rejected_sale_code text := 'TEST-BALANCE-REJECTED-' || gen_random_uuid()::text;
  partial_sale_code text := 'TEST-BALANCE-PARTIAL-' || gen_random_uuid()::text;
  repair_order_id bigint;
  second_order_id bigint;
  repair_invoice bigint := 990000000000 + floor(random() * 100000000)::bigint;
  result jsonb;
  saved_order public.pos_sales_orders%rowtype;
  payment_count integer;
  failed boolean;
  base jsonb;
  sale jsonb;
begin
  select shift_record.* into shift_row
  from public.pos_store_shifts shift_record
  where shift_record.status = 'open'
    and shift_record.business_date = (now() at time zone 'Australia/Brisbane')::date
    and shift_record.opening_confirmed_at is not null
    and exists (
      select 1 from public.staff_directory staff
      where staff.active
        and lower(staff.display_name) = lower(shift_record.current_staff_name)
        and public.staff_has_store_access(staff.id, shift_record.store_id)
    )
  order by shift_record.id desc
  limit 1;
  if shift_row.id is null then raise exception 'No open shift available for balance checkout test'; end if;
  select * into store_row from public.store_locations where id = shift_row.store_id;

  select staff.* into staff_row
  from public.staff_directory staff
  where staff.active
    and lower(staff.display_name) = lower(shift_row.current_staff_name)
    and public.staff_has_store_access(staff.id, store_row.id)
  limit 1;
  if staff_row.id is null then raise exception 'Open-shift staff is unavailable for balance checkout test'; end if;

  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
  values (
    staff_row.id,
    extensions.crypt(token, extensions.gen_salt('bf')),
    encode(extensions.digest(token, 'sha256'), 'hex'),
    now() + interval '5 minutes'
  );

  -- $250 repair invoice with a $50 deposit, and a $100 invoice with $20 paid.
  insert into public.pos_sales_orders(
    order_code, invoice_number, store_id, business_date, staff_name, shift_id,
    customer_name, customer_phone, payment_method, total, amount_paid, payment_status, order_payload
  ) values (
    repair_order_code, repair_invoice, store_row.id, shift_row.business_date,
    staff_row.display_name, shift_row.shift_code, 'Balance Test', '0499000002',
    'Card', 250, 50, 'deposit', '{}'::jsonb
  ) returning id into repair_order_id;
  insert into public.pos_sales_order_lines(
    sales_order_id, line_number, line_type, product_id, sku, name, category, quantity, unit_price, line_total
  ) values (
    repair_order_id, 1, 'special', 'special-balance-test', 'SPECIAL', 'Deposit test item',
    'Special Products', 1, 250, 250
  );
  insert into public.pos_sales_order_payments(sales_order_id, payment_number, method, amount)
  values (repair_order_id, 1, 'Card', 50);

  insert into public.pos_sales_orders(
    order_code, invoice_number, store_id, business_date, staff_name, shift_id,
    customer_name, customer_phone, payment_method, total, amount_paid, payment_status, order_payload
  ) values (
    second_order_code, repair_invoice + 1, store_row.id, shift_row.business_date,
    staff_row.display_name, shift_row.shift_code, 'Balance Test', '0499000002',
    'Cash', 100, 20, 'deposit', '{}'::jsonb
  ) returning id into second_order_id;
  insert into public.pos_sales_order_lines(
    sales_order_id, line_number, line_type, product_id, sku, name, category, quantity, unit_price, line_total
  ) values (
    second_order_id, 1, 'special', 'special-balance-test-2', 'SPECIAL', 'Second deposit item',
    'Special Products', 1, 100, 100
  );
  insert into public.pos_sales_order_payments(sales_order_id, payment_number, method, amount)
  values (second_order_id, 1, 'Cash', 20);

  base := jsonb_build_object(
    'store_code', store_row.store_code,
    'staff_name', staff_row.display_name,
    'shift_id', shift_row.shift_code
  );
  sale := jsonb_build_object(
    'id', sale_code,
    'store_code', store_row.store_code,
    'staff_name', staff_row.display_name,
    'shift_id', shift_row.shift_code,
    'customer_name', 'Balance Test',
    'customer_phone', '0499000002',
    'payment_method', 'Card',
    'payments', jsonb_build_array(jsonb_build_object('method', 'Card', 'amount', 30)),
    'total', 30,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', 'special-case-test', 'sku', 'SPECIAL', 'name', 'Test case',
      'category', 'Special Products', 'qty', 1, 'unit_price', 30, 'line_total', 30, 'is_special', true
    ))
  );

  -- Stale balance: nothing is written, not even the new sale.
  failed := false;
  begin
    perform public.checkout_pos_cart_with_balances_for_store(token, base || jsonb_build_object(
      'order', sale || jsonb_build_object('id', rejected_sale_code),
      'balances', jsonb_build_array(jsonb_build_object(
        'order_id', repair_order_code, 'expected_balance', 180,
        'payments', jsonb_build_array(jsonb_build_object('method', 'Card', 'amount', 180))
      ))
    ));
  exception when others then
    failed := sqlerrm like '%now has 200.00 owing%';
  end;
  assert failed, 'A stale balance amount was not refused';
  assert not exists (select 1 from public.pos_sales_orders where order_code = rejected_sale_code),
    'A refused balance checkout still saved the new sale';

  -- New items short-paid: refused before any balance payment.
  failed := false;
  begin
    perform public.checkout_pos_cart_with_balances_for_store(token, base || jsonb_build_object(
      'order', sale || jsonb_build_object(
        'id', rejected_sale_code,
        'payments', jsonb_build_array(jsonb_build_object('method', 'Card', 'amount', 20))
      ),
      'balances', jsonb_build_array(jsonb_build_object(
        'order_id', repair_order_code, 'expected_balance', 200,
        'payments', jsonb_build_array(jsonb_build_object('method', 'Card', 'amount', 10))
      ))
    ));
  exception when others then
    failed := sqlerrm like '%new items must be paid in full%';
  end;
  assert failed, 'Short-paid new items were not refused';
  select count(*) into payment_count from public.pos_sales_order_payments where sales_order_id = repair_order_id;
  assert payment_count = 1, 'A refused checkout still added a balance payment';

  -- The same invoice twice is refused.
  failed := false;
  begin
    perform public.checkout_pos_cart_with_balances_for_store(token, base || jsonb_build_object(
      'order', null,
      'balances', jsonb_build_array(
        jsonb_build_object('order_id', second_order_code, 'expected_balance', 80,
          'payments', jsonb_build_array(jsonb_build_object('method', 'Cash', 'amount', 10))),
        jsonb_build_object('order_id', second_order_code, 'expected_balance', 80,
          'payments', jsonb_build_array(jsonb_build_object('method', 'Cash', 'amount', 10)))
      )
    ));
  exception when others then
    failed := sqlerrm like '%same invoice is in the cart twice%';
  end;
  assert failed, 'A duplicated invoice balance was not refused';
  select count(*) into payment_count from public.pos_sales_order_payments where sales_order_id = second_order_id;
  assert payment_count = 1, 'A refused duplicate still paid the first copy';

  -- $30 case + $200 balance = $230, paid $100 cash + $130 card. The case
  -- takes $30 of the cash; the balance gets $70 cash + $130 card.
  result := public.checkout_pos_cart_with_balances_for_store(token, base || jsonb_build_object(
    'order', sale || jsonb_build_object(
      'payment_method', 'Cash',
      'payments', jsonb_build_array(jsonb_build_object('method', 'Cash', 'amount', 30))
    ),
    'balances', jsonb_build_array(jsonb_build_object(
      'order_id', repair_order_code, 'expected_balance', 200,
      'payments', jsonb_build_array(
        jsonb_build_object('method', 'Cash', 'amount', 70),
        jsonb_build_object('method', 'Card', 'amount', 130)
      )
    ))
  ));
  assert (result->>'ok')::boolean, 'Combined checkout failed';
  assert result #>> '{order,total}' = '30.00', 'New invoice total should hold only the new items';
  assert result #>> '{order,payment_status}' = 'paid', 'New invoice should be paid in full';
  assert result #>> '{order,balance_settlements,0,invoice_number}' = repair_invoice::text,
    'New invoice does not record which balance it settled';
  assert result #>> '{order,balance_settlements,0,amount}' = '200.00', 'Settlement amount is wrong';
  assert result #>> '{order,balance_settlements,0,balance_after}' = '0.00', 'Settlement remaining is wrong';
  assert jsonb_array_length(result #> '{order,balance_settlements,0,payments}') = 2, 'Settlement payments missing';
  assert jsonb_array_length(result->'balance_orders') = 1, 'Paid balance invoice not returned';
  assert result #>> '{balance_orders,0,payment_status}' = 'paid', 'Balance invoice not marked paid';

  select * into saved_order from public.pos_sales_orders where id = repair_order_id;
  assert saved_order.amount_paid = 250 and saved_order.payment_status = 'paid', 'Balance invoice totals are wrong';
  assert saved_order.total = 250, 'Balance invoice total changed';
  select count(*) into payment_count from public.pos_sales_order_payments where sales_order_id = repair_order_id;
  assert payment_count = 3, 'Balance invoice should have the deposit plus two new payment rows';
  assert (
    select sum(payment.amount) from public.pos_sales_order_payments payment
    join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id
    where sales_order.order_code in (sale_code, repair_order_code)
      and payment.shift_id = shift_row.shift_code
  ) = 230, 'Today''s takings should be exactly the $230 charged';

  -- A retry of the same checkout returns the saved result and pays nothing again.
  result := public.checkout_pos_cart_with_balances_for_store(token, base || jsonb_build_object(
    'order', sale,
    'balances', jsonb_build_array(jsonb_build_object(
      'order_id', repair_order_code, 'expected_balance', 200,
      'payments', jsonb_build_array(jsonb_build_object('method', 'Card', 'amount', 200))
    ))
  ));
  assert (result->>'replayed')::boolean, 'Retry was not recognised';
  assert result #>> '{balance_orders,0,id}' = repair_order_code, 'Retry did not return the balance invoice';
  select count(*) into payment_count from public.pos_sales_order_payments where sales_order_id = repair_order_id;
  assert payment_count = 3, 'Retry paid the balance twice';
  assert (select count(*) from public.pos_sales_orders where order_code = sale_code) = 1, 'Retry duplicated the sale';

  -- Part payment: $10 item paid in full, $50 of the $80 balance, $30 left owing.
  result := public.checkout_pos_cart_with_balances_for_store(token, base || jsonb_build_object(
    'order', sale || jsonb_build_object(
      'id', partial_sale_code,
      'payments', jsonb_build_array(jsonb_build_object('method', 'Card', 'amount', 10)),
      'total', 10,
      'items', jsonb_build_array(jsonb_build_object(
        'product_id', 'special-protector-test', 'sku', 'SPECIAL', 'name', 'Test protector',
        'category', 'Special Products', 'qty', 1, 'unit_price', 10, 'line_total', 10, 'is_special', true
      ))
    ),
    'balances', jsonb_build_array(jsonb_build_object(
      'order_id', second_order_code, 'expected_balance', 80,
      'payments', jsonb_build_array(jsonb_build_object('method', 'Card', 'amount', 50))
    ))
  ));
  assert result #>> '{order,payment_status}' = 'paid', 'Part payment left the new items owing';
  assert result #>> '{balance_orders,0,payment_status}' = 'deposit', 'Part-paid balance should stay a deposit';
  assert result #>> '{balance_orders,0,balance_due}' = '30.00', 'Part-paid balance remaining is wrong';

  -- Balance only, no new items.
  result := public.checkout_pos_cart_with_balances_for_store(token, base || jsonb_build_object(
    'order', null,
    'balances', jsonb_build_array(jsonb_build_object(
      'order_id', second_order_code, 'expected_balance', 30,
      'payments', jsonb_build_array(jsonb_build_object('method', 'Cash', 'amount', 30))
    ))
  ));
  assert result->'order' = 'null'::jsonb, 'Balance-only checkout should not create a sale';
  assert result #>> '{balance_orders,0,payment_status}' = 'paid', 'Balance-only checkout did not pay the invoice';
end;
$test$;
rollback;
select 'PASS: invoice balances check out with new cart items atomically and idempotently.' as result;
