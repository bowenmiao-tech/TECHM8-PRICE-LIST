-- Staff-facing performance report for the Invoices page.
--
-- Everything is counted on money ACTUALLY RECEIVED, attributed to the day the
-- payment landed, so the three category totals and the payment-method totals
-- describe the same pot of money and can be reconciled against the till.
--
-- A payment is spread across its order's lines in proportion to each line's
-- value, which is exact for a fully paid order and splits a deposit fairly.
-- Refunds attach to a specific order line, so they are subtracted exactly.
--
-- Deliberately carries no cost, margin or profit: this is shown to staff.

create or replace function public.get_pos_performance_report(
  session_token text,
  target_store_code text,
  date_from date default null,
  date_to date default null,
  order_limit integer default 300
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  selected_store public.store_locations%rowtype;
  from_value date := coalesce(date_from, (now() at time zone 'Australia/Brisbane')::date);
  to_value date := coalesce(date_to, date_from, (now() at time zone 'Australia/Brisbane')::date);
  limit_value integer := least(greatest(coalesce(order_limit, 300), 1), 1000);
  report jsonb;
begin
  actor := public.pos_authorized_actor(session_token, target_store_code, null);
  if from_value > to_value then raise exception 'Start date must not be after end date'; end if;
  if to_value - from_value > 366 then raise exception 'Report range cannot exceed 367 days'; end if;

  select * into selected_store
  from public.store_locations
  where id = nullif(actor->>'store_id', '')::bigint;
  if not found then raise exception 'Store not found'; end if;

  with payment_rows as (
    select
      payment.id,
      payment.sales_order_id,
      payment.method,
      payment.amount,
      coalesce(payment.business_date, (payment.created_at at time zone 'Australia/Brisbane')::date) as paid_on
    from public.pos_sales_order_payments payment
    join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id
    where sales_order.store_id = selected_store.id
      and coalesce(payment.business_date, (payment.created_at at time zone 'Australia/Brisbane')::date)
          between from_value and to_value
  ),
  refund_rows as (
    select
      refund.id,
      refund.method,
      refund.amount,
      coalesce(refund.business_date, (refund.created_at at time zone 'Australia/Brisbane')::date) as refunded_on
    from public.pos_sales_refunds refund
    where refund.store_id = selected_store.id
      and coalesce(refund.business_date, (refund.created_at at time zone 'Australia/Brisbane')::date)
          between from_value and to_value
  ),
  -- Each line's share of its own order, used to split every payment.
  line_weights as (
    select
      sales_line.id as line_id,
      sales_line.sales_order_id,
      sales_line.line_type,
      sales_line.quantity,
      sales_line.line_total,
      sum(sales_line.line_total) over (partition by sales_line.sales_order_id) as order_line_total
    from public.pos_sales_order_lines sales_line
    where sales_line.sales_order_id in (select distinct sales_order_id from payment_rows)
  ),
  allocated as (
    select
      line_weights.line_id,
      line_weights.sales_order_id,
      line_weights.line_type,
      line_weights.quantity,
      payment_rows.paid_on,
      case when line_weights.order_line_total > 0
        then payment_rows.amount * (line_weights.line_total / line_weights.order_line_total)
        else 0 end as received
    from payment_rows
    join line_weights on line_weights.sales_order_id = payment_rows.sales_order_id
  ),
  refunded as (
    select
      sales_line.id as line_id,
      sales_line.sales_order_id,
      sales_line.line_type,
      sum(refund_line.amount) as refunded,
      sum(coalesce(refund_line.returned_quantity, 0)) as returned_quantity
    from public.pos_sales_refund_lines refund_line
    join refund_rows on refund_rows.id = refund_line.refund_id
    join public.pos_sales_order_lines sales_line on sales_line.id = refund_line.sales_order_line_id
    group by 1, 2, 3
  ),
  -- Units are booked once per order, on its first payment in range, so a
  -- balance payment later in the period does not count the goods twice.
  first_payment as (
    select sales_order_id, min(paid_on) as first_paid_on
    from payment_rows group by sales_order_id
  ),
  order_category as (
    select
      allocated.sales_order_id,
      allocated.line_type,
      round(sum(allocated.received), 2) as received,
      round(coalesce(sum(distinct_refund.refunded), 0), 2) as refunded,
      sum(case when allocated.paid_on = first_payment.first_paid_on then allocated.quantity else 0 end) as units
    from allocated
    join first_payment on first_payment.sales_order_id = allocated.sales_order_id
    left join lateral (
      select refunded.refunded
      from refunded
      where refunded.line_id = allocated.line_id
        and allocated.paid_on = first_payment.first_paid_on
    ) distinct_refund on true
    group by 1, 2
  ),
  category_rows as (
    select
      order_category.line_type,
      round(sum(order_category.received), 2) as received,
      round(sum(order_category.refunded), 2) as refunded,
      sum(order_category.units)::integer as units,
      count(distinct order_category.sales_order_id)::integer as order_count
    from order_category
    group by 1
  )
  select jsonb_build_object(
    'ok', true,
    'store_code', selected_store.store_code,
    'store_name', selected_store.store_name,
    'date_from', from_value,
    'date_to', to_value,
    'totals', jsonb_build_object(
      'received', coalesce((select round(sum(amount), 2) from payment_rows), 0),
      'refunded', coalesce((select round(sum(amount), 2) from refund_rows), 0),
      'net', coalesce((select round(sum(amount), 2) from payment_rows), 0)
             - coalesce((select round(sum(amount), 2) from refund_rows), 0),
      'order_count', coalesce((select count(distinct sales_order_id)::integer from payment_rows), 0),
      'refund_count', coalesce((select count(*)::integer from refund_rows), 0)
    ),
    'payment_totals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'method', totals.method,
        'received', totals.received,
        'refunded', totals.refunded,
        'net', totals.received - totals.refunded
      ) order by totals.received - totals.refunded desc)
      from (
        select
          method_keys.method,
          coalesce((select round(sum(amount), 2) from payment_rows where payment_rows.method = method_keys.method), 0) as received,
          coalesce((select round(sum(amount), 2) from refund_rows where refund_rows.method = method_keys.method), 0) as refunded
        from (
          select method from payment_rows
          union select method from refund_rows
        ) method_keys
      ) totals
    ), '[]'::jsonb),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', category_rows.line_type,
        'units', category_rows.units,
        'order_count', category_rows.order_count,
        'received', category_rows.received,
        'refunded', category_rows.refunded,
        'net', category_rows.received - category_rows.refunded,
        'truncated', category_rows.order_count > limit_value,
        'orders', coalesce((
          select jsonb_agg(listed.entry order by listed.received desc)
          from (
            select jsonb_build_object(
              'order_code', sales_order.order_code,
              'invoice_number', sales_order.invoice_number,
              'paid_on', order_category.received,
              'business_date', sales_order.business_date,
              'created_at', sales_order.created_at,
              'customer_name', sales_order.customer_name,
              'staff_name', sales_order.staff_name,
              'units', order_category.units,
              'received', order_category.received,
              'refunded', order_category.refunded,
              'net', order_category.received - order_category.refunded
            ) as entry,
            order_category.received
            from order_category
            join public.pos_sales_orders sales_order on sales_order.id = order_category.sales_order_id
            where order_category.line_type = category_rows.line_type
            order by order_category.received desc
            limit limit_value
          ) listed
        ), '[]'::jsonb)
      ) order by category_rows.received - category_rows.refunded desc)
      from category_rows
    ), '[]'::jsonb)
  ) into report;

  return report;
end;
$$;

revoke all on function public.get_pos_performance_report(text, text, date, date, integer)
  from public, anon, authenticated;
grant execute on function public.get_pos_performance_report(text, text, date, date, integer)
  to service_role;
