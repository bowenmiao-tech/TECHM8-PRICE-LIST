-- Management-only sales overview for the Admin Portal.
--
-- Sales are attributed to the invoice business date. Refunds and payments are
-- attributed to the date on which they were processed. The category columns
-- are net of line-level refunds, and MIS deliberately means used-device sales.

create or replace function public.get_admin_sales_overview(
  session_token text,
  date_from date default null,
  date_to date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  from_value date := coalesce(date_from, (now() at time zone 'Australia/Brisbane')::date);
  to_value date := coalesce(date_to, date_from, (now() at time zone 'Australia/Brisbane')::date);
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

  with selected_stores as materialized (
    select
      store_location.id,
      store_location.store_code,
      store_location.store_name,
      array_position(
        array['parkridge', 'fairfield', 'northlakes', 'toowong']::text[],
        store_location.store_code
      ) as display_order
    from public.store_locations store_location
    where store_location.active = true
      and store_location.store_code = any (
        array['parkridge', 'fairfield', 'northlakes', 'toowong']::text[]
      )
  ),
  sale_orders as materialized (
    select sales_order.id, sales_order.store_id, sales_order.total
    from public.pos_sales_orders sales_order
    join selected_stores store on store.id = sales_order.store_id
    where sales_order.business_date between from_value and to_value
  ),
  order_summary as (
    select
      sale_order.store_id,
      round(sum(sale_order.total), 2) as gross_sales,
      count(*)::integer as invoice_count
    from sale_orders sale_order
    group by sale_order.store_id
  ),
  sale_categories as (
    select
      sale_order.store_id,
      case
        when sales_line.line_type = 'repair' then 'repair'
        when sales_line.line_type = 'used_device' then 'mis'
        when sales_line.line_type in ('product', 'retail') then 'product'
        else 'other'
      end as category_key,
      round(sum(sales_line.line_total), 2) as gross
    from sale_orders sale_order
    join public.pos_sales_order_lines sales_line
      on sales_line.sales_order_id = sale_order.id
    group by sale_order.store_id, 2
  ),
  refunds as materialized (
    select refund.id, refund.store_id, refund.amount
    from public.pos_sales_refunds refund
    join selected_stores store on store.id = refund.store_id
    where coalesce(
      refund.business_date,
      (refund.created_at at time zone 'Australia/Brisbane')::date
    ) between from_value and to_value
  ),
  refund_summary as (
    select
      refund.store_id,
      round(sum(refund.amount), 2) as refunds,
      count(*)::integer as refund_count
    from refunds refund
    group by refund.store_id
  ),
  refund_categories as (
    select
      refund.store_id,
      case
        when sales_line.line_type = 'repair' then 'repair'
        when sales_line.line_type = 'used_device' then 'mis'
        when sales_line.line_type in ('product', 'retail') then 'product'
        else 'other'
      end as category_key,
      round(sum(refund_line.amount), 2) as refunded
    from refunds refund
    join public.pos_sales_refund_lines refund_line
      on refund_line.refund_id = refund.id
    join public.pos_sales_order_lines sales_line
      on sales_line.id = refund_line.sales_order_line_id
    group by refund.store_id, 2
  ),
  payments as (
    select
      sales_order.store_id,
      round(sum(payment.amount), 2) as payments_received
    from public.pos_sales_order_payments payment
    join public.pos_sales_orders sales_order
      on sales_order.id = payment.sales_order_id
    join selected_stores store on store.id = sales_order.store_id
    where coalesce(
      payment.business_date,
      (payment.created_at at time zone 'Australia/Brisbane')::date
    ) between from_value and to_value
    group by sales_order.store_id
  ),
  store_values as materialized (
    select
      store.store_code,
      store.store_name,
      store.display_order,
      coalesce(order_summary.gross_sales, 0) as gross_sales,
      coalesce(refund_summary.refunds, 0) as refunds,
      coalesce(order_summary.gross_sales, 0) - coalesce(refund_summary.refunds, 0) as net_sales,
      coalesce(payments.payments_received, 0) as payments_received,
      coalesce(order_summary.invoice_count, 0) as invoice_count,
      coalesce(refund_summary.refund_count, 0) as refund_count,
      coalesce((select gross from sale_categories where sale_categories.store_id = store.id and category_key = 'repair'), 0)
        - coalesce((select refunded from refund_categories where refund_categories.store_id = store.id and category_key = 'repair'), 0) as repairs,
      coalesce((select gross from sale_categories where sale_categories.store_id = store.id and category_key = 'mis'), 0)
        - coalesce((select refunded from refund_categories where refund_categories.store_id = store.id and category_key = 'mis'), 0) as mis,
      coalesce((select gross from sale_categories where sale_categories.store_id = store.id and category_key = 'product'), 0)
        - coalesce((select refunded from refund_categories where refund_categories.store_id = store.id and category_key = 'product'), 0) as products
    from selected_stores store
    left join order_summary on order_summary.store_id = store.id
    left join refund_summary on refund_summary.store_id = store.id
    left join payments on payments.store_id = store.id
  ),
  completed_store_values as materialized (
    select
      store_values.*,
      store_values.net_sales - store_values.repairs - store_values.mis - store_values.products as other
    from store_values
  ),
  totals as (
    select
      coalesce(round(sum(gross_sales), 2), 0) as gross_sales,
      coalesce(round(sum(refunds), 2), 0) as refunds,
      coalesce(round(sum(net_sales), 2), 0) as net_sales,
      coalesce(round(sum(payments_received), 2), 0) as payments_received,
      coalesce(sum(invoice_count), 0)::integer as invoice_count,
      coalesce(sum(refund_count), 0)::integer as refund_count,
      coalesce(round(sum(repairs), 2), 0) as repairs,
      coalesce(round(sum(mis), 2), 0) as mis,
      coalesce(round(sum(products), 2), 0) as products,
      coalesce(round(sum(other), 2), 0) as other
    from completed_store_values
  )
  select jsonb_build_object(
    'ok', true,
    'date_from', from_value,
    'date_to', to_value,
    'generated_at', now(),
    'totals', jsonb_build_object(
      'gross_sales', totals.gross_sales,
      'refunds', totals.refunds,
      'net_sales', totals.net_sales,
      'payments_received', totals.payments_received,
      'invoice_count', totals.invoice_count,
      'refund_count', totals.refund_count,
      'gst', round(totals.net_sales / 11, 2),
      'repairs', totals.repairs,
      'mis', totals.mis,
      'products', totals.products,
      'other', totals.other
    ),
    'stores', coalesce((
      select jsonb_agg(jsonb_build_object(
        'store_code', store.store_code,
        'store_name', store.store_name,
        'gross_sales', round(store.gross_sales, 2),
        'refunds', round(store.refunds, 2),
        'net_sales', round(store.net_sales, 2),
        'payments_received', round(store.payments_received, 2),
        'invoice_count', store.invoice_count,
        'refund_count', store.refund_count,
        'average_sale', case
          when store.invoice_count > 0 then round(store.net_sales / store.invoice_count, 2)
          else 0
        end,
        'gst', round(store.net_sales / 11, 2),
        'repairs', round(store.repairs, 2),
        'mis', round(store.mis, 2),
        'products', round(store.products, 2),
        'other', round(store.other, 2)
      ) order by store.display_order)
      from completed_store_values store
    ), '[]'::jsonb)
  ) into result_payload
  from totals;

  return result_payload;
end;
$$;

revoke all on function public.get_admin_sales_overview(text, date, date)
  from public;
grant execute on function public.get_admin_sales_overview(text, date, date)
  to anon, authenticated;

comment on function public.get_admin_sales_overview(text, date, date) is
  'Admin-session-only four-store sales overview. MIS is used-device sales; category and total sales are net of refunds.';
