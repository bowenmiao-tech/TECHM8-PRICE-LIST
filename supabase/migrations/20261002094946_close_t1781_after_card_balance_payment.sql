-- Owner-requested correction for RepairDesk ticket T-1781 (North Lakes).
-- Luke paid the $180.00 balance on invoice #4912 by card today and collected
-- the phone, but the imported invoice was never linked to the card, so POS
-- could neither take the balance nor finish the card. The device was also
-- recorded as a Pixel 10 instead of a Pixel 10 Pro.
-- The payment is credited to the staff member on today's North Lakes shift,
-- as a counter payment would be. The RepairDesk source record is untouched.
do $fix$
declare
  ticket public.pos_repair_tickets%rowtype;
  invoice public.pos_sales_orders%rowtype;
  shift public.pos_store_shifts%rowtype;
  repair_line_id bigint;
  today_value date := (now() at time zone 'Australia/Brisbane')::date;
  activity_ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  select * into strict ticket from public.pos_repair_tickets
  where ticket_code = 'T-1781' for update;
  select * into strict invoice from public.pos_sales_orders
  where order_code = 'RD-NL-INV-4912' for update;

  if ticket.store_id <> (select id from public.store_locations where store_code = 'northlakes')
    or ticket.customer_name <> 'Luke'
    or ticket.title <> 'Pixel 10'
    or not ticket.active or ticket.closed_at is not null
    or invoice.store_id <> ticket.store_id
    or invoice.invoice_number <> 4912
    or invoice.total <> 339.00 or invoice.amount_paid <> 159.00
    or invoice.payment_status <> 'deposit' then
    raise exception 'T-1781 / invoice #4912 no longer match the requested correction';
  end if;

  select line.id into strict repair_line_id
  from public.pos_sales_order_lines line
  where line.sales_order_id = invoice.id and line.line_type = 'repair'
    and line.repair_ticket_id is null and line.line_total = 339.00;

  select * into strict shift from public.pos_store_shifts
  where store_id = ticket.store_id and business_date = today_value and status = 'open'
    and opened_by = 'Joanna Chen';

  update public.pos_sales_order_lines
  set repair_ticket_id = ticket.id
  where id = repair_line_id;

  insert into public.pos_sales_order_payments (
    sales_order_id, payment_number, method, amount,
    shift_id, staff_name, business_date, taken_at, created_at
  ) values (
    invoice.id,
    (select coalesce(max(payment_number), 0) + 1 from public.pos_sales_order_payments where sales_order_id = invoice.id),
    'Card', 180.00,
    shift.shift_code, shift.opened_by, today_value, now(), now()
  );

  update public.pos_sales_orders
  set amount_paid = 339.00,
      payment_status = 'paid',
      payment_method = (
        select string_agg(distinct payment.method, ' + ' order by payment.method)
        from public.pos_sales_order_payments payment
        where payment.sales_order_id = invoice.id
      )
  where id = invoice.id;

  update public.pos_repair_tickets
  set title = 'Pixel 10 Pro',
      status = 'closed',
      resolution = 'repaired',
      ready_for_pickup_at = coalesce(ready_for_pickup_at, now()),
      closed_at = now(),
      updated_by = 'Admin (owner-requested correction)',
      status_updated_at = now(),
      activity = jsonb_build_array(
        jsonb_build_object(
          'id', 'ACT-' || (activity_ms + 2), 'type', 'finished',
          'text', 'closed this repair card after invoice #4912 - repaired; customer collected the device',
          'staffName', 'Admin', 'at', now()),
        jsonb_build_object(
          'id', 'ACT-' || (activity_ms + 1), 'type', 'paid',
          'text', 'recorded the $180.00 card balance on invoice #4912 (taken by ' || shift.opened_by || ') at the owner request',
          'staffName', 'Admin', 'at', now()),
        jsonb_build_object(
          'id', 'ACT-' || activity_ms, 'type', 'details',
          'text', 'changed the device from Pixel 10 to Pixel 10 Pro at the owner request',
          'staffName', 'Admin', 'at', now())
      ) || coalesce(activity, '[]'::jsonb)
  where id = ticket.id;
end;
$fix$;
