-- Refund amount must follow the quantity returned to stock.
-- Every fixture write is rolled back.
begin;
do $test$
declare
  store_id_value bigint;
  order_id_value bigint;
  line_id_value bigint;
  refund_id_value bigint;
  rejected boolean := false;
begin
  select id into store_id_value
  from public.store_locations
  where active and store_code <> 'warehouse'
  order by id
  limit 1;

  insert into public.pos_sales_orders(
    order_code, store_id, business_date, staff_name, customer_name,
    payment_method, total, amount_paid, order_payload, invoice_number
  ) values (
    'TEST-REFUND-GUARD-' || extensions.gen_random_uuid(), store_id_value,
    current_date, 'Refund Guard Test', 'Walk-in Customer', 'Card',
    70, 70, '{}'::jsonb, 910000000000 + floor(random() * 100000000)::bigint
  ) returning id into order_id_value;

  insert into public.pos_sales_order_lines(
    sales_order_id, line_number, line_type, product_id, sku, name,
    category, quantity, unit_price, line_total, line_payload
  ) values (
    order_id_value, 1, 'product', '999999991', 'TEST-REFUND-GUARD',
    'Refund guard fixture', 'Test', 2, 35, 70, '{}'::jsonb
  ) returning id into line_id_value;

  insert into public.pos_sales_refunds(
    refund_code, sales_order_id, store_id, staff_name, method, reason, amount
  ) values (
    'TEST-REFUND-GUARD-' || extensions.gen_random_uuid(), order_id_value,
    store_id_value, 'Refund Guard Test', 'Card', 'Regression test', 35
  ) returning id into refund_id_value;

  begin
    insert into public.pos_sales_refund_lines(
      refund_id, sales_order_line_id, amount, returned_quantity
    ) values (refund_id_value, line_id_value, 70, 1);
  exception when others then
    rejected := true;
  end;
  assert rejected, 'A one-item return refunded the full two-item line';

  insert into public.pos_sales_refund_lines(
    refund_id, sales_order_line_id, amount, returned_quantity
  ) values (refund_id_value, line_id_value, 35, 1);

  rejected := false;
  begin
    update public.pos_sales_refund_lines
    set amount = 70
    where refund_id = refund_id_value
      and sales_order_line_id = line_id_value;
  exception when others then
    rejected := true;
  end;
  assert rejected, 'An existing one-item return was changed to the full two-item amount';
end;
$test$;
rollback;
