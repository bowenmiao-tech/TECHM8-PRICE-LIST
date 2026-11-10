-- A walk-in customer has no account to hold Store Credit, so an exchange for
-- them nets the return against the new items as Cash: the same amount is
-- refunded and paid in Cash in one transaction, which leaves the till
-- unchanged. With a customer account the return still goes through Store
-- Credit as before.
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
  netting_method text;
  order_code_value text := coalesce(trim(payload->>'id'), '');
  existing_order public.pos_sales_orders%rowtype;
begin
  if jsonb_typeof(payload) <> 'object' or jsonb_typeof(exchange_payload) <> 'object' then
    raise exception 'Exchange refund details are required';
  end if;
  if jsonb_typeof(exchange_payload->'lines') <> 'array'
    or jsonb_array_length(exchange_payload->'lines') = 0 then
    raise exception 'Select at least one item to return';
  end if;
  if order_code_value = '' then raise exception 'Order id is required'; end if;
  netting_method := case when customer_code_value = '' then 'Cash' else 'Store Credit' end;

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
  -- Without an account nothing can be left over as credit.
  if customer_code_value = '' and refund_total <> expected_exchange_payment then
    raise exception 'Select a customer account to keep the rest of the return as Store Credit';
  end if;

  refund_result := public.refund_pos_sales_order_for_store(
    session_token,
    exchange_payload || jsonb_build_object(
      'store_code', payload->>'store_code',
      'staff_name', payload->>'staff_name',
      'shift_id', payload->>'shift_id',
      'business_date', payload->>'business_date',
      'refund_method', netting_method,
      'customer_code', customer_code_value
    )
  );

  select coalesce(jsonb_agg(
    case when lower(trim(payment->>'method')) = 'exchange credit'
      then jsonb_set(payment, '{method}', to_jsonb(netting_method))
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
      'customer_code', case when customer_code_value = ''
        then coalesce(payload->>'customer_code', '') else customer_code_value end,
      'payment_method', (
        select string_agg(distinct case
          when lower(trim(payment->>'method')) = 'exchange credit' then netting_method
          else payment->>'method' end, ' + ' order by case
          when lower(trim(payment->>'method')) = 'exchange credit' then netting_method
          else payment->>'method' end)
        from jsonb_array_elements(coalesce(payload->'payments', '[]'::jsonb)) payment
        where coalesce(nullif(payment->>'amount', '')::numeric, 0) > 0
      ),
      'exchange_source', jsonb_build_object(
        'order_id', exchange_payload->>'order_id',
        'invoice_number', refund_result #>> '{order,invoice_number}',
        'refund_id', refund_result->>'refund_id',
        'netting_method', netting_method,
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

revoke all on function public.save_pos_exchange_order_for_store(text,jsonb) from public,anon,authenticated;
grant execute on function public.save_pos_exchange_order_for_store(text,jsonb) to service_role;
