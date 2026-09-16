-- Keep the overview and its drill-down on one accounting basis: sales are
-- attributed to invoice dates; refunds and payments to their processed dates.
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
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  if from_value > to_value then raise exception 'Start date must not be after end date'; end if;
  if to_value - from_value > 366 then raise exception 'Report range cannot exceed 367 days'; end if;

  with selected_stores as materialized (
    select store.id, store.store_code, store.store_name,
      array_position(array['parkridge','fairfield','northlakes','toowong']::text[], store.store_code) display_order
    from public.store_locations store
    where store.active and store.store_code = any (array['parkridge','fairfield','northlakes','toowong']::text[])
  ),
  sale_orders as materialized (
    select sales_order.id, sales_order.store_id, sales_order.total
    from public.pos_sales_orders sales_order
    join selected_stores store on store.id=sales_order.store_id
    where sales_order.business_date between from_value and to_value
  ),
  order_summary as (
    select sale_order.store_id, round(sum(sale_order.total),2) gross_sales, count(*)::integer invoice_count
    from sale_orders sale_order group by sale_order.store_id
  ),
  sale_categories as (
    select sale_order.store_id,
      case when sales_line.line_type='repair' then 'repair'
        when sales_line.line_type='used_device' then 'mis'
        when sales_line.line_type in ('product','retail') then 'product' else 'other' end category_key,
      round(sum(sales_line.line_total),2) gross
    from sale_orders sale_order
    join public.pos_sales_order_lines sales_line on sales_line.sales_order_id=sale_order.id
    group by sale_order.store_id,2
  ),
  refunds as materialized (
    select refund.id,refund.store_id,refund.amount
    from public.pos_sales_refunds refund join selected_stores store on store.id=refund.store_id
    where coalesce(refund.business_date,(refund.created_at at time zone 'Australia/Brisbane')::date)
      between from_value and to_value
  ),
  refund_summary as (
    select refund.store_id,round(sum(refund.amount),2) refunds,count(*)::integer refund_count
    from refunds refund group by refund.store_id
  ),
  refund_categories as (
    select refund.store_id,
      case when sales_line.line_type='repair' then 'repair'
        when sales_line.line_type='used_device' then 'mis'
        when sales_line.line_type in ('product','retail') then 'product' else 'other' end category_key,
      round(sum(refund_line.amount),2) refunded
    from refunds refund
    join public.pos_sales_refund_lines refund_line on refund_line.refund_id=refund.id
    join public.pos_sales_order_lines sales_line on sales_line.id=refund_line.sales_order_line_id
    group by refund.store_id,2
  ),
  payments as (
    select sales_order.store_id,round(sum(payment.amount),2) payments_received
    from public.pos_sales_order_payments payment
    join public.pos_sales_orders sales_order on sales_order.id=payment.sales_order_id
    join selected_stores store on store.id=sales_order.store_id
    where coalesce(payment.business_date,(payment.created_at at time zone 'Australia/Brisbane')::date)
      between from_value and to_value
    group by sales_order.store_id
  ),
  store_values as materialized (
    select store.store_code,store.store_name,store.display_order,
      coalesce(order_summary.gross_sales,0) gross_sales,coalesce(refund_summary.refunds,0) refunds,
      coalesce(order_summary.gross_sales,0)-coalesce(refund_summary.refunds,0) net_sales,
      coalesce(payments.payments_received,0) payments_received,coalesce(order_summary.invoice_count,0) invoice_count,
      coalesce(refund_summary.refund_count,0) refund_count,
      coalesce((select gross from sale_categories where store_id=store.id and category_key='repair'),0)
        -coalesce((select refunded from refund_categories where store_id=store.id and category_key='repair'),0) repairs,
      coalesce((select gross from sale_categories where store_id=store.id and category_key='mis'),0)
        -coalesce((select refunded from refund_categories where store_id=store.id and category_key='mis'),0) mis,
      coalesce((select gross from sale_categories where store_id=store.id and category_key='product'),0)
        -coalesce((select refunded from refund_categories where store_id=store.id and category_key='product'),0) products
    from selected_stores store
    left join order_summary on order_summary.store_id=store.id
    left join refund_summary on refund_summary.store_id=store.id
    left join payments on payments.store_id=store.id
  ),
  completed_store_values as materialized (
    select store_values.*,net_sales-repairs-mis-products other from store_values
  ),
  totals as (
    select coalesce(round(sum(gross_sales),2),0) gross_sales,coalesce(round(sum(refunds),2),0) refunds,
      coalesce(round(sum(net_sales),2),0) net_sales,coalesce(round(sum(payments_received),2),0) payments_received,
      coalesce(sum(invoice_count),0)::integer invoice_count,coalesce(sum(refund_count),0)::integer refund_count,
      coalesce(round(sum(repairs),2),0) repairs,coalesce(round(sum(mis),2),0) mis,
      coalesce(round(sum(products),2),0) products,coalesce(round(sum(other),2),0) other
    from completed_store_values
  )
  select jsonb_build_object('ok',true,'date_from',from_value,'date_to',to_value,'generated_at',now(),
    'totals',jsonb_build_object('gross_sales',totals.gross_sales,'refunds',totals.refunds,'net_sales',totals.net_sales,
      'payments_received',totals.payments_received,'invoice_count',totals.invoice_count,'refund_count',totals.refund_count,
      'gst',round(totals.net_sales/11,2),'repairs',totals.repairs,'mis',totals.mis,'products',totals.products,'other',totals.other),
    'stores',coalesce((select jsonb_agg(jsonb_build_object('store_code',store.store_code,'store_name',store.store_name,
      'gross_sales',round(store.gross_sales,2),'refunds',round(store.refunds,2),'net_sales',round(store.net_sales,2),
      'payments_received',round(store.payments_received,2),'invoice_count',store.invoice_count,'refund_count',store.refund_count,
      'average_sale',case when store.invoice_count>0 then round(store.net_sales/store.invoice_count,2) else 0 end,
      'gst',round(store.net_sales/11,2),'repairs',round(store.repairs,2),'mis',round(store.mis,2),
      'products',round(store.products,2),'other',round(store.other,2)) order by store.display_order)
      from completed_store_values store),'[]'::jsonb)
  ) into result_payload from totals;
  return result_payload;
end;
$$;

revoke all on function public.get_admin_sales_overview(text,date,date) from public,anon,authenticated;
grant execute on function public.get_admin_sales_overview(text,date,date) to anon,authenticated,service_role;

comment on function public.get_admin_sales_overview(text,date,date) is
  'Admin-session-only four-store overview. Category and total sales are net of refunds processed in the selected period.';

create or replace function public.get_admin_sales_drilldown(
  session_token text,
  date_from date default null,
  date_to date default null,
  target_store_code text default null,
  target_category text default 'all',
  search_query text default '',
  page_limit integer default 50,
  page_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  from_value date := coalesce(date_from, (now() at time zone 'Australia/Brisbane')::date);
  to_value date := coalesce(date_to, date_from, (now() at time zone 'Australia/Brisbane')::date);
  store_value text := lower(coalesce(trim(target_store_code), ''));
  category_value text := lower(coalesce(nullif(trim(target_category), ''), 'all'));
  query_value text := lower(coalesce(trim(search_query), ''));
  limit_value integer := least(greatest(coalesce(page_limit, 50), 1), 100);
  offset_value integer := greatest(coalesce(page_offset, 0), 0);
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
  if store_value <> '' and store_value <> all (
    array['parkridge', 'fairfield', 'northlakes', 'toowong']::text[]
  ) then
    raise exception 'Store is not available in the sales overview';
  end if;
  if category_value <> all (
    array['all', 'repair', 'mis', 'product', 'other']::text[]
  ) then
    raise exception 'Sales category is invalid';
  end if;

  with selected_stores as materialized (
    select store.id, store.store_code, store.store_name
    from public.store_locations store
    where store.active = true
      and store.store_code = any (
        array['parkridge', 'fairfield', 'northlakes', 'toowong']::text[]
      )
      and (store_value = '' or store.store_code = store_value)
  ),
  sale_line_movements as materialized (
    select
      'sale'::text as event_type,
      'sale:' || sales_order.id::text as event_key,
      sales_order.created_at as transaction_at,
      sales_order.business_date as transaction_date,
      store.store_code,
      store.store_name,
      sales_order.invoice_number,
      sales_order.order_code,
      ''::text as refund_code,
      ''::text as reason,
      sales_order.customer_name,
      sales_order.customer_phone,
      sales_order.customer_email,
      sales_order.staff_name,
      sales_order.payment_method,
      sales_order.payment_status,
      sales_order.total as invoice_total,
      sales_order.amount_paid,
      greatest(sales_order.total - sales_order.amount_paid, 0) as balance_due,
      case
        when sales_line.line_type = 'repair' then 'repair'
        when sales_line.line_type = 'used_device' then 'mis'
        when sales_line.line_type in ('product', 'retail') then 'product'
        else 'other'
      end as category_key,
      sales_line.id as line_id,
      sales_line.name as item_name,
      sales_line.sku,
      sales_line.quantity,
      sales_line.unit_price,
      sales_line.line_total as amount,
      coalesce(repair_ticket.ticket_code, '') as ticket_code,
      coalesce(
        nullif(trim(sales_line.line_payload->>'note'), ''),
        nullif(trim(sales_line.line_payload->>'notes'), ''),
        nullif(trim(sales_line.line_payload->>'description'), ''),
        ''
      ) as line_note
    from public.pos_sales_orders sales_order
    join selected_stores store on store.id = sales_order.store_id
    join public.pos_sales_order_lines sales_line
      on sales_line.sales_order_id = sales_order.id
    left join public.pos_repair_tickets repair_ticket
      on repair_ticket.id = sales_line.repair_ticket_id
    where sales_order.business_date between from_value and to_value
  ),
  refund_line_movements as materialized (
    select
      'refund'::text as event_type,
      'refund:' || refund.id::text as event_key,
      refund.created_at as transaction_at,
      coalesce(
        refund.business_date,
        (refund.created_at at time zone 'Australia/Brisbane')::date
      ) as transaction_date,
      store.store_code,
      store.store_name,
      sales_order.invoice_number,
      sales_order.order_code,
      refund.refund_code,
      refund.reason,
      sales_order.customer_name,
      sales_order.customer_phone,
      sales_order.customer_email,
      refund.staff_name,
      refund.method as payment_method,
      sales_order.payment_status,
      sales_order.total as invoice_total,
      sales_order.amount_paid,
      greatest(sales_order.total - sales_order.amount_paid, 0) as balance_due,
      case
        when sales_line.line_type = 'repair' then 'repair'
        when sales_line.line_type = 'used_device' then 'mis'
        when sales_line.line_type in ('product', 'retail') then 'product'
        else 'other'
      end as category_key,
      sales_line.id as line_id,
      sales_line.name as item_name,
      sales_line.sku,
      refund_line.returned_quantity as quantity,
      sales_line.unit_price,
      -refund_line.amount as amount,
      coalesce(repair_ticket.ticket_code, '') as ticket_code,
      coalesce(
        nullif(trim(sales_line.line_payload->>'note'), ''),
        nullif(trim(sales_line.line_payload->>'notes'), ''),
        nullif(trim(sales_line.line_payload->>'description'), ''),
        ''
      ) as line_note
    from public.pos_sales_refunds refund
    join selected_stores store on store.id = refund.store_id
    join public.pos_sales_orders sales_order on sales_order.id = refund.sales_order_id
    join public.pos_sales_refund_lines refund_line on refund_line.refund_id = refund.id
    join public.pos_sales_order_lines sales_line on sales_line.id = refund_line.sales_order_line_id
    left join public.pos_repair_tickets repair_ticket
      on repair_ticket.id = sales_line.repair_ticket_id
    where coalesce(
      refund.business_date,
      (refund.created_at at time zone 'Australia/Brisbane')::date
    ) between from_value and to_value
  ),
  filtered_lines as materialized (
    select * from sale_line_movements
    where category_value = 'all' or category_key = category_value
    union all
    select * from refund_line_movements
    where category_value = 'all' or category_key = category_value
  ),
  grouped_movements as materialized (
    select
      event_type,
      event_key,
      max(transaction_at) as transaction_at,
      max(transaction_date) as transaction_date,
      store_code,
      store_name,
      invoice_number,
      order_code,
      max(refund_code) as refund_code,
      max(reason) as reason,
      max(customer_name) as customer_name,
      max(customer_phone) as customer_phone,
      max(customer_email) as customer_email,
      max(staff_name) as staff_name,
      max(payment_method) as payment_method,
      max(payment_status) as payment_status,
      max(invoice_total) as invoice_total,
      max(amount_paid) as amount_paid,
      max(balance_due) as balance_due,
      case when count(distinct category_key) = 1 then min(category_key) else 'mixed' end as category_key,
      string_agg(distinct nullif(ticket_code, ''), ', ') as ticket_codes,
      sum(amount) as amount,
      sum(greatest(quantity, 0))::integer as item_count,
      jsonb_agg(jsonb_build_object(
        'line_id', line_id,
        'category', category_key,
        'name', item_name,
        'sku', sku,
        'quantity', quantity,
        'unit_price', unit_price,
        'amount', amount,
        'ticket_code', ticket_code,
        'note', line_note
      ) order by line_id) as items,
      lower(concat_ws(' ',
        invoice_number::text,
        order_code,
        max(refund_code),
        max(customer_name),
        max(customer_phone),
        max(customer_email),
        max(staff_name),
        string_agg(item_name, ' '),
        string_agg(coalesce(sku, ''), ' '),
        string_agg(coalesce(ticket_code, ''), ' ')
      )) as search_text
    from filtered_lines
    group by event_type, event_key, store_code, store_name, invoice_number, order_code
  ),
  searched_movements as materialized (
    select *
    from grouped_movements movement
    where query_value = '' or movement.search_text like '%' || query_value || '%'
  ),
  summary as (
    select
      round(coalesce(sum(case when event_type = 'sale' then amount else 0 end), 0), 2) as sales,
      round(abs(coalesce(sum(case when event_type = 'refund' then amount else 0 end), 0)), 2) as refunds,
      round(coalesce(sum(amount), 0), 2) as net,
      count(*)::integer as transaction_count
    from searched_movements
  )
  select jsonb_build_object(
    'ok', true,
    'date_from', from_value,
    'date_to', to_value,
    'store_code', store_value,
    'store_name', case when store_value = '' then 'All Stores'
      else coalesce((select min(store_name) from selected_stores), store_value) end,
    'category', category_value,
    'query', query_value,
    'limit', limit_value,
    'offset', offset_value,
    'has_more', summary.transaction_count > offset_value + limit_value,
    'summary', jsonb_build_object(
      'sales', summary.sales,
      'refunds', summary.refunds,
      'net', summary.net,
      'transaction_count', summary.transaction_count
    ),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type', page.event_type,
        'event_key', page.event_key,
        'transaction_at', page.transaction_at,
        'transaction_date', page.transaction_date,
        'store_code', page.store_code,
        'store_name', page.store_name,
        'invoice_number', page.invoice_number,
        'order_code', page.order_code,
        'refund_code', page.refund_code,
        'reason', page.reason,
        'customer_name', page.customer_name,
        'customer_phone', page.customer_phone,
        'customer_email', page.customer_email,
        'staff_name', page.staff_name,
        'payment_method', page.payment_method,
        'payment_status', page.payment_status,
        'invoice_total', page.invoice_total,
        'amount_paid', page.amount_paid,
        'balance_due', page.balance_due,
        'category', page.category_key,
        'ticket_codes', coalesce(page.ticket_codes, ''),
        'item_count', page.item_count,
        'amount', round(page.amount, 2),
        'items', page.items
      ) order by page.transaction_at desc, page.event_key desc)
      from (
        select *
        from searched_movements
        order by transaction_at desc, event_key desc
        limit limit_value offset offset_value
      ) page
    ), '[]'::jsonb)
  ) into result_payload
  from summary;

  return result_payload;
end;
$$;

revoke all on function public.get_admin_sales_drilldown(
  text, date, date, text, text, text, integer, integer
) from public, anon, authenticated;
grant execute on function public.get_admin_sales_drilldown(
  text, date, date, text, text, text, integer, integer
) to anon, authenticated, service_role;

comment on function public.get_admin_sales_drilldown(
  text, date, date, text, text, text, integer, integer
) is
  'Admin-session-only paginated sales and refund movements. Uses the same category and date attribution rules as the four-store overview.';
