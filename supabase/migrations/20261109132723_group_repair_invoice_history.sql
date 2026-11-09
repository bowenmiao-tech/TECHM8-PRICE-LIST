-- Select one checkout per matching invoice before pagination. The existing
-- payload keeps original checkout amounts and exposes the full receipt in invoice.
CREATE OR REPLACE FUNCTION public.search_pos_sales_orders(session_token text, target_store_code text, search_query text DEFAULT ''::text, result_limit integer DEFAULT 100, result_offset integer DEFAULT 0, date_from date DEFAULT NULL::date, date_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  access_result jsonb;
  selected_store public.store_locations%rowtype;
  orders_payload jsonb;
  query_value text := trim(coalesce(search_query, ''));
  phone_query text := regexp_replace(coalesce(search_query, ''), '[^0-9]', '', 'g');
  safe_limit integer := least(greatest(coalesce(result_limit, 100), 1), 200);
  safe_offset integer := greatest(coalesce(result_offset, 0), 0);
begin
  access_result := public.verify_staff_store_access(session_token, target_store_code);
  if not coalesce((access_result->>'ok')::boolean, false)
    or not coalesce((access_result->>'allowed')::boolean, false) then
    raise exception '%', coalesce(access_result->>'message', 'Store access denied');
  end if;
  if date_from is not null and date_to is not null and date_from > date_to then
    raise exception 'Start date must not be after end date';
  end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = lower(trim(coalesce(target_store_code, '')))
    and store_location.store_code <> 'warehouse';
  if not found then raise exception 'Store not found'; end if;

  select coalesce(
    jsonb_agg(public.pos_sales_order_payload(sales_order) order by sales_order.created_at desc),
    '[]'::jsonb
  ) into orders_payload
  from (
    select grouped.* from (
    select distinct on (sales_order.invoice_number) sales_order.*
    from public.pos_sales_orders sales_order
    where sales_order.store_id = selected_store.id
      and (date_from is null or sales_order.business_date >= date_from)
      and (date_to is null or sales_order.business_date <= date_to)
      and (
        query_value = ''
        or sales_order.invoice_number::text ilike '%' || query_value || '%'
        or sales_order.order_code ilike '%' || query_value || '%'
        or sales_order.customer_name ilike '%' || query_value || '%'
        or sales_order.customer_phone ilike '%' || query_value || '%'
        or (phone_query <> '' and regexp_replace(sales_order.customer_phone, '[^0-9]', '', 'g') like '%' || phone_query || '%')
        or exists (
          select 1
          from public.pos_sales_order_lines sales_line
          left join public.pos_repair_tickets repair_ticket on repair_ticket.id = sales_line.repair_ticket_id
          where sales_line.sales_order_id = sales_order.id
            and (
              sales_line.name ilike '%' || query_value || '%'
              or sales_line.sku ilike '%' || query_value || '%'
              or repair_ticket.ticket_code ilike '%' || query_value || '%'
              or coalesce(sales_line.line_payload->>'source_ticket_id', '') ilike '%' || query_value || '%'
              or coalesce(sales_line.line_payload->>'source_serial', '') ilike '%' || query_value || '%'
              or coalesce(sales_line.line_payload->>'source_device', '') ilike '%' || query_value || '%'
              or coalesce(sales_line.line_payload->>'source_description', '') ilike '%' || query_value || '%'
              or coalesce(sales_line.line_payload->>'source_invoice_notes', '') ilike '%' || query_value || '%'
              or coalesce(sales_line.line_payload->>'note', '') ilike '%' || query_value || '%'
            )
        )
      )
    order by sales_order.invoice_number, sales_order.created_at desc, sales_order.id desc
    ) grouped
    order by grouped.created_at desc, grouped.id desc
    limit safe_limit offset safe_offset
  ) sales_order;

  return jsonb_build_object(
    'ok', true,
    'store_code', selected_store.store_code,
    'orders', orders_payload,
    'date_from', date_from,
    'date_to', date_to
  );
end;
$function$

