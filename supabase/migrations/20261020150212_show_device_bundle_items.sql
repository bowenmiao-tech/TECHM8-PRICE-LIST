-- Add the actual device and accessory names to scored bundle history.
-- Keep the existing point calculation and refund rules unchanged.

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
  base_report jsonb;
  staff_report jsonb;
  detailed_device_events jsonb;
  commission_total numeric(12,2);
  date_value date := (now() at time zone 'Australia/Brisbane')::date;
  month_value date := date_trunc('month', (now() at time zone 'Australia/Brisbane')::date)::date;
begin
  -- The base function validates the admin session before any staff data is read.
  base_report := public.get_staff_points_report_base(session_token, result_limit);

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

revoke all on function public.get_staff_points_report(text, integer) from public, anon, authenticated;

grant execute on function public.get_staff_points_report(text, integer) to service_role;
