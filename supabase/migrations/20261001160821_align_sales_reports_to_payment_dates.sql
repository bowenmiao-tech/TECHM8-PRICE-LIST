-- Shared cash-basis ledger for POS performance and the admin overview/detail.
-- No orders, payments or dates are rewritten. Store credit is not new cash.
create or replace function public.pos_takings_line_movements(
  target_store_ids bigint[], date_from date, date_to date
)
returns table (
  event_type text, event_key text, transaction_at timestamptz, transaction_date date,
  store_id bigint, sales_order_id bigint, line_id bigint, line_type text,
  amount numeric, quantity integer, staff_name text, payment_method text,
  refund_code text, reason text
)
language sql stable security invoker set search_path = '' as $ledger$
  with payments as materialized (
    select p.id, p.sales_order_id, o.store_id, p.amount,
      coalesce(p.taken_at,p.created_at) transaction_at,
      coalesce(p.business_date,(p.created_at at time zone 'Australia/Brisbane')::date) transaction_date,
      coalesce(nullif(trim(p.staff_name),''),nullif(trim(o.staff_name),''),'Unknown') staff_name,
      p.method
    from public.pos_sales_order_payments p
    join public.pos_sales_orders o on o.id=p.sales_order_id
    where o.store_id=any(target_store_ids)
      and coalesce(p.business_date,(p.created_at at time zone 'Australia/Brisbane')::date) between date_from and date_to
      and lower(trim(p.method)) <> 'store credit'
  ), weights as materialized (
    select l.*, sum(l.line_total) over(partition by l.sales_order_id) total_weight,
      sum(l.line_total) over(partition by l.sales_order_id order by l.line_number,l.id rows unbounded preceding) cumulative_weight
    from public.pos_sales_order_lines l
    where l.sales_order_id in (select p.sales_order_id from payments p)
  ), refunds as materialized (
    select r.* from public.pos_sales_refunds r
    where r.store_id=any(target_store_ids)
      and coalesce(r.business_date,(r.created_at at time zone 'Australia/Brisbane')::date) between date_from and date_to
      and lower(trim(r.method)) <> 'store credit'
  )
  select 'sale'::text,'payment:'||p.id,p.transaction_at,p.transaction_date,
    p.store_id,p.sales_order_id,w.id,
    case when w.line_type in ('product','retail') then 'retail' when w.line_type in ('repair','used_device') then w.line_type else 'other' end,
    -- Cumulative rounding allocates every cent exactly once, even across dates.
    round(p.amount*w.cumulative_weight/w.total_weight,2)
      -round(p.amount*(w.cumulative_weight-w.line_total)/w.total_weight,2),
    w.quantity,p.staff_name,p.method,''::text,''::text
  from payments p join weights w on w.sales_order_id=p.sales_order_id and w.total_weight<>0
  union all
  select 'sale','payment:'||p.id,p.transaction_at,p.transaction_date,
    p.store_id,p.sales_order_id,null::bigint,'other',p.amount,0,p.staff_name,p.method,'',''
  from payments p where not exists(select 1 from weights w where w.sales_order_id=p.sales_order_id and w.total_weight<>0)
  union all
  select 'refund','refund:'||r.id,r.created_at,
    coalesce(r.business_date,(r.created_at at time zone 'Australia/Brisbane')::date),
    r.store_id,r.sales_order_id,l.id,
    case when l.line_type in ('product','retail') then 'retail' when l.line_type in ('repair','used_device') then l.line_type else 'other' end,
    -rl.amount,coalesce(rl.returned_quantity,0),r.staff_name,r.method,r.refund_code,r.reason
  from refunds r join public.pos_sales_refund_lines rl on rl.refund_id=r.id
  join public.pos_sales_order_lines l on l.id=rl.sales_order_line_id
  union all
  select 'refund','refund:'||r.id,r.created_at,
    coalesce(r.business_date,(r.created_at at time zone 'Australia/Brisbane')::date),
    r.store_id,r.sales_order_id,null::bigint,'other',
    -(r.amount-coalesce((select sum(rl.amount) from public.pos_sales_refund_lines rl where rl.refund_id=r.id),0)),
    0,r.staff_name,r.method,r.refund_code,r.reason
  from refunds r where r.amount<>coalesce((select sum(rl.amount) from public.pos_sales_refund_lines rl where rl.refund_id=r.id),0);
$ledger$;
revoke all on function public.pos_takings_line_movements(bigint[],date,date) from public,anon,authenticated;
grant execute on function public.pos_takings_line_movements(bigint[],date,date) to service_role;

create or replace function public.get_admin_sales_overview(
  session_token text, date_from date default null, date_to date default null
)
returns jsonb language plpgsql security definer set search_path = '' as $overview$
declare
  from_value date := coalesce(date_from,(now() at time zone 'Australia/Brisbane')::date);
  to_value date := coalesce(date_to,date_from,(now() at time zone 'Australia/Brisbane')::date);
  result_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  if from_value>to_value then raise exception 'Start date must not be after end date'; end if;
  if to_value-from_value>366 then raise exception 'Report range cannot exceed 367 days'; end if;
  with selected_stores as materialized (
    select s.id,s.store_code,s.store_name,
      array_position(array['parkridge','fairfield','northlakes','toowong']::text[],s.store_code) display_order
    from public.store_locations s where s.active and s.store_code=any(array['parkridge','fairfield','northlakes','toowong']::text[])
  ), movements as materialized (
    select * from public.pos_takings_line_movements(array(select id from selected_stores),from_value,to_value)
  ), store_values as (
    select s.store_code,s.store_name,s.display_order,
      coalesce(sum(m.amount) filter(where m.event_type='sale'),0) gross_sales,
      -coalesce(sum(m.amount) filter(where m.event_type='refund'),0) refunds,
      coalesce(sum(m.amount),0) net_sales,
      coalesce(sum(m.amount) filter(where m.event_type='sale'),0) payments_received,
      count(distinct m.sales_order_id) filter(where m.event_type='sale')::integer invoice_count,
      count(distinct m.event_key) filter(where m.event_type='refund')::integer refund_count,
      coalesce(sum(m.amount) filter(where m.line_type='repair'),0) repairs,
      coalesce(sum(m.amount) filter(where m.line_type='used_device'),0) mis,
      coalesce(sum(m.amount) filter(where m.line_type='retail'),0) products,
      coalesce(sum(m.amount) filter(where m.line_type not in ('repair','used_device','retail')),0) other
    from selected_stores s left join movements m on m.store_id=s.id
    group by s.id,s.store_code,s.store_name,s.display_order
  ), totals as (
    select coalesce(sum(gross_sales),0) gross_sales,coalesce(sum(refunds),0) refunds,
      coalesce(sum(net_sales),0) net_sales,coalesce(sum(payments_received),0) payments_received,
      coalesce(sum(invoice_count),0) invoice_count,coalesce(sum(refund_count),0) refund_count,
      coalesce(sum(repairs),0) repairs,coalesce(sum(mis),0) mis,coalesce(sum(products),0) products,coalesce(sum(other),0) other
    from store_values
  )
  select jsonb_build_object('ok',true,'accounting_basis','payments','date_from',from_value,'date_to',to_value,'generated_at',now(),
    'totals',to_jsonb(t)||jsonb_build_object('gst',round(t.net_sales/11,2)),
    'stores',coalesce((select jsonb_agg((to_jsonb(s)-'display_order')||jsonb_build_object(
      'gst',round(s.net_sales/11,2),'average_sale',case when s.invoice_count>0 then round(s.net_sales/s.invoice_count,2) else 0 end
    ) order by s.display_order) from store_values s),'[]'::jsonb)) into result_payload from totals t;
  return result_payload;
end;
$overview$;

CREATE OR REPLACE FUNCTION public.get_pos_performance_report_before_store_credit(session_token text, target_store_code text, date_from date DEFAULT NULL::date, date_to date DEFAULT NULL::date, order_limit integer DEFAULT 300)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  with takings_movements as materialized (
    select * from public.pos_takings_line_movements(array[selected_store.id],from_value,to_value)
  ), payment_rows as materialized (
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
    where lower(trim(method)) <> 'store credit'
    group by 1
  ),
  order_received as (
    select sales_order_id,line_type,sum(amount) as received
    from takings_movements where event_type='sale' group by 1,2
  ),
  order_refunded as (
    select sales_order_id,line_type,-sum(amount) as refunded,
      sum(quantity)::integer as returned_units,
      string_agg(distinct staff_name, ', ' order by staff_name) as refund_staff_names
    from takings_movements where event_type='refund' group by 1,2
  ),
  order_units as (
    select sales_order_id, case when line_type in ('product','retail') then 'retail' when line_type in ('repair','used_device') then line_type else 'other' end as line_type, sum(quantity)::integer as gross_units
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
  -- Daily takings for the trend chart: a fixed 30-day window ending on the
  -- report end date, aggregated once per day rather than per row.
  trend_payments as (
    select coalesce(payment.business_date, (payment.created_at at time zone 'Australia/Brisbane')::date) as day,
           sum(payment.amount) as received
    from public.pos_sales_order_payments payment
    join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id
    where sales_order.store_id = selected_store.id
      and lower(trim(payment.method)) <> 'store credit'
      and coalesce(payment.business_date, (payment.created_at at time zone 'Australia/Brisbane')::date)
          between to_value - 29 and to_value
    group by 1
  ),
  trend_refunds as (
    select coalesce(refund.business_date, (refund.created_at at time zone 'Australia/Brisbane')::date) as day,
           sum(refund.amount) as refunded
    from public.pos_sales_refunds refund
    where refund.store_id = selected_store.id
      and lower(trim(refund.method)) <> 'store credit'
      and coalesce(refund.business_date, (refund.created_at at time zone 'Australia/Brisbane')::date)
          between to_value - 29 and to_value
    group by 1
  ),
  daily_trend_rows as (
    select
      day_series::date as day,
      coalesce(trend_payments.received, 0) as received,
      coalesce(trend_refunds.refunded, 0) as refunded
    from generate_series(to_value - 29, to_value, interval '1 day') as day_series
    left join trend_payments on trend_payments.day = day_series::date
    left join trend_refunds on trend_refunds.day = day_series::date
  ),
  hourly_payments as (
    select extract(hour from coalesce(payment.taken_at, payment.created_at) at time zone 'Australia/Brisbane')::int as hour,
           sum(payment.amount) as received,
           count(distinct payment.sales_order_id) as order_count
    from public.pos_sales_order_payments payment
    join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id
    where sales_order.store_id = selected_store.id
      and lower(trim(payment.method)) <> 'store credit'
      and from_value = to_value
      and coalesce(payment.business_date, (payment.created_at at time zone 'Australia/Brisbane')::date) = from_value
    group by 1
  ),
  hourly_refunds as (
    select extract(hour from refund.created_at at time zone 'Australia/Brisbane')::int as hour,
           sum(refund.amount) as refunded
    from public.pos_sales_refunds refund
    where refund.store_id = selected_store.id
      and lower(trim(refund.method)) <> 'store credit'
      and from_value = to_value
      and coalesce(refund.business_date, (refund.created_at at time zone 'Australia/Brisbane')::date) = from_value
    group by 1
  ),
  hourly_bounds as (
    select min(hour) as first_hour, max(hour) as last_hour
    from (
      select hour from hourly_payments
      union all
      select hour from hourly_refunds
    ) active_hours
  ),
  hourly_rows as (
    select
      hour_series as hour,
      coalesce(hourly_payments.received, 0) as received,
      coalesce(hourly_refunds.refunded, 0) as refunded,
      coalesce(hourly_payments.order_count, 0) as order_count
    from hourly_bounds
    cross join generate_series(
      least(hourly_bounds.first_hour, 9),
      greatest(hourly_bounds.last_hour, 17)
    ) as hour_series
    left join hourly_payments on hourly_payments.hour = hour_series
    left join hourly_refunds on hourly_refunds.hour = hour_series
    where hourly_bounds.first_hour is not null
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
    'accounting_basis', 'payments',
    'store_code', selected_store.store_code,
    'store_name', selected_store.store_name,
    'date_from', from_value,
    'date_to', to_value,
    'hourly_trend', coalesce((
      select jsonb_agg(jsonb_build_object(
        'hour', hour,
        'received', round(received, 2),
        'refunded', round(refunded, 2),
        'net', round(received - refunded, 2),
        'order_count', order_count
      ) order by hour)
      from hourly_rows
    ), '[]'::jsonb),
    'daily_trend', coalesce((
      select jsonb_agg(jsonb_build_object(
        'date', day,
        'received', round(received, 2),
        'refunded', round(refunded, 2),
        'net', round(received - refunded, 2)
      ) order by day)
      from daily_trend_rows
    ), '[]'::jsonb),
    'totals', jsonb_build_object(
      'received', coalesce((select round(sum(amount), 2) from payment_rows where lower(trim(method)) <> 'store credit'), 0),
      'refunded', coalesce((select round(sum(amount), 2) from refund_rows where lower(trim(method)) <> 'store credit'), 0),
      'net', coalesce((select round(sum(amount), 2) from payment_rows where lower(trim(method)) <> 'store credit'), 0)
             - coalesce((select round(sum(amount), 2) from refund_rows where lower(trim(method)) <> 'store credit'), 0),
      'order_count', (select count(*)::integer from paid_orders),
      'refund_count', (select count(*)::integer from refund_rows where lower(trim(method)) <> 'store credit'),
      'returned_units', coalesce((select sum(returned_units)::integer from order_refunded), 0),
      'unallocated', coalesce((select round(sum(amount), 2) from payment_rows where lower(trim(method)) <> 'store credit'), 0)
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_pos_performance_report(session_token text, target_store_code text, date_from date DEFAULT NULL::date, date_to date DEFAULT NULL::date, order_limit integer DEFAULT 300)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  result_payload jsonb;
  credit_issued numeric(12,2);
  credit_redeemed numeric(12,2);
  totals jsonb;
begin
  result_payload := public.get_pos_performance_report_before_store_credit(
    session_token, target_store_code, date_from, date_to, order_limit
  );
  select
    coalesce(sum((entry->>'received')::numeric), 0),
    coalesce(sum((entry->>'refunded')::numeric), 0)
  into credit_redeemed, credit_issued
  from jsonb_array_elements(result_payload->'payment_totals') entry
  where lower(trim(entry->>'method')) = 'store credit';
  totals := result_payload->'totals';
  totals := totals || jsonb_build_object(
    'store_credit_issued', credit_issued,
    'store_credit_redeemed', credit_redeemed
  );
  return jsonb_set(result_payload, '{totals}', totals);
end;
$function$
;

create or replace function public.get_admin_sales_drilldown(
  session_token text,
  date_from date default null,
  date_to date default null,
  target_store_code text default null,
  target_category text default 'all',
  search_query text default '',
  page_limit integer default 50,
  page_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  from_value date := coalesce(date_from, (now() at time zone 'Australia/Brisbane')::date);
  to_value date := coalesce(date_to, date_from, (now() at time zone 'Australia/Brisbane')::date);
  store_value text := lower(coalesce(trim(target_store_code), ''));
  category_value text := lower(coalesce(nullif(trim(target_category), ''), 'all'));
  query_value text := lower(coalesce(trim(search_query), ''));
  limit_value integer := least(greatest(coalesce(page_limit, 50), 1), 100);
  offset_value integer := greatest(coalesce(page_offset, 0), 0);
  result_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;
  if from_value > to_value then
    raise exception 'Start date must not be after end date';
  end if;
  if to_value - from_value > 366 then
    raise exception 'Report range cannot exceed 367 days';
  end if;
  if store_value <> '' and store_value <> all (
    array['parkridge', 'fairfield', 'northlakes', 'toowong']::text[]
  ) then
    raise exception 'Store is not available in the sales overview';
  end if;
  if category_value <> all (
    array['all', 'repair', 'mis', 'product', 'other']::text[]
  ) then
    raise exception 'Sales category is invalid';
  end if;

  with selected_stores as materialized (
    select store.id, store.store_code, store.store_name
    from public.store_locations store
    where store.active = true
      and store.store_code = any (
        array['parkridge', 'fairfield', 'northlakes', 'toowong']::text[]
      )
      and (store_value = '' or store.store_code = store_value)
  ),
  takings_movements as materialized (
    select * from public.pos_takings_line_movements(array(select id from selected_stores),from_value,to_value)
  ),
  filtered_lines as materialized (
    select m.event_type,m.event_key,m.transaction_at,m.transaction_date,
      store.store_code,store.store_name,sales_order.invoice_number,sales_order.order_code,
      m.refund_code,m.reason,sales_order.customer_name,sales_order.customer_phone,sales_order.customer_email,
      m.staff_name,m.payment_method,sales_order.payment_status,sales_order.total as invoice_total,
      sales_order.amount_paid,greatest(sales_order.total-sales_order.amount_paid,0) as balance_due,
      case when m.line_type='repair' then 'repair' when m.line_type='used_device' then 'mis'
        when m.line_type='retail' then 'product' else 'other' end as category_key,
      m.line_id,coalesce(sales_line.name,'Unallocated payment / refund') as item_name,
      sales_line.sku,m.quantity,sales_line.unit_price,m.amount,
      coalesce(repair_ticket.ticket_code,'') as ticket_code,
      coalesce(nullif(trim(sales_line.line_payload->>'note'),''),nullif(trim(sales_line.line_payload->>'notes'),''),
        nullif(trim(sales_line.line_payload->>'description'),''),'') as line_note
    from takings_movements m
    join selected_stores store on store.id=m.store_id
    join public.pos_sales_orders sales_order on sales_order.id=m.sales_order_id
    left join public.pos_sales_order_lines sales_line on sales_line.id=m.line_id
    left join public.pos_repair_tickets repair_ticket on repair_ticket.id=sales_line.repair_ticket_id
    where category_value='all' or category_value=case when m.line_type='repair' then 'repair'
      when m.line_type='used_device' then 'mis' when m.line_type='retail' then 'product' else 'other' end
  ),
  grouped_movements as materialized (
    select
      event_type,
      event_key,
      max(transaction_at) as transaction_at,
      max(transaction_date) as transaction_date,
      store_code,
      store_name,
      invoice_number,
      order_code,
      max(refund_code) as refund_code,
      max(reason) as reason,
      max(customer_name) as customer_name,
      max(customer_phone) as customer_phone,
      max(customer_email) as customer_email,
      max(staff_name) as staff_name,
      max(payment_method) as payment_method,
      max(payment_status) as payment_status,
      max(invoice_total) as invoice_total,
      max(amount_paid) as amount_paid,
      max(balance_due) as balance_due,
      case when count(distinct category_key) = 1 then min(category_key) else 'mixed' end as category_key,
      string_agg(distinct nullif(ticket_code, ''), ', ') as ticket_codes,
      sum(amount) as amount,
      sum(greatest(quantity, 0))::integer as item_count,
      jsonb_agg(jsonb_build_object(
        'line_id', line_id,
        'category', category_key,
        'name', item_name,
        'sku', sku,
        'quantity', quantity,
        'unit_price', unit_price,
        'amount', amount,
        'ticket_code', ticket_code,
        'note', line_note
      ) order by line_id) as items,
      lower(concat_ws(' ',
        invoice_number::text,
        order_code,
        max(refund_code),
        max(customer_name),
        max(customer_phone),
        max(customer_email),
        max(staff_name),
        string_agg(item_name, ' '),
        string_agg(coalesce(sku, ''), ' '),
        string_agg(coalesce(ticket_code, ''), ' ')
      )) as search_text
    from filtered_lines
    group by event_type, event_key, store_code, store_name, invoice_number, order_code
  ),
  searched_movements as materialized (
    select *
    from grouped_movements movement
    where query_value = '' or movement.search_text like '%' || query_value || '%'
  ),
  summary as (
    select
      round(coalesce(sum(case when event_type = 'sale' then amount else 0 end), 0), 2) as sales,
      round(abs(coalesce(sum(case when event_type = 'refund' then amount else 0 end), 0)), 2) as refunds,
      round(coalesce(sum(amount), 0), 2) as net,
      count(*)::integer as transaction_count
    from searched_movements
  )
  select jsonb_build_object(
    'ok', true,
    'date_from', from_value,
    'date_to', to_value,
    'store_code', store_value,
    'store_name', case when store_value = '' then 'All Stores'
      else coalesce((select min(store_name) from selected_stores), store_value) end,
    'category', category_value,
    'query', query_value,
    'limit', limit_value,
    'offset', offset_value,
    'has_more', summary.transaction_count > offset_value + limit_value,
    'summary', jsonb_build_object(
      'sales', summary.sales,
      'refunds', summary.refunds,
      'net', summary.net,
      'transaction_count', summary.transaction_count
    ),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', page.event_type,
        'event_key', page.event_key,
        'transaction_at', page.transaction_at,
        'transaction_date', page.transaction_date,
        'store_code', page.store_code,
        'store_name', page.store_name,
        'invoice_number', page.invoice_number,
        'order_code', page.order_code,
        'refund_code', page.refund_code,
        'reason', page.reason,
        'customer_name', page.customer_name,
        'customer_phone', page.customer_phone,
        'customer_email', page.customer_email,
        'staff_name', page.staff_name,
        'payment_method', page.payment_method,
        'payment_status', page.payment_status,
        'invoice_total', page.invoice_total,
        'amount_paid', page.amount_paid,
        'balance_due', page.balance_due,
        'category', page.category_key,
        'ticket_codes', coalesce(page.ticket_codes, ''),
        'item_count', page.item_count,
        'amount', round(page.amount, 2),
        'items', page.items
      ) order by page.transaction_at desc, page.event_key desc)
      from (
        select *
        from searched_movements
        order by transaction_at desc, event_key desc
        limit limit_value offset offset_value
      ) page
    ), '[]'::jsonb)
  ) into result_payload
  from summary;

  return result_payload;
end;
$$;

revoke all on function public.get_admin_sales_drilldown(
  text, date, date, text, text, text, integer, integer
) from public, anon, authenticated;
grant execute on function public.get_admin_sales_drilldown(
  text, date, date, text, text, text, integer, integer
) to anon, authenticated, service_role;

comment on function public.get_admin_sales_drilldown(
  text, date, date, text, text, text, integer, integer
) is
  'Admin-session-only paginated sales and refund movements. Uses the same category and date attribution rules as the four-store overview.';

comment on function public.get_admin_sales_overview(text,date,date) is 'Admin-only cash takings by payment/refund date, using the same ledger as POS performance; includes old-invoice balance payments.';
