drop function if exists public.search_pos_sales_orders(text, text, text, integer, integer);

create or replace function public.search_pos_sales_orders(
  session_token text,
  target_store_code text,
  search_query text default '',
  result_limit integer default 100,
  result_offset integer default 0,
  date_from date default null,
  date_to date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  orders_payload jsonb;
  query_value text := trim(coalesce(search_query, ''));
  phone_query text := regexp_replace(coalesce(search_query, ''), '[^0-9]', '', 'g');
  safe_limit integer := least(greatest(coalesce(result_limit, 100), 1), 200);
  safe_offset integer := greatest(coalesce(result_offset, 0), 0);
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;
  if date_from is not null and date_to is not null and date_from > date_to then
    raise exception 'Start date must not be after end date';
  end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = coalesce(trim(target_store_code), '')
    and store_location.store_code <> 'warehouse';
  if not found then raise exception 'Store not found'; end if;

  select coalesce(
    jsonb_agg(public.pos_sales_order_payload(sales_order) order by sales_order.created_at desc),
    '[]'::jsonb
  ) into orders_payload
  from (
    select sales_order.*
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
            )
        )
      )
    order by sales_order.created_at desc
    limit safe_limit offset safe_offset
  ) sales_order;

  return jsonb_build_object(
    'ok', true,
    'orders', orders_payload,
    'date_from', date_from,
    'date_to', date_to
  );
end;
$$;

revoke execute on function public.search_pos_sales_orders(text, text, text, integer, integer, date, date) from public;
grant execute on function public.search_pos_sales_orders(text, text, text, integer, integer, date, date) to anon, authenticated, service_role;
