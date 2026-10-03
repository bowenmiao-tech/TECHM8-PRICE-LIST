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
        where event->>'normalized_staff_name' = person->>'normalized_staff_name'), 0),
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
