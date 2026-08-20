-- Customer records are returned only after an intentional search. The POS uses
-- two or more characters and renders name, phone, and email matches on demand.
create or replace function public.search_pos_customers(
  session_token text,
  target_store_code text,
  search_query text default '',
  result_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  customers_payload jsonb;
  query_value text := trim(coalesce(search_query, ''));
  query_lower text := lower(trim(coalesce(search_query, '')));
  phone_query text := regexp_replace(coalesce(search_query, ''), '[^0-9]', '', 'g');
  safe_limit integer := least(greatest(coalesce(result_limit, 100), 1), 500);
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = coalesce(trim(target_store_code), '')
    and store_location.store_code <> 'warehouse';
  if not found then raise exception 'Store not found'; end if;

  if char_length(query_value) < 2 then
    return jsonb_build_object('ok', true, 'customers', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(
    public.pos_customer_payload(customer.customer_row)
    order by customer.search_rank,
      (customer.customer_row).first_name,
      (customer.customer_row).last_name,
      (customer.customer_row).updated_at desc
  ), '[]'::jsonb)
  into customers_payload
  from (
    select customer as customer_row,
      case
        when lower(concat_ws(' ', customer.first_name, customer.last_name)) = query_lower then 0
        when phone_query <> '' and customer.normalized_phone = phone_query then 0
        when lower(customer.email) = query_lower then 0
        when lower(concat_ws(' ', customer.first_name, customer.last_name)) like query_lower || '%' then 1
        when phone_query <> '' and customer.normalized_phone like phone_query || '%' then 1
        else 2
      end as search_rank
    from public.pos_customers customer
    where customer.active = true
      and (
        customer.first_name ilike '%' || query_value || '%'
        or customer.last_name ilike '%' || query_value || '%'
        or concat_ws(' ', customer.first_name, customer.last_name) ilike '%' || query_value || '%'
        or customer.company ilike '%' || query_value || '%'
        or customer.phone ilike '%' || query_value || '%'
        or customer.alert_number ilike '%' || query_value || '%'
        or customer.email ilike '%' || query_value || '%'
        or customer.customer_code ilike '%' || query_value || '%'
        or (phone_query <> '' and customer.normalized_phone like '%' || phone_query || '%')
      )
    order by search_rank, customer.first_name, customer.last_name, customer.updated_at desc
    limit safe_limit
  ) customer;

  return jsonb_build_object('ok', true, 'customers', customers_payload);
end;
$$;

revoke all on function public.search_pos_customers(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.search_pos_customers(text, text, text, integer) to anon, authenticated, service_role;
