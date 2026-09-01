-- Finalize the staff performance report semantics:
--   * returned quantities reduce the displayed item count and remain visible;
--   * payment attribution follows the staff member who took the money;
--   * shift cash variance and handover staff are available to the print slip.

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

  with payment_rows as materialized (
    select
      payment.sales_order_id,
      payment.method,
      payment.amount,
      coalesce(payment.business_date, (payment.created_at at time zone 'Australia/Brisbane')::date) as paid_on,
      coalesce(nullif(trim(payment.staff_name), ''), nullif(trim(sales_order.staff_name), ''), 'Unknown') as collector_name
    from public.pos_sales_order_payments payment
    join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id
    where sales_order.store_id = selected_store.id
      and coalesce(payment.business_date, (payment.created_at at time zone 'Australia/Brisbane')::date)
          between from_value and to_value
  ),
  refund_rows as materialized (
    select
      refund.id,
      refund.sales_order_id,
      refund.method,
      refund.amount,
      coalesce(nullif(trim(refund.staff_name), ''), 'Unknown') as refund_staff_name
    from public.pos_sales_refunds refund
    where refund.store_id = selected_store.id
      and coalesce(refund.business_date, (refund.created_at at time zone 'Australia/Brisbane')::date)
          between from_value and to_value
  ),
  paid_orders as (
    select
      sales_order_id,
      min(paid_on) as paid_on,
      sum(amount) as order_received,
      string_agg(distinct collector_name, ', ' order by collector_name) as collector_names
    from payment_rows
    group by 1
  ),
  line_weights as (
    select
      sales_line.sales_order_id,
      sales_line.line_type,
      sales_line.line_total,
      sum(sales_line.line_total) over (partition by sales_line.sales_order_id) as order_line_total
    from public.pos_sales_order_lines sales_line
    join paid_orders on paid_orders.sales_order_id = sales_line.sales_order_id
  ),
  order_received as (
    select
      line_weights.sales_order_id,
      line_weights.line_type,
      round(sum(case when line_weights.order_line_total <> 0
        then paid_orders.order_received * (line_weights.line_total / line_weights.order_line_total)
        else 0 end), 2) as received
    from line_weights
    join paid_orders on paid_orders.sales_order_id = line_weights.sales_order_id
    group by 1, 2
  ),
  order_refunded as (
    select
      sales_line.sales_order_id,
      sales_line.line_type,
      round(sum(refund_line.amount), 2) as refunded,
      sum(coalesce(refund_line.returned_quantity, 0))::integer as returned_units,
      string_agg(distinct refund_rows.refund_staff_name, ', ' order by refund_rows.refund_staff_name) as refund_staff_names
    from public.pos_sales_refund_lines refund_line
    join refund_rows on refund_rows.id = refund_line.refund_id
    join public.pos_sales_order_lines sales_line on sales_line.id = refund_line.sales_order_line_id
    group by 1, 2
  ),
  order_units as (
    select sales_order_id, line_type, sum(quantity)::integer as gross_units
    from public.pos_sales_order_lines
    where sales_order_id in (select sales_order_id from paid_orders)
       or sales_order_id in (select sales_order_id from order_refunded)
    group by 1, 2
  ),
  order_rows as (
    select
      coalesce(received_side.sales_order_id, refunded_side.sales_order_id) as sales_order_id,
      coalesce(received_side.line_type, refunded_side.line_type) as line_type,
      coalesce(received_side.received, 0) as received,
      coalesce(refunded_side.refunded, 0) as refunded,
      coalesce(order_units.gross_units, 0) as gross_units,
      coalesce(refunded_side.returned_units, 0) as returned_units,
      coalesce(order_units.gross_units, 0) - coalesce(refunded_side.returned_units, 0) as units,
      paid_orders.paid_on,
      paid_orders.collector_names,
      refunded_side.refund_staff_names
    from order_received received_side
    full outer join order_refunded refunded_side
      on refunded_side.sales_order_id = received_side.sales_order_id
     and refunded_side.line_type = received_side.line_type
    left join order_units
      on order_units.sales_order_id = coalesce(received_side.sales_order_id, refunded_side.sales_order_id)
     and order_units.line_type = coalesce(received_side.line_type, refunded_side.line_type)
    left join paid_orders
      on paid_orders.sales_order_id = coalesce(received_side.sales_order_id, refunded_side.sales_order_id)
  ),
  category_rows as (
    select
      line_type,
      round(sum(received), 2) as received,
      round(sum(refunded), 2) as refunded,
      sum(gross_units)::integer as gross_units,
      sum(returned_units)::integer as returned_units,
      sum(units)::integer as units,
      count(*)::integer as order_count
    from order_rows
    group by 1
  ),
  ranked_orders as (
    select
      order_rows.*,
      row_number() over (partition by order_rows.line_type order by order_rows.received - order_rows.refunded desc) as rank
    from order_rows
  ),
  payment_methods as (
    select
      method_keys.method,
      coalesce(paid.received, 0) as received,
      coalesce(given_back.refunded, 0) as refunded
    from (
      select method from payment_rows
      union
      select method from refund_rows
    ) method_keys
    left join (select method, round(sum(amount), 2) as received from payment_rows group by 1) paid
      on paid.method = method_keys.method
    left join (select method, round(sum(amount), 2) as refunded from refund_rows group by 1) given_back
      on given_back.method = method_keys.method
  ),
  shift_rows as materialized (
    select
      shift_record.status,
      shift_record.closed_by,
      case
        when shift_record.differences ? 'cash'
          then nullif(shift_record.differences->>'cash', '')::numeric
        else null
      end as cash_difference
    from public.pos_store_shifts shift_record
    where shift_record.store_id = selected_store.id
      and shift_record.business_date between from_value and to_value
  ),
  shift_summary as (
    select
      count(*) filter (where status = 'open')::integer as open_shift_count,
      count(*) filter (where status = 'closed')::integer as closed_shift_count,
      count(cash_difference) > 0 as cash_difference_recorded,
      coalesce(round(sum(cash_difference), 2), 0) as cash_difference,
      string_agg(distinct trim(closed_by), ', ' order by trim(closed_by)) filter (
        where nullif(trim(closed_by), '') is not null
          and lower(trim(closed_by)) <> 'system daily reset'
      ) as handover_staff
    from shift_rows
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
      'order_count', (select count(*)::integer from paid_orders),
      'refund_count', (select count(*)::integer from refund_rows),
      'returned_units', coalesce((select sum(returned_units)::integer from order_refunded), 0),
      'unallocated', coalesce((select round(sum(amount), 2) from payment_rows), 0)
                     - coalesce((select round(sum(received), 2) from order_received), 0)
    ),
    'shift_summary', (select jsonb_build_object(
      'open_shift_count', open_shift_count,
      'closed_shift_count', closed_shift_count,
      'cash_difference_recorded', cash_difference_recorded,
      'cash_difference', cash_difference,
      'handover_staff', handover_staff
    ) from shift_summary),
    'payment_totals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'method', method, 'received', received, 'refunded', refunded, 'net', received - refunded
      ) order by received - refunded desc)
      from payment_methods
    ), '[]'::jsonb),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', category_rows.line_type,
        'gross_units', category_rows.gross_units,
        'returned_units', category_rows.returned_units,
        'units', category_rows.units,
        'order_count', category_rows.order_count,
        'received', category_rows.received,
        'refunded', category_rows.refunded,
        'net', category_rows.received - category_rows.refunded,
        'truncated', category_rows.order_count > limit_value,
        'orders', coalesce((
          select jsonb_agg(jsonb_build_object(
            'order_code', sales_order.order_code,
            'invoice_number', sales_order.invoice_number,
            'paid_on', ranked_orders.paid_on,
            'business_date', sales_order.business_date,
            'created_at', sales_order.created_at,
            'customer_name', sales_order.customer_name,
            'staff_name', ranked_orders.collector_names,
            'refund_staff_name', ranked_orders.refund_staff_names,
            'gross_units', ranked_orders.gross_units,
            'returned_units', ranked_orders.returned_units,
            'units', ranked_orders.units,
            'received', ranked_orders.received,
            'refunded', ranked_orders.refunded,
            'net', ranked_orders.received - ranked_orders.refunded
          ) order by ranked_orders.received - ranked_orders.refunded desc)
          from ranked_orders
          join public.pos_sales_orders sales_order on sales_order.id = ranked_orders.sales_order_id
          where ranked_orders.line_type = category_rows.line_type
            and ranked_orders.rank <= limit_value
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
