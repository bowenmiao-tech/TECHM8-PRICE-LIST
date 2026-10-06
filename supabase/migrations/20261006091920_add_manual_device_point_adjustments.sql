-- Audited device point credits, separate from sales and Google reviews.
create table public.pos_device_point_adjustments (
  request_key text primary key,
  staff_id bigint not null references public.staff_directory(id),
  store_id bigint not null references public.store_locations(id),
  business_date date not null,
  points integer not null check (points <> 0),
  reason text not null check (length(trim(reason)) > 0),
  requested_by text not null check (length(trim(requested_by)) > 0),
  created_at timestamptz not null default now()
);
create index pos_device_point_adjustments_staff_date_idx
  on public.pos_device_point_adjustments(staff_id, business_date);
create index pos_device_point_adjustments_store_date_idx
  on public.pos_device_point_adjustments(store_id, business_date);
alter table public.pos_device_point_adjustments enable row level security;
revoke all on public.pos_device_point_adjustments from public, anon, authenticated, service_role;
grant select on public.pos_device_point_adjustments to service_role;
comment on table public.pos_device_point_adjustments is
  'Owner-authorized manual device points. Does not create sales, reviews or bundle counts.';

-- A paid device sale earns five points per device only when an accessory is
-- on the same invoice, plus five points for each accessory unit.
-- Retail replaced the legacy product line type in August 2026.
create or replace function public.pos_bundle_score_metrics(
  target_store_id bigint,
  date_from date,
  date_to date,
  target_staff_name text
)
returns table (
  bundle_order_count integer,
  device_count integer,
  accessory_count integer,
  bundle_points integer
)
language sql
stable
security definer
set search_path = ''
as $$
  with sale_orders as (
    select sales_order.id
    from public.pos_sales_orders sales_order
    where sales_order.store_id = target_store_id
      and sales_order.business_date between date_from and date_to
      and lower(trim(sales_order.staff_name)) = lower(trim(target_staff_name))
      and sales_order.payment_status = 'paid'
      and sales_order.amount_paid >= sales_order.total
  ),
  line_refunds as (
    select
      refund_line.sales_order_line_id,
      sum(refund_line.amount)::numeric(12,2) as refunded_amount
    from public.pos_sales_refund_lines refund_line
    join public.pos_sales_refunds refund on refund.id = refund_line.refund_id
    join sale_orders sales_order on sales_order.id = refund.sales_order_id
    group by refund_line.sales_order_line_id
  ),
  net_lines as (
    select
      sales_line.sales_order_id,
      sales_line.line_type,
      sales_line.category,
      sales_line.line_payload,
      greatest(0, sales_line.quantity - case
        when coalesce(line_refund.refunded_amount, 0) >= sales_line.line_total then sales_line.quantity
        when sales_line.unit_price > 0 and coalesce(line_refund.refunded_amount, 0) > 0 then least(
          sales_line.quantity,
          greatest(1, round(line_refund.refunded_amount / sales_line.unit_price)::integer)
        )
        else 0
      end)::integer as net_quantity
    from public.pos_sales_order_lines sales_line
    join sale_orders sales_order on sales_order.id = sales_line.sales_order_id
    left join line_refunds line_refund on line_refund.sales_order_line_id = sales_line.id
  ),
  classified_lines as (
    select
      net_line.*,
      (
        net_line.line_type = 'used_device'
        or lower(coalesce(net_line.line_payload->>'is_used_device', 'false')) = 'true'
        or regexp_replace(lower(trim(net_line.category)), '[^a-z0-9]+', '', 'g') in (
          'device', 'devices', 'useddevice', 'useddevices', 'refurbisheddevice',
          'refurbisheddevices', 'mobilephone', 'mobilephones'
        )
      ) as is_device
    from net_lines net_line
    where net_line.net_quantity > 0
  ),
  order_units as (
    select
      classified_line.sales_order_id,
      coalesce(sum(classified_line.net_quantity) filter (where classified_line.is_device), 0)::integer as device_units,
      coalesce(sum(classified_line.net_quantity) filter (
        where not classified_line.is_device
          and classified_line.line_type in ('retail', 'product')
          and lower(trim(classified_line.category)) <> 'uncategorized'
      ), 0)::integer as accessory_units
    from classified_lines classified_line
    group by classified_line.sales_order_id
  ),
  qualifying_orders as (
    select *
    from order_units
    where device_units > 0 and accessory_units > 0
  )
  select
    count(*)::integer,
    coalesce(sum(qualifying_order.device_units), 0)::integer,
    coalesce(sum(qualifying_order.accessory_units), 0)::integer,
    (coalesce(sum((qualifying_order.device_units + qualifying_order.accessory_units) * 5), 0) +
      coalesce((select sum(adjustment.points)
        from public.pos_device_point_adjustments adjustment
        join public.staff_directory staff on staff.id = adjustment.staff_id
        where adjustment.store_id = target_store_id
          and adjustment.business_date between date_from and date_to
          and lower(trim(staff.display_name)) = lower(trim(target_staff_name))), 0))::integer
  from qualifying_orders qualifying_order;
$$;

revoke all on function public.pos_bundle_score_metrics(bigint, date, date, text)
  from public, anon, authenticated;
grant execute on function public.pos_bundle_score_metrics(bigint, date, date, text)
  to service_role;

-- Admin-only monthly score report. Review history comes from the existing
-- authenticated report; device orders use the same paid/refund rules as POS.
create or replace function public.get_staff_points_report(
  session_token text,
  result_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  review_report jsonb;
  month_start date := date_trunc('month', (now() at time zone 'Australia/Brisbane')::date)::date;
  next_month date := (date_trunc('month', (now() at time zone 'Australia/Brisbane')::date) + interval '1 month')::date;
  device_events jsonb;
  staff_report jsonb;
  device_points_total integer;
begin
  review_report := public.get_staff_google_review_report(session_token, result_limit);

  with paid_orders as (
    select o.id, o.order_code, o.business_date, o.store_id, o.staff_name,
      lower(trim(o.staff_name)) as normalized_staff_name, s.store_name
    from public.pos_sales_orders o
    join public.store_locations s on s.id = o.store_id
    where o.business_date >= month_start and o.business_date < next_month
      and o.payment_status = 'paid' and o.amount_paid >= o.total
  ),
  refunds as (
    select rl.sales_order_line_id, sum(rl.amount)::numeric(12,2) as refunded_amount
    from public.pos_sales_refund_lines rl
    join public.pos_sales_refunds r on r.id = rl.refund_id
    join paid_orders o on o.id = r.sales_order_id
    group by rl.sales_order_line_id
  ),
  lines as (
    select o.id, o.order_code, o.business_date, o.store_name, o.staff_name,
      o.normalized_staff_name, l.line_type, l.category, l.line_payload,
      greatest(0, l.quantity - case
        when coalesce(r.refunded_amount, 0) >= l.line_total then l.quantity
        when l.unit_price > 0 and coalesce(r.refunded_amount, 0) > 0 then least(
          l.quantity, greatest(1, round(r.refunded_amount / l.unit_price)::integer)
        ) else 0 end)::integer as net_quantity
    from paid_orders o
    join public.pos_sales_order_lines l on l.sales_order_id = o.id
    left join refunds r on r.sales_order_line_id = l.id
  ),
  classified as (
    select lines.*,
      (line_type = 'used_device'
        or lower(coalesce(line_payload->>'is_used_device', 'false')) = 'true'
        or regexp_replace(lower(trim(category)), '[^a-z0-9]+', '', 'g') in (
          'device', 'devices', 'useddevice', 'useddevices', 'refurbisheddevice',
          'refurbisheddevices', 'mobilephone', 'mobilephones'
        )) as is_device
    from lines where net_quantity > 0
  ),
  order_units as (
    select id, order_code, business_date, store_name, staff_name,
      normalized_staff_name,
      coalesce(sum(net_quantity) filter (where is_device), 0)::integer as device_count,
      coalesce(sum(net_quantity) filter (where not is_device
        and line_type in ('retail', 'product')
        and lower(trim(category)) <> 'uncategorized'), 0)::integer as accessory_count
    from classified
    group by id, order_code, business_date, store_name, staff_name, normalized_staff_name
  ),
  bundles as (
    select order_code, business_date, store_name, staff_name, normalized_staff_name,
      device_count, accessory_count, (device_count + accessory_count) * 5 as points
    from order_units where device_count > 0 and accessory_count > 0
  )
  select coalesce(jsonb_agg(to_jsonb(b) order by b.business_date desc, b.order_code desc), '[]'::jsonb)
  into device_events from bundles b;

  -- Preserve the sales event shape for older clients; mark adjustments explicitly.
  select device_events || coalesce(jsonb_agg(jsonb_build_object(
    'event_type', 'manual_adjustment', 'order_code', 'Manual device points adjustment',
    'request_key', adjustment.request_key, 'business_date', adjustment.business_date,
    'store_name', store_location.store_name, 'staff_name', staff.display_name,
    'normalized_staff_name', lower(trim(staff.display_name)),
    'device_count', 0, 'accessory_count', 0,
    'points', adjustment.points, 'reason', adjustment.reason
  ) order by adjustment.business_date desc, adjustment.created_at desc), '[]'::jsonb)
  into device_events
  from public.pos_device_point_adjustments adjustment
  join public.staff_directory staff on staff.id = adjustment.staff_id
  join public.store_locations store_location on store_location.id = adjustment.store_id
  where adjustment.business_date >= month_start and adjustment.business_date < next_month;

  select coalesce(sum((event->>'points')::integer), 0)::integer
  into device_points_total
  from jsonb_array_elements(device_events) event;

  select coalesce(jsonb_agg(staff_row.enriched order by
    (staff_row.enriched->>'total_points')::integer desc,
    staff_row.enriched->>'staff_name'), '[]'::jsonb)
  into staff_report
  from (
    select person || jsonb_build_object(
      'device_points', coalesce((select sum((event->>'points')::integer)
        from jsonb_array_elements(device_events) event
        where event->>'normalized_staff_name' = person->>'normalized_staff_name'), 0),
      'device_bundle_count', coalesce((select count(*)
        from jsonb_array_elements(device_events) event
        where event->>'normalized_staff_name' = person->>'normalized_staff_name'
          and coalesce(event->>'event_type', 'sale') <> 'manual_adjustment'), 0),
      'total_points', coalesce((person->>'this_month_points')::integer, 0) +
        coalesce((select sum((event->>'points')::integer)
          from jsonb_array_elements(device_events) event
          where event->>'normalized_staff_name' = person->>'normalized_staff_name'), 0)
    ) as enriched
    from jsonb_array_elements(review_report->'staff') person
  ) staff_row;

  return review_report || jsonb_build_object(
    'staff', staff_report,
    'device_events', device_events,
    'totals', (review_report->'totals') || jsonb_build_object(
      'device_points', device_points_total,
      'combined_points', coalesce((review_report->'totals'->>'this_month_points')::integer, 0) + device_points_total
    )
  );
end;
$$;

revoke all on function public.get_staff_points_report(text, integer)
  from public, anon, authenticated;
grant execute on function public.get_staff_points_report(text, integer) to service_role;
