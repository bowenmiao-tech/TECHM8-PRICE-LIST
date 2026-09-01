-- Rebuilds the per-order rollup on explicit aggregates instead of a lateral
-- join, which mis-mapped the payment date and could count a refund twice when
-- an order took two payments on the same day. Refund-only days now also appear
-- in the categories, matching what the payment totals already showed.

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
    where sales_line.sales_order_id in (select sales_order_id from payment_rows)
  ),
  allocated as (
    select
      line_weights.sales_order_id,
      line_weights.line_type,
      case when line_weights.order_line_total > 0
        then payment_rows.amount * (line_weights.line_total / line_weights.order_line_total)
        else 0 end as received
    from payment_rows
    join line_weights on line_weights.sales_order_id = payment_rows.sales_order_id
  ),
  refunded as (
    select
      sales_line.sales_order_id,
      sales_line.line_type,
      refund_line.amount
    from public.pos_sales_refund_lines refund_line
    join refund_rows on refund_rows.id = refund_line.refund_id
    join public.pos_sales_order_lines sales_line on sales_line.id = refund_line.sales_order_line_id
  ),
  -- Orders touched in this period, whether by a payment or by a refund.
  order_keys as (
    select sales_order_id, line_type from allocated
    union
    select sales_order_id, line_type from refunded
  ),
  order_rows as (
    select
      order_keys.sales_order_id,
      order_keys.line_type,
      coalesce((
        select round(sum(allocated.received), 2) from allocated
        where allocated.sales_order_id = order_keys.sales_order_id
          and allocated.line_type = order_keys.line_type
      ), 0) as received,
      coalesce((
        select round(sum(refunded.amount), 2) from refunded
        where refunded.sales_order_id = order_keys.sales_order_id
          and refunded.line_type = order_keys.line_type
      ), 0) as refunded,
      -- Counted once per order from its own lines, never per payment.
      coalesce((
        select sum(sales_line.quantity)::integer
        from public.pos_sales_order_lines sales_line
        where sales_line.sales_order_id = order_keys.sales_order_id
          and sales_line.line_type = order_keys.line_type
      ), 0) as units,
      (
        select min(payment_rows.paid_on) from payment_rows
        where payment_rows.sales_order_id = order_keys.sales_order_id
      ) as paid_on
    from order_keys
  ),
  category_rows as (
    select
      order_rows.line_type,
      round(sum(order_rows.received), 2) as received,
      round(sum(order_rows.refunded), 2) as refunded,
      sum(order_rows.units)::integer as units,
      count(*)::integer as order_count
    from order_rows
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
          select jsonb_agg(to_jsonb(listed) - 'sort_key' order by listed.sort_key desc)
          from (
            select
              sales_order.order_code,
              sales_order.invoice_number,
              order_rows.paid_on,
              sales_order.business_date,
              sales_order.created_at,
              sales_order.customer_name,
              sales_order.staff_name,
              order_rows.units,
              order_rows.received,
              order_rows.refunded,
              order_rows.received - order_rows.refunded as net,
              order_rows.received - order_rows.refunded as sort_key
            from order_rows
            join public.pos_sales_orders sales_order on sales_order.id = order_rows.sales_order_id
            where order_rows.line_type = category_rows.line_type
            order by order_rows.received - order_rows.refunded desc
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
