-- Preserve the established paid/deposit path and add a tightly scoped zero-sale path.
alter function public.save_pos_sales_order(text,jsonb)
  rename to save_pos_sales_order_before_zero_checkout;

create function public.save_pos_sales_order(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  selected_staff public.staff_directory%rowtype;
  saved_order public.pos_sales_orders%rowtype;
  order_code_value text;
  created_at_value timestamptz;
  business_date_value date;
  total_value numeric(12,2);
  item_total numeric(12,2);
  payment_total numeric(12,2);
  next_invoice_number bigint;
  repair_item_count integer;
  repair_ticket_count integer;
  repair_distinct_ticket_count integer;
  shift_id_value text;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Order payload must be a JSON object'; end if;
  total_value := round(coalesce(nullif(payload->>'total', '')::numeric, 0), 2);
  if total_value > 0 then
    return public.save_pos_sales_order_before_zero_checkout(session_token, payload);
  end if;
  if total_value < 0 then raise exception 'Order total cannot be negative'; end if;
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;

  order_code_value := coalesce(trim(payload->>'id'), '');
  if order_code_value = '' then raise exception 'Order id is required'; end if;
  if jsonb_typeof(payload->'items') <> 'array' or jsonb_array_length(payload->'items') = 0 then
    raise exception 'Order must contain at least one item';
  end if;

  select round(coalesce(sum(coalesce(nullif(payment->>'amount', '')::numeric, 0)), 0), 2)
  into payment_total from jsonb_array_elements(coalesce(payload->'payments', '[]'::jsonb)) payment;
  if payment_total <> 0 then raise exception 'A zero-dollar order cannot contain a payment'; end if;

  select round(coalesce(sum(
    coalesce(
      nullif(item->>'line_total', '')::numeric,
      coalesce(nullif(item->>'unit_price', '')::numeric, nullif(item->>'sale_price', '')::numeric, 0)
        * greatest(coalesce(nullif(item->>'qty', '')::integer, 1), 1)
    )
  ), 0), 2)
  into item_total from jsonb_array_elements(payload->'items') item;
  if item_total <> 0 then raise exception 'Order item total does not match order total'; end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and (
      lower(regexp_replace(store_location.store_code, '[^a-z0-9]', '', 'g')) =
        lower(regexp_replace(coalesce(payload->>'store_db_code', payload->>'store_id', ''), '[^a-z0-9]', '', 'g'))
      or upper(store_location.store_code) = upper(coalesce(payload->>'store_code', ''))
    )
  limit 1;
  if not found then raise exception 'Store not found'; end if;

  select * into selected_staff
  from public.staff_directory staff
  where staff.active = true and lower(staff.display_name) = lower(coalesce(trim(payload->>'staff_name'), ''))
  limit 1;
  if not found then raise exception 'Staff member not found'; end if;

  created_at_value := coalesce(nullif(payload->>'created_at', '')::timestamptz, now());
  business_date_value := coalesce(
    nullif(payload->>'business_date', '')::date,
    (created_at_value at time zone 'Australia/Brisbane')::date
  );
  shift_id_value := nullif(trim(payload->>'shift_id'), '');

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(order_code_value, 0));
  select * into saved_order
  from public.pos_sales_orders sales_order
  where sales_order.order_code = order_code_value
  for update;
  if found then
    if saved_order.store_id <> selected_store.id then raise exception 'Order store cannot be changed'; end if;
    return jsonb_build_object('ok', true, 'order', public.pos_sales_order_payload(saved_order));
  end if;

  select count(*) into repair_item_count
  from jsonb_array_elements(payload->'items') item
  where lower(coalesce(item->>'is_repair', 'false')) = 'true';

  select count(distinct coalesce(
    nullif(trim(item->>'ticket_id'), ''),
    nullif(regexp_replace(coalesce(item->>'product_id', ''), '^repair-', ''), coalesce(item->>'product_id', ''))
  )) into repair_distinct_ticket_count
  from jsonb_array_elements(payload->'items') item
  where lower(coalesce(item->>'is_repair', 'false')) = 'true';

  if repair_item_count > 0 then
    if coalesce(trim(payload->>'customer_name'), '') = ''
      or lower(trim(payload->>'customer_name')) = 'walk-in customer' then
      raise exception 'Customer name is required for repair sales';
    end if;
    if coalesce(trim(payload->>'customer_phone'), '') = '' then
      raise exception 'Customer phone is required for repair sales';
    end if;
    if exists (
      select 1 from jsonb_array_elements(payload->'items') item
      where lower(coalesce(item->>'is_repair', 'false')) = 'true'
        and coalesce(
          nullif(trim(item->>'ticket_id'), ''),
          nullif(regexp_replace(coalesce(item->>'product_id', ''), '^repair-', ''), coalesce(item->>'product_id', ''))
        ) is null
    ) then raise exception 'Repair sale item is missing ticket id'; end if;

    perform 1
    from public.pos_repair_tickets repair_ticket
    where repair_ticket.ticket_code in (
      select coalesce(
        nullif(trim(item->>'ticket_id'), ''),
        nullif(regexp_replace(coalesce(item->>'product_id', ''), '^repair-', ''), coalesce(item->>'product_id', ''))
      )
      from jsonb_array_elements(payload->'items') item
      where lower(coalesce(item->>'is_repair', 'false')) = 'true'
    )
    for update;

    select count(*) into repair_ticket_count
    from public.pos_repair_tickets repair_ticket
    where repair_ticket.ticket_code in (
      select coalesce(
        nullif(trim(item->>'ticket_id'), ''),
        nullif(regexp_replace(coalesce(item->>'product_id', ''), '^repair-', ''), coalesce(item->>'product_id', ''))
      )
      from jsonb_array_elements(payload->'items') item
      where lower(coalesce(item->>'is_repair', 'false')) = 'true'
    )
      and repair_ticket.store_id = selected_store.id
      and repair_ticket.active = true
      and repair_ticket.closed_at is null;
    if repair_ticket_count <> repair_distinct_ticket_count then
      raise exception 'Repair ticket is missing, closed, or belongs to another store';
    end if;

    if exists (
      select 1 from jsonb_array_elements(payload->'items') item
      where lower(coalesce(item->>'is_repair', 'false')) = 'true'
        and nullif(btrim(coalesce(item->>'repair_job_id', '')), '') is not null
        and not exists (
          select 1
          from public.pos_repair_ticket_jobs job
          join public.pos_repair_tickets owner_ticket on owner_ticket.id = job.repair_ticket_id
          where job.job_code = btrim(item->>'repair_job_id')
            and owner_ticket.ticket_code = coalesce(
              nullif(trim(item->>'ticket_id'), ''),
              nullif(regexp_replace(coalesce(item->>'product_id', ''), '^repair-', ''), coalesce(item->>'product_id', ''))
            )
        )
    ) then raise exception 'Repair job does not belong to this ticket'; end if;

    if exists (
      select 1
      from jsonb_array_elements(payload->'items') item
      join public.pos_repair_tickets repair_ticket
        on repair_ticket.ticket_code = coalesce(
          nullif(trim(item->>'ticket_id'), ''),
          nullif(regexp_replace(coalesce(item->>'product_id', ''), '^repair-', ''), coalesce(item->>'product_id', ''))
        )
      left join public.pos_repair_ticket_jobs job
        on job.job_code = nullif(btrim(coalesce(item->>'repair_job_id', '')), '')
       and job.repair_ticket_id = repair_ticket.id
      join public.pos_sales_order_lines sales_line
        on sales_line.repair_ticket_id = repair_ticket.id
       and sales_line.repair_job_id is not distinct from job.id
      where lower(coalesce(item->>'is_repair', 'false')) = 'true'
    ) then raise exception 'This repair has already been invoiced'; end if;
  end if;

  insert into public.pos_store_invoice_counters(store_id, last_number)
  values (selected_store.id, 1)
  on conflict (store_id) do update set
    last_number = public.pos_store_invoice_counters.last_number + 1,
    updated_at = now()
  returning last_number into next_invoice_number;

  insert into public.pos_sales_orders(
    order_code, invoice_number, store_id, business_date, staff_name, shift_id,
    customer_name, customer_phone, customer_email, payment_method, total,
    payment_status, amount_paid, order_payload, created_at
  ) values (
    order_code_value, next_invoice_number, selected_store.id, business_date_value,
    selected_staff.display_name, shift_id_value,
    coalesce(nullif(trim(payload->>'customer_name'), ''), 'Walk-in Customer'),
    coalesce(trim(payload->>'customer_phone'), ''),
    coalesce(trim(payload->>'customer_email'), ''),
    'No Charge', 0, 'paid', 0,
    payload || jsonb_build_object('sync_pending', false, 'payment_method', 'No Charge', 'payment_status', 'paid'),
    created_at_value
  ) returning * into saved_order;

  insert into public.pos_sales_order_lines(
    sales_order_id, line_number, line_type, product_id, repair_ticket_id,
    sku, name, category, quantity, unit_price, line_total, line_payload, created_at,
    repair_job_id
  )
  select
    saved_order.id, item.ordinality::integer,
    case
      when lower(coalesce(item.value->>'is_repair', 'false')) = 'true' then 'repair'
      when lower(coalesce(item.value->>'is_used_device', 'false')) = 'true' then 'used_device'
      when lower(coalesce(item.value->>'is_special', 'false')) = 'true'
        or coalesce(item.value->>'product_id', '') like 'special-%' then 'special'
      else 'product'
    end,
    coalesce(item.value->>'product_id', item.value->>'id', ''),
    repair_ticket.id,
    coalesce(item.value->>'sku', ''),
    coalesce(nullif(trim(item.value->>'name'), ''), 'Sale item'),
    coalesce(item.value->>'category', ''),
    greatest(coalesce(nullif(item.value->>'qty', '')::integer, 1), 1),
    0, 0, item.value, created_at_value, repair_job.id
  from jsonb_array_elements(payload->'items') with ordinality as item(value, ordinality)
  left join public.pos_repair_tickets repair_ticket
    on repair_ticket.ticket_code = coalesce(
      nullif(trim(item.value->>'ticket_id'), ''),
      nullif(regexp_replace(coalesce(item.value->>'product_id', ''), '^repair-', ''), coalesce(item.value->>'product_id', ''))
    )
  left join public.pos_repair_ticket_jobs repair_job
    on repair_job.job_code = nullif(btrim(coalesce(item.value->>'repair_job_id', '')), '')
   and repair_job.repair_ticket_id = repair_ticket.id;

  if repair_item_count > 0 then
    perform public.close_pos_repair_tickets_for_order(
      saved_order.id, selected_staff.display_name, next_invoice_number,
      saved_order.customer_name, saved_order.customer_phone,
      coalesce(nullif(lower(btrim(payload->>'close_repair_tickets')), '')::boolean, true)
    );
  end if;
  return jsonb_build_object('ok', true, 'order', public.pos_sales_order_payload(saved_order));
end;
$$;

create or replace function public.save_pos_sales_order_for_store(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  shift_context jsonb;
  sanitized_payload jsonb;
  total_value numeric(12,2);
  payment_total numeric(12,2);
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Order payload must be a JSON object'; end if;
  shift_context := public.pos_open_shift_context(
    session_token,
    coalesce(payload->>'store_db_code', payload->>'store_code', payload->>'store_id'),
    payload->>'shift_id', payload->>'staff_name', true
  );
  total_value := round(coalesce(nullif(payload->>'total', '')::numeric, 0), 2);
  select round(coalesce(sum(coalesce(nullif(payment->>'amount', '')::numeric, 0)), 0), 2)
  into payment_total from jsonb_array_elements(coalesce(payload->'payments', '[]'::jsonb)) payment;
  if total_value < 0 then raise exception 'Order total cannot be negative'; end if;
  if total_value = 0 and payment_total <> 0 then raise exception 'A zero-dollar order cannot contain a payment'; end if;
  if total_value > 0 and payment_total <= 0 then raise exception 'Payment amount must be above zero'; end if;
  if payment_total > total_value then raise exception 'Payment is more than the order total'; end if;

  sanitized_payload := payload || jsonb_build_object(
    'store_db_code', shift_context->>'store_code',
    'store_code', shift_context->>'store_code',
    'store_id', shift_context->>'store_code',
    'store_name', shift_context->>'store_name',
    'staff_name', shift_context->>'staff_name',
    'shift_id', shift_context->>'shift_id',
    'business_date', shift_context->>'business_date',
    'created_at', now(),
    'payment_status', case when total_value = 0 or payment_total >= total_value then 'paid' else 'deposit' end,
    'payment_method', case when total_value = 0 then 'No Charge' else payload->>'payment_method' end
  );
  return public.save_pos_sales_order(session_token, sanitized_payload);
end;
$$;

-- The return and replacement sale are one transaction. The refund first creates
-- Store Credit; the replacement invoice immediately spends only the amount used.
create or replace function public.save_pos_exchange_order_for_store(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  exchange_payload jsonb := payload->'exchange_refund';
  refund_result jsonb;
  save_result jsonb;
  transformed_payments jsonb;
  refund_total numeric(12,2);
  order_total numeric(12,2) := round(coalesce(nullif(payload->>'total', '')::numeric, 0), 2);
  exchange_payment numeric(12,2);
  expected_exchange_payment numeric(12,2);
  customer_code_value text := coalesce(trim(exchange_payload->>'customer_code'), '');
  order_code_value text := coalesce(trim(payload->>'id'), '');
  existing_order public.pos_sales_orders%rowtype;
begin
  if jsonb_typeof(payload) <> 'object' or jsonb_typeof(exchange_payload) <> 'object' then
    raise exception 'Exchange refund details are required';
  end if;
  if customer_code_value = '' then raise exception 'Select a customer account for the exchange'; end if;
  if jsonb_typeof(exchange_payload->'lines') <> 'array'
    or jsonb_array_length(exchange_payload->'lines') = 0 then
    raise exception 'Select at least one item to return';
  end if;
  if order_code_value = '' then raise exception 'Order id is required'; end if;

  -- A network retry must return the already-created replacement invoice. It
  -- must never issue the original return credit a second time.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(order_code_value, 0));
  select * into existing_order
  from public.pos_sales_orders sales_order
  where sales_order.order_code = order_code_value
  for update;
  if found then
    return jsonb_build_object(
      'ok', true,
      'order', public.pos_sales_order_payload(existing_order),
      'exchange_refund_id', existing_order.order_payload #>> '{exchange_source,refund_id}'
    );
  end if;
  select round(coalesce(sum(coalesce(nullif(line->>'amount', '')::numeric, 0)), 0), 2)
  into refund_total from jsonb_array_elements(exchange_payload->'lines') line;
  if refund_total <= 0 then raise exception 'Exchange return amount must be above zero'; end if;
  expected_exchange_payment := least(refund_total, greatest(order_total, 0));
  select round(coalesce(sum(coalesce(nullif(payment->>'amount', '')::numeric, 0)), 0), 2)
  into exchange_payment
  from jsonb_array_elements(coalesce(payload->'payments', '[]'::jsonb)) payment
  where lower(trim(payment->>'method')) = 'exchange credit';
  if exchange_payment <> expected_exchange_payment then
    raise exception 'Exchange Credit must equal the return amount used on this sale';
  end if;

  refund_result := public.refund_pos_sales_order_for_store(
    session_token,
    exchange_payload || jsonb_build_object(
      'store_code', payload->>'store_code',
      'staff_name', payload->>'staff_name',
      'shift_id', payload->>'shift_id',
      'business_date', payload->>'business_date',
      'refund_method', 'Store Credit',
      'customer_code', customer_code_value
    )
  );

  select coalesce(jsonb_agg(
    case when lower(trim(payment->>'method')) = 'exchange credit'
      then jsonb_set(payment, '{method}', to_jsonb('Store Credit'::text))
      else payment end
    order by ordinality
  ), '[]'::jsonb)
  into transformed_payments
  from jsonb_array_elements(coalesce(payload->'payments', '[]'::jsonb))
    with ordinality as entry(payment, ordinality);

  save_result := public.save_pos_sales_order_for_store(
    session_token,
    (payload - 'exchange_refund') || jsonb_build_object(
      'payments', transformed_payments,
      'customer_code', customer_code_value,
      'payment_method', (
        select string_agg(distinct case
          when lower(trim(payment->>'method')) = 'exchange credit' then 'Store Credit'
          else payment->>'method' end, ' + ' order by case
          when lower(trim(payment->>'method')) = 'exchange credit' then 'Store Credit'
          else payment->>'method' end)
        from jsonb_array_elements(coalesce(payload->'payments', '[]'::jsonb)) payment
        where coalesce(nullif(payment->>'amount', '')::numeric, 0) > 0
      ),
      'exchange_source', jsonb_build_object(
        'order_id', exchange_payload->>'order_id',
        'invoice_number', refund_result #>> '{order,invoice_number}',
        'refund_id', refund_result->>'refund_id',
        'credit_issued', refund_total,
        'credit_used', expected_exchange_payment
      )
    )
  );
  return save_result || jsonb_build_object(
    'exchange_refund_id', refund_result->>'refund_id',
    'exchange_order', refund_result->'order',
    'exchange_credit_issued', refund_total,
    'exchange_credit_used', expected_exchange_payment,
    'store_credit_remaining', refund_total - expected_exchange_payment
  );
end;
$$;

revoke all on function public.save_pos_sales_order_before_zero_checkout(text,jsonb)
  from public,anon,authenticated;
revoke all on function public.save_pos_sales_order(text,jsonb) from public,anon,authenticated;
revoke all on function public.save_pos_exchange_order_for_store(text,jsonb) from public,anon,authenticated;
grant execute on function public.save_pos_sales_order(text,jsonb) to service_role;
grant execute on function public.save_pos_exchange_order_for_store(text,jsonb) to service_role;

comment on function public.save_pos_exchange_order_for_store(text,jsonb) is
  'Atomically records a returned item as Store Credit and applies the used credit to its replacement invoice.';

-- A special repair may be opened before its final charge is known. Ordinary
-- repairs still require a positive agreed price.
create or replace function public.enforce_pos_repair_ticket_numeric_price()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  raw_price text := btrim(coalesce(new.price, ''));
  numeric_price numeric(12,2);
begin
  if raw_price !~ '^[$]?[0-9]+([.][0-9]{1,2})?$' then
    raise exception 'Repair price must be one numeric amount, not a range';
  end if;
  numeric_price := replace(raw_price, '$', '')::numeric;
  if numeric_price < 0 or numeric_price > 1000000
    or (numeric_price = 0 and not coalesce(new.special_order, false)) then
    raise exception 'Ordinary repair price must be above zero; only a special repair may start at zero';
  end if;
  new.price := '$' || to_char(numeric_price, 'FM999999990.00');
  return new;
end;
$$;

do $$
declare
  function_definition text;
  anchor text := $anchor$  if numeric_price !~ '^[0-9]+(\.[0-9]{1,2})?$' or numeric_price::numeric <= 0 then$anchor$;
  replacement text := $replacement$  if numeric_price !~ '^[0-9]+(\.[0-9]{1,2})?$'
    or numeric_price::numeric < 0
    or (numeric_price::numeric = 0 and not coalesce(new.special_order, false)) then$replacement$;
begin
  select pg_catalog.pg_get_functiondef(
    'public.enforce_complete_new_pos_repair_ticket()'::regprocedure
  ) into function_definition;
  if pg_catalog.strpos(function_definition, anchor) = 0 then
    raise exception 'The new-ticket repair price validation changed unexpectedly';
  end if;
  execute pg_catalog.replace(function_definition, anchor, replacement);
end;
$$;

comment on function public.enforce_pos_repair_ticket_numeric_price() is
  'Requires a positive repair price, except special repairs may start at exactly zero.';
