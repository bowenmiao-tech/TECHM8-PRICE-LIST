-- Keep the existing admin report's review and device point rules, then add
-- cash-basis personal sales and product units per paid invoice.
alter function public.get_staff_points_report(text, integer)
  rename to get_staff_points_report_base;

create function public.get_staff_points_report(
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
        else 0 end)) filter (where sales_line.line_type in ('retail', 'product', 'used_device')), 0)::integer as product_units
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

  return base_report || jsonb_build_object(
    'staff', staff_report,
    'totals', (base_report->'totals') || jsonb_build_object(
      'commission_points', commission_total,
      'combined_points', coalesce((base_report->'totals'->>'combined_points')::numeric, 0) + commission_total
    )
  );
end;
$$;

revoke all on function public.get_staff_points_report(text, integer) from public, anon, authenticated;
grant execute on function public.get_staff_points_report(text, integer) to service_role;

-- Reuse the already calculated hourly-sales payload so the POS card and the
-- admin report award exactly 1 point per $100 of net personal takings.
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
    'staff_month_points', points.payload || jsonb_build_object(
      'personal_sales', (hourly.payload->>'net_sales')::numeric,
      'commission_points', round((hourly.payload->>'net_sales')::numeric * 0.01, 2),
      'total_points', coalesce((points.payload->>'total_points')::numeric, 0)
        + round((hourly.payload->>'net_sales')::numeric * 0.01, 2)
    )
  )
  from public.pos_staff_month_hourly_sales(target_staff_name, target_business_date) hourly(payload)
  cross join public.pos_staff_month_points(target_staff_name, target_business_date) points(payload);
$$;
