-- Run as the database owner after 20261102120000; every fixture change is rolled back.
begin;
do $$
declare
  earlier public.pos_sales_orders%rowtype;
  ticket_code_value text;
  counter_before bigint;
  reused public.pos_sales_orders%rowtype;
  plain public.pos_sales_orders%rowtype;
begin
  select repair_ticket.ticket_code, sales_order.id into ticket_code_value, earlier.id
  from public.pos_sales_order_lines sales_line
  join public.pos_sales_orders sales_order on sales_order.id = sales_line.sales_order_id
  join public.pos_repair_tickets repair_ticket on repair_ticket.id = sales_line.repair_ticket_id
  where sales_line.repair_job_id is null
    and not exists (select 1 from public.pos_sales_orders other
      where other.store_id = sales_order.store_id
        and other.invoice_number = sales_order.invoice_number and other.invoice_part > 1)
  order by sales_order.created_at desc limit 1;
  assert ticket_code_value is not null, 'No billed repair card to test with';
  select * into earlier from public.pos_sales_orders where id = earlier.id;

  -- A later checkout of the same card takes a number, then gets the card's.
  update public.pos_store_invoice_counters set last_number = last_number + 1
    where store_id = earlier.store_id returning last_number into counter_before;
  insert into public.pos_sales_orders(order_code, invoice_number, store_id, business_date,
    staff_name, customer_name, payment_method, total, payment_status, amount_paid, order_payload)
  values ('TEST-REUSE-1', counter_before, earlier.store_id, current_date, 'test', 'test',
    'Cash', 10, 'paid', 10, jsonb_build_object('items', jsonb_build_array(
      jsonb_build_object('is_repair', true, 'ticket_id', ticket_code_value))))
  returning * into reused;
  assert reused.invoice_number = earlier.invoice_number, 'Repair checkout did not reuse the card invoice number';
  assert reused.invoice_part = 2, 'Second checkout should be part 2';
  assert reused.business_date = current_date, 'Reused invoice must keep its own business date';
  assert (select last_number from public.pos_store_invoice_counters where store_id = earlier.store_id)
    = counter_before - 1, 'Unused number was not handed back to the counter';

  -- A sale with no repair card keeps the next number as before.
  update public.pos_store_invoice_counters set last_number = last_number + 1
    where store_id = earlier.store_id returning last_number into counter_before;
  insert into public.pos_sales_orders(order_code, invoice_number, store_id, business_date,
    staff_name, customer_name, payment_method, total, payment_status, amount_paid, order_payload)
  values ('TEST-PLAIN-1', counter_before, earlier.store_id, current_date, 'test', 'test',
    'Cash', 10, 'paid', 10, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('sku', 'X'))))
  returning * into plain;
  assert plain.invoice_number = counter_before and plain.invoice_part = 1, 'Plain sale number changed';
  raise notice 'ok: card invoice #% reused as part %', reused.invoice_number, reused.invoice_part;
end;
$$;
rollback;
