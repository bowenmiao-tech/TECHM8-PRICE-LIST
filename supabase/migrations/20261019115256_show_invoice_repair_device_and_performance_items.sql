-- Show the actual repair device beside each billed repair line. Keep warranty,
-- payments, refunds, and all existing invoice fields in the order payload.
CREATE OR REPLACE FUNCTION public.pos_sales_order_payload(order_row pos_sales_orders)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with line_rows as (
    select
      coalesce(
        jsonb_agg(
          sales_line.line_payload || jsonb_build_object(
            'line_id', sales_line.id,
            'warranty', public.pos_line_warranty(sales_line, order_row.business_date),
            'line_number', sales_line.line_number,
            'line_type', sales_line.line_type,
            'product_id', sales_line.product_id,
            'ticket_id', repair_ticket.ticket_code,
            'repair_device', case when sales_line.line_type = 'repair' then
              coalesce(nullif(trim(repair_ticket.title), ''),
                nullif(nullif(trim(sales_line.line_payload->>'source_device'), ''), '-'))
              else null end,
            'sku', sales_line.sku,
            'name', sales_line.name,
            'category', sales_line.category,
            'qty', sales_line.quantity,
            'unit_price', sales_line.unit_price,
            'sale_price', sales_line.unit_price,
            'line_total', sales_line.line_total,
            'refunded_amount', coalesce(refunded.amount, 0),
            'refunded_quantity', coalesce(refunded.returned_quantity, 0),
            'refundable_amount', greatest(sales_line.line_total - coalesce(refunded.amount, 0), 0),
            'refundable_quantity', greatest(sales_line.quantity - coalesce(refunded.returned_quantity, 0), 0)
          )
          order by sales_line.line_number
        ),
        '[]'::jsonb
      ) as items,
      bool_or(sales_line.line_type = 'repair') as has_repair,
      bool_or(sales_line.line_type <> 'repair') as has_non_repair
    from public.pos_sales_order_lines sales_line
    left join public.pos_repair_tickets repair_ticket on repair_ticket.id = sales_line.repair_ticket_id
    left join lateral (
      select
        coalesce(sum(refund_line.amount), 0) as amount,
        coalesce(sum(refund_line.returned_quantity), 0) as returned_quantity
      from public.pos_sales_refund_lines refund_line
      where refund_line.sales_order_line_id = sales_line.id
    ) refunded on true
    where sales_line.sales_order_id = order_row.id
  ),
  payment_rows as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'method', payment.method,
          'amount', payment.amount,
          'staff_name', payment.staff_name,
          'shift_id', payment.shift_id,
          'business_date', payment.business_date,
          'taken_at', coalesce(payment.taken_at, payment.created_at)
        ) order by payment.payment_number
      ),
      '[]'::jsonb
    ) as payments
    from public.pos_sales_order_payments payment
    where payment.sales_order_id = order_row.id
  ),
  refund_rows as (
    select
      coalesce(sum(refund.amount), 0) as refund_total,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', refund.refund_code,
            'staff_name', refund.staff_name,
            'method', refund.method,
            'reason', refund.reason,
            'amount', refund.amount,
            'shift_id', refund.shift_id,
            'business_date', refund.business_date,
            'created_at', refund.created_at
          ) order by refund.created_at desc
        ) filter (where refund.id is not null),
        '[]'::jsonb
      ) as refunds
    from public.pos_sales_refunds refund
    where refund.sales_order_id = order_row.id
  )
  select order_row.order_payload || jsonb_build_object(
    'id', order_row.order_code,
    'invoice_number', order_row.invoice_number,
    'store_db_code', store_location.store_code,
    'store_name', store_location.store_name,
    'business_date', order_row.business_date,
    'staff_name', order_row.staff_name,
    'shift_id', order_row.shift_id,
    'customer_name', order_row.customer_name,
    'customer_phone', order_row.customer_phone,
    'customer_email', order_row.customer_email,
    'payment_method', order_row.payment_method,
    'payments', payment_rows.payments,
    'items', line_rows.items,
    'sale_type', case
      when coalesce(line_rows.has_repair, false) and coalesce(line_rows.has_non_repair, false) then 'mixed'
      when coalesce(line_rows.has_repair, false) then 'repair'
      else 'retail'
    end,
    'total', order_row.total,
    'payment_status', order_row.payment_status,
    'amount_paid', order_row.amount_paid,
    'balance_due', round(greatest(order_row.total - order_row.amount_paid, 0), 2),
    'refund_total', refund_rows.refund_total,
    'refundable_total', greatest(least(order_row.total, order_row.amount_paid) - refund_rows.refund_total, 0),
    'refund_status', case
      when refund_rows.refund_total <= 0 then 'paid'
      when refund_rows.refund_total < least(order_row.total, order_row.amount_paid) then 'partially_refunded'
      else 'refunded'
    end,
    'refunds', refund_rows.refunds,
    'receipt_email_count', order_row.receipt_email_count,
    'last_receipt_email', order_row.last_receipt_email,
    'receipt_emailed_at', order_row.receipt_emailed_at,
    'created_at', order_row.created_at,
    'database_saved_at', order_row.updated_at,
    'sync_pending', false
  )
  from public.store_locations store_location
  cross join line_rows
  cross join payment_rows
  cross join refund_rows
  where store_location.id = order_row.store_id;
$function$;

-- The report already validates the staff session and store before returning
-- orders. Add only the lines that belong to each shown category, so a mixed
-- invoice describes repairs in Repairs and merchandise in Products.
create or replace function public.get_pos_performance_report(
  session_token text, target_store_code text, date_from date default null,
  date_to date default null, order_limit integer default 300
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  result_payload jsonb;
  credit_issued numeric(12,2);
  credit_redeemed numeric(12,2);
  totals jsonb;
  enriched_categories jsonb;
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

  with shown_orders as (
    select distinct category.value->>'type' as category_type,
      order_row.value->>'order_code' as order_code
    from jsonb_array_elements(coalesce(result_payload->'categories', '[]'::jsonb)) category(value)
    cross join lateral jsonb_array_elements(coalesce(category.value->'orders', '[]'::jsonb)) order_row(value)
  ), descriptions as (
    select shown.category_type, shown.order_code,
      jsonb_agg(jsonb_build_object(
        'name', sales_line.name,
        'device', case when sales_line.line_type = 'repair' then
          coalesce(nullif(trim(repair_ticket.title), ''),
            nullif(nullif(trim(sales_line.line_payload->>'source_device'), ''), '-'))
          else null end,
        'qty', sales_line.quantity
      ) order by sales_line.line_number) as items
    from shown_orders shown
    join public.pos_sales_orders sales_order on sales_order.order_code = shown.order_code
    join public.store_locations store on store.id = sales_order.store_id
      and lower(store.store_code) = lower(trim(target_store_code))
    join public.pos_sales_order_lines sales_line on sales_line.sales_order_id = sales_order.id
    left join public.pos_repair_tickets repair_ticket on repair_ticket.id = sales_line.repair_ticket_id
    where (case
      when sales_line.line_type in ('product', 'retail') then 'retail'
      when sales_line.line_type in ('repair', 'used_device') then sales_line.line_type
      else 'other'
    end) = shown.category_type
    group by shown.category_type, shown.order_code
  )
  select coalesce(jsonb_agg(category.value || jsonb_build_object(
    'orders', coalesce((
      select jsonb_agg(order_row.value || jsonb_build_object(
        'items', coalesce(description.items, '[]'::jsonb)
      ) order by order_row.ordinality)
      from jsonb_array_elements(coalesce(category.value->'orders', '[]'::jsonb))
        with ordinality order_row(value, ordinality)
      left join descriptions description
        on description.category_type = category.value->>'type'
       and description.order_code = order_row.value->>'order_code'
    ), '[]'::jsonb)
  ) order by category.ordinality), '[]'::jsonb)
  into enriched_categories
  from jsonb_array_elements(coalesce(result_payload->'categories', '[]'::jsonb))
    with ordinality category(value, ordinality);

  return result_payload || jsonb_build_object(
    'totals', totals,
    'categories', enriched_categories
  );
end;
$function$;

revoke all on function public.get_pos_performance_report(text, text, date, date, integer)
  from public, anon, authenticated;
grant execute on function public.get_pos_performance_report(text, text, date, date, integer)
  to service_role;

