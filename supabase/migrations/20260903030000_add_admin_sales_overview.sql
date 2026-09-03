-- Backs the admin portal's four-store sales overview.
--
-- The page calls get_admin_sales_overview with the admin session token. Until
-- now that function did not exist, so the overview could never load.

-- 1. Imported history always lands as 'retail', so the Fairfield import counted
--    2,472 repair and used-device lines as products. This is the same backfill
--    20260901120559 applied to Toowong, re-run across every legacy row so it
--    also covers any store imported later. RepairDesk's own item type is kept
--    in line_payload->>'source_type', so the split is recovered, not guessed.
update public.pos_sales_order_lines
set line_type = case
  when line_payload->>'source_type' = 'Repair' then 'repair'
  when line_payload->>'source_type' = 'Accessories' then 'retail'
  when line_payload->>'source_type' = 'Casual'
    then case when lower(trim(name)) = 'device' then 'used_device' else 'retail' end
  when coalesce(line_payload->>'source_type', '') = ''
    then case when nullif(line_payload->>'source_ticket_id', '') is not null then 'repair' else 'retail' end
  else 'retail'
end
where legacy_import = true;

-- 2. The overview itself.
--
-- Category figures come from sale lines and always add up to net sales, so a
-- store row reconciles on its own. Refunds are separate immutable records and
-- stay in their own column rather than being netted off. No per-line tax column
-- exists, so GST is derived from the GST-inclusive total at the Australian
-- 1/11 rate; it is an indicative figure, not a BAS number.
create or replace function public.get_admin_sales_overview(
  session_token text,
  date_from date,
  date_to date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  store_rows jsonb;
  totals jsonb;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;
  if date_from is null or date_to is null then
    raise exception 'A start date and an end date are required';
  end if;
  if date_to < date_from then
    raise exception 'The start date must be on or before the end date';
  end if;
  if date_to - date_from > 400 then
    raise exception 'Choose a date range of 400 days or less';
  end if;

  with reported_stores as (
    select store_location.id, store_location.store_code
    from public.store_locations store_location
    where store_location.store_code in ('parkridge', 'fairfield', 'northlakes', 'toowong')
  ), order_totals as (
    select
      sales_order.store_id,
      count(*) as invoice_count,
      coalesce(sum(sales_order.total), 0) as net_sales
    from public.pos_sales_orders sales_order
    join reported_stores on reported_stores.id = sales_order.store_id
    where sales_order.business_date between date_from and date_to
    group by sales_order.store_id
  ), line_totals as (
    select
      sales_order.store_id,
      coalesce(sum(line.line_total) filter (where line.line_type = 'repair'), 0) as repairs,
      coalesce(sum(line.line_total) filter (where line.line_type = 'used_device'), 0) as mis,
      coalesce(sum(line.line_total) filter (where line.line_type = 'retail'), 0) as products,
      coalesce(sum(line.line_total) filter (
        where line.line_type not in ('repair', 'used_device', 'retail')
      ), 0) as other
    from public.pos_sales_order_lines line
    join public.pos_sales_orders sales_order on sales_order.id = line.sales_order_id
    join reported_stores on reported_stores.id = sales_order.store_id
    where sales_order.business_date between date_from and date_to
    group by sales_order.store_id
  ), payment_totals as (
    select
      sales_order.store_id,
      coalesce(sum(payment.amount), 0) as payments_received
    from public.pos_sales_order_payments payment
    join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id
    join reported_stores on reported_stores.id = sales_order.store_id
    where coalesce(payment.business_date, sales_order.business_date) between date_from and date_to
    group by sales_order.store_id
  ), refund_totals as (
    select
      refund.store_id,
      coalesce(sum(refund.amount), 0) as refunds,
      count(*) as refund_count
    from public.pos_sales_refunds refund
    join reported_stores on reported_stores.id = refund.store_id
    where refund.business_date between date_from and date_to
    group by refund.store_id
  ), combined as (
    select
      reported_stores.store_code,
      round(coalesce(order_totals.net_sales, 0), 2) as net_sales,
      coalesce(order_totals.invoice_count, 0) as invoice_count,
      round(coalesce(line_totals.repairs, 0), 2) as repairs,
      round(coalesce(line_totals.mis, 0), 2) as mis,
      round(coalesce(line_totals.products, 0), 2) as products,
      round(coalesce(line_totals.other, 0), 2) as other,
      round(coalesce(payment_totals.payments_received, 0), 2) as payments_received,
      round(coalesce(refund_totals.refunds, 0), 2) as refunds,
      coalesce(refund_totals.refund_count, 0) as refund_count
    from reported_stores
    left join order_totals on order_totals.store_id = reported_stores.id
    left join line_totals on line_totals.store_id = reported_stores.id
    left join payment_totals on payment_totals.store_id = reported_stores.id
    left join refund_totals on refund_totals.store_id = reported_stores.id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'store_code', combined.store_code,
      'net_sales', combined.net_sales,
      'repairs', combined.repairs,
      'mis', combined.mis,
      'products', combined.products,
      'other', combined.other,
      'payments_received', combined.payments_received,
      'refunds', combined.refunds,
      'refund_count', combined.refund_count,
      'invoice_count', combined.invoice_count,
      'average_sale', case
        when combined.invoice_count > 0 then round(combined.net_sales / combined.invoice_count, 2)
        else 0
      end
    ) order by combined.store_code
  ), '[]'::jsonb)
  into store_rows
  from combined;

  select jsonb_build_object(
    'net_sales', coalesce(round(sum((store_row->>'net_sales')::numeric), 2), 0),
    'gst', coalesce(round(sum((store_row->>'net_sales')::numeric) / 11, 2), 0),
    'repairs', coalesce(round(sum((store_row->>'repairs')::numeric), 2), 0),
    'mis', coalesce(round(sum((store_row->>'mis')::numeric), 2), 0),
    'products', coalesce(round(sum((store_row->>'products')::numeric), 2), 0),
    'other', coalesce(round(sum((store_row->>'other')::numeric), 2), 0),
    'payments_received', coalesce(round(sum((store_row->>'payments_received')::numeric), 2), 0),
    'refunds', coalesce(round(sum((store_row->>'refunds')::numeric), 2), 0),
    'refund_count', coalesce(sum((store_row->>'refund_count')::bigint), 0),
    'invoice_count', coalesce(sum((store_row->>'invoice_count')::bigint), 0)
  )
  into totals
  from jsonb_array_elements(store_rows) as store_row;

  return jsonb_build_object(
    'ok', true,
    'date_from', date_from,
    'date_to', date_to,
    'stores', store_rows,
    'totals', totals
  );
end;
$$;

revoke all on function public.get_admin_sales_overview(text, date, date) from public;
grant execute on function public.get_admin_sales_overview(text, date, date) to anon;
grant execute on function public.get_admin_sales_overview(text, date, date) to authenticated;
grant execute on function public.get_admin_sales_overview(text, date, date) to service_role;

comment on function public.get_admin_sales_overview(text, date, date) is
  'Admin-session-only four-store sales overview: per-store repair/used-device/product split, net sales, payments received, refunds and invoice counts for a date range.';
