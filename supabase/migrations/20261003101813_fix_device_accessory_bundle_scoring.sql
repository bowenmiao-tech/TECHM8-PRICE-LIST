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
    coalesce(sum((qualifying_order.device_units + qualifying_order.accessory_units) * 5), 0)::integer
  from qualifying_orders qualifying_order;
$$;

revoke all on function public.pos_bundle_score_metrics(bigint, date, date, text)
  from public, anon, authenticated;
grant execute on function public.pos_bundle_score_metrics(bigint, date, date, text)
  to service_role;
