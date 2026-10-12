-- A deposit invoice's balance is paid through the cart, so a customer who
-- collects a repair and buys a case at the same time pays one total. The
-- new items still get their own invoice and the balance still lands on the
-- original invoice; this function only makes both writes one transaction,
-- so a failure cannot leave the card charged with half the sale saved.
create or replace function public.checkout_pos_cart_with_balances_for_store(
  session_token text,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  shift_context jsonb;
  store_id_value bigint;
  sale_payload jsonb := payload->'order';
  sale_code text := '';
  sale_total numeric(12,2);
  sale_paid numeric(12,2);
  existing_sale public.pos_sales_orders%rowtype;
  balance_entry jsonb;
  balance_code text;
  balance_order public.pos_sales_orders%rowtype;
  balance_before numeric(12,2);
  expected_balance numeric(12,2);
  allocated numeric(12,2);
  payment_result jsonb;
  paid_order jsonb;
  seen_codes text[] := '{}';
  settlements jsonb := '[]'::jsonb;
  balance_orders jsonb := '[]'::jsonb;
  saved jsonb;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Checkout payload must be an object'; end if;
  if jsonb_typeof(payload->'balances') <> 'array' or jsonb_array_length(payload->'balances') = 0 then
    raise exception 'At least one invoice balance is required';
  end if;
  if sale_payload is not null and jsonb_typeof(sale_payload) = 'null' then sale_payload := null; end if;
  if sale_payload is not null and jsonb_typeof(sale_payload) <> 'object' then
    raise exception 'The new sale must be an object';
  end if;

  shift_context := public.pos_open_shift_context(
    session_token, payload->>'store_code', payload->>'shift_id', payload->>'staff_name', true
  );
  store_id_value := nullif(shift_context->>'store_id', '')::bigint;

  if sale_payload is not null then
    sale_code := coalesce(trim(sale_payload->>'id'), '');
    if sale_code = '' then raise exception 'Order id is required'; end if;

    -- A retry after a dropped response must not take the balance twice. The
    -- sale and the balance payments commit together, so a saved sale means
    -- the balances were paid by the same request.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(sale_code, 0));
    select * into existing_sale
    from public.pos_sales_orders sales_order
    where sales_order.order_code = sale_code;
    if found then
      if existing_sale.store_id <> store_id_value then raise exception 'Order store cannot be changed'; end if;
      select coalesce(jsonb_agg(public.pos_sales_order_payload(paid)), '[]'::jsonb)
      into balance_orders
      from public.pos_sales_orders paid
      where paid.store_id = store_id_value
        and paid.order_code in (
          select settlement->>'order_id'
          from jsonb_array_elements(coalesce(existing_sale.order_payload->'balance_settlements', '[]'::jsonb)) settlement
        );
      return jsonb_build_object(
        'ok', true,
        'replayed', true,
        'order', public.pos_sales_order_payload(existing_sale),
        'balance_orders', balance_orders
      );
    end if;

    -- Payment is applied to the new items first, so anything short of the
    -- full amount stays owing on the earlier invoice, never on today's sale.
    sale_total := round(coalesce(nullif(sale_payload->>'total', '')::numeric, 0), 2);
    select round(coalesce(sum(coalesce(nullif(payment->>'amount', '')::numeric, 0)), 0), 2)
    into sale_paid from jsonb_array_elements(coalesce(sale_payload->'payments', '[]'::jsonb)) payment;
    if sale_paid < sale_total then
      raise exception 'The new items must be paid in full before paying toward an earlier invoice';
    end if;
  end if;

  for balance_entry in select value from jsonb_array_elements(payload->'balances') loop
    balance_code := coalesce(trim(balance_entry->>'order_id'), '');
    if balance_code = '' then raise exception 'Invoice id is required for every balance'; end if;
    if balance_code = any(seen_codes) or balance_code = sale_code then
      raise exception 'The same invoice is in the cart twice';
    end if;
    seen_codes := seen_codes || balance_code;

    select * into balance_order
    from public.pos_sales_orders sales_order
    where sales_order.order_code = balance_code
      and sales_order.store_id = store_id_value
    for update;
    if not found then raise exception 'Invoice % was not found in this store', balance_code; end if;

    -- The cart line was priced when it was added. A held cart, or a payment
    -- taken on another register since, makes that figure stale.
    balance_before := round(greatest(balance_order.total - balance_order.amount_paid, 0), 2);
    expected_balance := round(coalesce(nullif(balance_entry->>'expected_balance', '')::numeric, -1), 2);
    if expected_balance <> balance_before then
      raise exception 'Invoice #% now has % owing, not %. Remove it from the cart and add it again.',
        balance_order.invoice_number, balance_before, expected_balance;
    end if;

    select round(coalesce(sum(coalesce(nullif(payment->>'amount', '')::numeric, 0)), 0), 2)
    into allocated from jsonb_array_elements(coalesce(balance_entry->'payments', '[]'::jsonb)) payment;
    if allocated <= 0 then
      raise exception 'Invoice #% has no payment allocated', balance_order.invoice_number;
    end if;

    payment_result := public.add_pos_sales_order_payment_for_store(session_token, jsonb_build_object(
      'order_id', balance_code,
      'store_code', payload->>'store_code',
      'staff_name', payload->>'staff_name',
      'shift_id', payload->>'shift_id',
      'customer_code', coalesce(balance_entry->>'customer_code', ''),
      'payments', balance_entry->'payments'
    ));
    if not coalesce((payment_result->>'ok')::boolean, false) then
      raise exception '%', coalesce(payment_result->>'message', 'The balance payment could not be saved');
    end if;
    paid_order := payment_result->'order';
    balance_orders := balance_orders || jsonb_build_array(paid_order);
    settlements := settlements || jsonb_build_array(jsonb_build_object(
      'order_id', balance_code,
      'invoice_number', balance_order.invoice_number,
      'order_total', balance_order.total,
      'balance_before', balance_before,
      'amount', allocated,
      'balance_after', coalesce((paid_order->>'balance_due')::numeric, 0),
      'has_repair', coalesce(paid_order->>'sale_type', '') in ('repair', 'mixed'),
      'payments', coalesce((
        select jsonb_agg(jsonb_build_object(
          'method', coalesce(nullif(trim(payment->>'method'), ''), 'Unknown'),
          'amount', round(coalesce(nullif(payment->>'amount', '')::numeric, 0), 2)
        ))
        from jsonb_array_elements(balance_entry->'payments') payment
        where coalesce(nullif(payment->>'amount', '')::numeric, 0) > 0
      ), '[]'::jsonb)
    ));
  end loop;

  if sale_payload is null then
    return jsonb_build_object('ok', true, 'order', null, 'balance_orders', balance_orders);
  end if;

  saved := public.save_pos_sales_order_for_store(
    session_token,
    sale_payload || jsonb_build_object('balance_settlements', settlements)
  );
  if not coalesce((saved->>'ok')::boolean, false) then
    raise exception '%', coalesce(saved->>'message', 'The sale could not be saved');
  end if;
  return jsonb_build_object('ok', true, 'order', saved->'order', 'balance_orders', balance_orders);
end;
$$;

revoke all on function public.checkout_pos_cart_with_balances_for_store(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.checkout_pos_cart_with_balances_for_store(text, jsonb) to service_role;

comment on function public.checkout_pos_cart_with_balances_for_store(text, jsonb) is
  'Pays earlier invoice balances and saves the new cart items in one transaction; payment covers new items first.';
