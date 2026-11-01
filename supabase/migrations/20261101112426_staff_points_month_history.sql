-- The existing two-argument points report keeps serving the current month.
-- These admin-only functions calculate a selected Brisbane calendar month.
create function public.get_staff_google_review_month_report(
  session_token text,
  target_month date,
  result_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  month_start date := date_trunc('month', target_month)::date;
  next_month date := (date_trunc('month', target_month) + interval '1 month')::date;
  last_month_start date := (date_trunc('month', target_month) - interval '1 month')::date;
  safe_limit integer := least(greatest(coalesce(result_limit, 500), 1), 2000);
  staff_payload jsonb;
  event_payload jsonb;
  totals_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;
  if target_month is null or target_month <> month_start
    or target_month > date_trunc('month', (now() at time zone 'Australia/Brisbane')::date)::date then
    raise exception 'Select a valid month up to the current month';
  end if;

  select coalesce(jsonb_agg(row_to_json(summary) order by summary.this_month_points desc, summary.staff_name), '[]'::jsonb)
  into staff_payload
  from (
    select staff.display_name as staff_name,
      lower(trim(staff.display_name)) as normalized_staff_name,
      staff.active,
      coalesce(count(*) filter (where event.business_date >= month_start and event.business_date < next_month), 0)::integer as this_month_reviews,
      coalesce(sum(event.points) filter (where event.business_date >= month_start and event.business_date < next_month), 0)::integer as this_month_points,
      coalesce(count(*) filter (where event.business_date >= last_month_start and event.business_date < month_start), 0)::integer as last_month_reviews,
      coalesce(sum(event.points) filter (where event.business_date >= last_month_start and event.business_date < month_start), 0)::integer as last_month_points,
      coalesce(count(event.id), 0)::integer as total_reviews,
      coalesce(sum(event.points), 0)::integer as total_points,
      max(event.business_date) as last_review_date
    from public.staff_directory staff
    left join public.pos_google_review_events event
      on event.normalized_staff_name = lower(trim(staff.display_name))
    group by staff.display_name, staff.active
  ) summary;

  select coalesce(jsonb_agg(row_to_json(rows) order by rows.business_date desc, rows.created_at desc), '[]'::jsonb)
  into event_payload
  from (
    select event.business_date, event.created_at, event.staff_name, event.customer_name,
      store_location.store_code, store_location.store_name, event.points
    from public.pos_google_review_events event
    join public.store_locations store_location on store_location.id = event.store_id
    where event.business_date >= month_start and event.business_date < next_month
    order by event.business_date desc, event.created_at desc
    limit safe_limit
  ) rows;

  select jsonb_build_object(
    'this_month_reviews', coalesce(count(*) filter (where business_date >= month_start and business_date < next_month), 0),
    'this_month_points', coalesce(sum(points) filter (where business_date >= month_start and business_date < next_month), 0),
    'last_month_reviews', coalesce(count(*) filter (where business_date >= last_month_start and business_date < month_start), 0),
    'last_month_points', coalesce(sum(points) filter (where business_date >= last_month_start and business_date < month_start), 0),
    'total_reviews', coalesce(count(*), 0),
    'total_points', coalesce(sum(points), 0)
  ) into totals_payload
  from public.pos_google_review_events;

  return jsonb_build_object(
    'ok', true,
    'this_month_start', month_start,
    'last_month_start', last_month_start,
    'totals', totals_payload,
    'staff', staff_payload,
    'events', event_payload
  );
end;
$$;

revoke all on function public.get_staff_google_review_month_report(text, date, integer) from public, anon, authenticated;
grant execute on function public.get_staff_google_review_month_report(text, date, integer) to service_role;

create function public.get_staff_points_month_report_base(
  session_token text,
  target_month date,
  result_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  review_report jsonb;
  month_start date := target_month;
  next_month date := (date_trunc('month', target_month) + interval '1 month')::date;
  device_events jsonb;
  staff_report jsonb;
  device_points_total integer;
begin
  review_report := public.get_staff_google_review_month_report(session_token, target_month, result_limit);

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

revoke all on function public.get_staff_points_month_report_base(text, date, integer) from public, anon, authenticated;
grant execute on function public.get_staff_points_month_report_base(text, date, integer) to service_role;

create function public.get_staff_points_month_report(
  session_token text,
  target_month date,
  result_limit integer default 500
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_report jsonb;
  staff_report jsonb;
  detailed_device_events jsonb;
  commission_total numeric(12,2);
  date_value date := least((now() at time zone 'Australia/Brisbane')::date, (date_trunc('month', target_month) + interval '1 month' - interval '1 day')::date);
  month_value date := target_month;
begin
  -- The base function validates the admin session before any staff data is read.
  base_report := public.get_staff_points_month_report_base(session_token, target_month, result_limit);

  with sales_metrics as (
    select lower(trim(movement.staff_name)) as staff_key,
      round(sum(movement.amount), 2) as personal_sales
    from public.pos_takings_line_movements(
      array(select location.id from public.store_locations location), month_value, date_value
    ) movement
    group by lower(trim(movement.staff_name))
  ), paid_orders as (
    select sales_order.id, lower(trim(sales_order.staff_name)) as staff_key
    from public.pos_sales_orders sales_order
    where sales_order.business_date between month_value and date_value
      and sales_order.payment_status = 'paid'
      and sales_order.amount_paid >= sales_order.total
  ), refunded_lines as (
    select refund_line.sales_order_line_id,
      sum(refund_line.amount) as refunded_amount
    from public.pos_sales_refund_lines refund_line
    join public.pos_sales_refunds refund on refund.id = refund_line.refund_id
    join paid_orders paid_order on paid_order.id = refund.sales_order_id
    group by refund_line.sales_order_line_id
  ), order_products as (
    select paid_order.staff_key, paid_order.id,
      coalesce(sum(greatest(0, sales_line.quantity - case
        when coalesce(refunded_line.refunded_amount, 0) >= sales_line.line_total then sales_line.quantity
        when sales_line.unit_price > 0 and coalesce(refunded_line.refunded_amount, 0) > 0
          then least(sales_line.quantity, greatest(1, round(refunded_line.refunded_amount / sales_line.unit_price)::integer))
        else 0 end)) filter (where sales_line.line_type in ('retail', 'product', 'used_device', 'repair')), 0)::integer as product_units
    from paid_orders paid_order
    left join public.pos_sales_order_lines sales_line on sales_line.sales_order_id = paid_order.id
    left join refunded_lines refunded_line on refunded_line.sales_order_line_id = sales_line.id
    group by paid_order.staff_key, paid_order.id
  ), transaction_metrics as (
    select staff_key, count(*)::integer as transaction_count,
      sum(product_units)::integer as product_units
    from order_products
    group by staff_key
  ), enriched as (
    select person || jsonb_build_object(
      'personal_sales', coalesce(sales.personal_sales, 0),
      'commission_points', round(coalesce(sales.personal_sales, 0) * 0.01, 2),
      'transaction_count', coalesce(transactions.transaction_count, 0),
      'product_units', coalesce(transactions.product_units, 0),
      'products_per_transaction', case when transactions.transaction_count > 0
        then round(transactions.product_units::numeric / transactions.transaction_count, 2) else 0 end,
      'total_points', coalesce((person->>'total_points')::numeric, 0)
        + round(coalesce(sales.personal_sales, 0) * 0.01, 2)
    ) as row_value
    from jsonb_array_elements(base_report->'staff') person
    left join sales_metrics sales on sales.staff_key = person->>'normalized_staff_name'
    left join transaction_metrics transactions on transactions.staff_key = person->>'normalized_staff_name'
  )
  select coalesce(jsonb_agg(row_value order by (row_value->>'total_points')::numeric desc,
    row_value->>'staff_name'), '[]'::jsonb)
  into staff_report
  from enriched;

  select coalesce(sum((person->>'commission_points')::numeric), 0)
  into commission_total
  from jsonb_array_elements(staff_report) person;

  with event_orders as (
    select distinct sales_order.id, sales_order.order_code
    from jsonb_array_elements(base_report->'device_events') event
    join public.pos_sales_orders sales_order on sales_order.order_code = event->>'order_code'
    where coalesce(event->>'event_type', 'sale') <> 'manual_adjustment'
  ), refunded_lines as (
    select refund_line.sales_order_line_id, sum(refund_line.amount) as refunded_amount
    from public.pos_sales_refund_lines refund_line
    join public.pos_sales_refunds refund on refund.id = refund_line.refund_id
    join event_orders event_order on event_order.id = refund.sales_order_id
    group by refund_line.sales_order_line_id
  ), net_lines as (
    select event_order.order_code, sales_line.name, sales_line.line_type,
      sales_line.category, sales_line.line_payload, sales_line.line_number,
      greatest(0, sales_line.quantity - case
        when coalesce(refunded_line.refunded_amount, 0) >= sales_line.line_total then sales_line.quantity
        when sales_line.unit_price > 0 and coalesce(refunded_line.refunded_amount, 0) > 0
          then least(sales_line.quantity, greatest(1, round(refunded_line.refunded_amount / sales_line.unit_price)::integer))
        else 0 end)::integer as net_quantity
    from event_orders event_order
    join public.pos_sales_order_lines sales_line on sales_line.sales_order_id = event_order.id
    left join refunded_lines refunded_line on refunded_line.sales_order_line_id = sales_line.id
  ), classified_lines as (
    select net_line.*,
      (net_line.line_type = 'used_device'
        or lower(coalesce(net_line.line_payload->>'is_used_device', 'false')) = 'true'
        or regexp_replace(lower(trim(net_line.category)), '[^a-z0-9]+', '', 'g') in (
          'device', 'devices', 'useddevice', 'useddevices', 'refurbisheddevice',
          'refurbisheddevices', 'mobilephone', 'mobilephones'
        )) as is_device
    from net_lines net_line
    where net_line.net_quantity > 0
  ), item_groups as (
    select classified_line.order_code,
      jsonb_agg(jsonb_build_object('name', classified_line.name, 'quantity', classified_line.net_quantity)
        order by classified_line.line_number) filter (where classified_line.is_device) as devices,
      jsonb_agg(jsonb_build_object('name', classified_line.name, 'quantity', classified_line.net_quantity)
        order by classified_line.line_number) filter (
          where not classified_line.is_device
            and classified_line.line_type in ('retail', 'product')
            and lower(trim(classified_line.category)) <> 'uncategorized'
        ) as accessories
    from classified_lines classified_line
    group by classified_line.order_code
  )
  select coalesce(jsonb_agg(event.value || jsonb_build_object(
    'devices', coalesce(item_group.devices, '[]'::jsonb),
    'accessories', coalesce(item_group.accessories, '[]'::jsonb)
  ) order by event.ordinality), '[]'::jsonb)
  into detailed_device_events
  from jsonb_array_elements(base_report->'device_events') with ordinality as event(value, ordinality)
  left join item_groups item_group on item_group.order_code = event.value->>'order_code';

  return base_report || jsonb_build_object(
    'staff', staff_report,
    'device_events', detailed_device_events,
    'totals', (base_report->'totals') || jsonb_build_object(
      'commission_points', commission_total,
      'combined_points', coalesce((base_report->'totals'->>'combined_points')::numeric, 0) + commission_total
    )
  );
end;
$$;

revoke all on function public.get_staff_points_month_report(text, date, integer) from public, anon, authenticated;
grant execute on function public.get_staff_points_month_report(text, date, integer) to service_role;
