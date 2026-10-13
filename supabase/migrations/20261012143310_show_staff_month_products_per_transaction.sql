-- The staff Today card uses the same paid-order and net-product rules as the
-- admin points report. Repair-only invoices count as zero product units.
create or replace function public.pos_staff_month_product_metrics(
  target_staff_name text,
  target_business_date date
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with period as (
    select date_trunc('month', coalesce(target_business_date,
      (now() at time zone 'Australia/Brisbane')::date))::date as month_start,
      coalesce(target_business_date, (now() at time zone 'Australia/Brisbane')::date) as date_to
  ), paid_orders as (
    select sales_order.id
    from public.pos_sales_orders sales_order
    cross join period
    where sales_order.business_date between period.month_start and period.date_to
      and lower(trim(sales_order.staff_name)) = lower(trim(target_staff_name))
      and sales_order.payment_status = 'paid'
      and sales_order.amount_paid >= sales_order.total
  ), refunded_lines as (
    select refund_line.sales_order_line_id, sum(refund_line.amount) as refunded_amount
    from public.pos_sales_refund_lines refund_line
    join public.pos_sales_refunds refund on refund.id = refund_line.refund_id
    join paid_orders paid_order on paid_order.id = refund.sales_order_id
    group by refund_line.sales_order_line_id
  ), order_products as (
    select paid_order.id,
      coalesce(sum(greatest(0, sales_line.quantity - case
        when coalesce(refunded_line.refunded_amount, 0) >= sales_line.line_total then sales_line.quantity
        when sales_line.unit_price > 0 and coalesce(refunded_line.refunded_amount, 0) > 0
          then least(sales_line.quantity, greatest(1, round(refunded_line.refunded_amount / sales_line.unit_price)::integer))
        else 0 end)) filter (where sales_line.line_type in ('retail', 'product', 'used_device')), 0)::integer as product_units
    from paid_orders paid_order
    left join public.pos_sales_order_lines sales_line on sales_line.sales_order_id = paid_order.id
    left join refunded_lines refunded_line on refunded_line.sales_order_line_id = sales_line.id
    group by paid_order.id
  )
  select jsonb_build_object(
    'transaction_count', count(*)::integer,
    'product_units', coalesce(sum(product_units), 0)::integer,
    'products_per_transaction', case when count(*) > 0
      then round(sum(product_units)::numeric / count(*), 2) else 0 end
  ) from order_products;
$$;

revoke all on function public.pos_staff_month_product_metrics(text, date)
  from public, anon, authenticated;
grant execute on function public.pos_staff_month_product_metrics(text, date)
  to service_role;

create or replace function public.pos_today_progress_month_figures(
  target_store_id bigint,
  target_staff_name text,
  target_business_date date
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'monthly_hourly_sales', hourly.payload,
    'store_month_sales', public.pos_store_month_sales_progress(target_store_id, target_business_date),
    'staff_month_points', points.payload || products.payload || jsonb_build_object(
      'personal_sales', (hourly.payload->>'net_sales')::numeric,
      'commission_points', round((hourly.payload->>'net_sales')::numeric * 0.01, 2),
      'total_points', coalesce((points.payload->>'total_points')::numeric, 0)
        + round((hourly.payload->>'net_sales')::numeric * 0.01, 2)
    )
  )
  from public.pos_staff_month_hourly_sales(target_staff_name, target_business_date) hourly(payload)
  cross join public.pos_staff_month_points(target_staff_name, target_business_date) points(payload)
  cross join public.pos_staff_month_product_metrics(target_staff_name, target_business_date) products(payload);
$$;
