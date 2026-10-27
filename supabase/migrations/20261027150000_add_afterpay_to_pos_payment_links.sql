-- Afterpay on POS payment links.
--
-- The customer's email now offers two buttons: card for the invoice amount,
-- and Afterpay for the invoice amount plus the Afterpay processing fee (the
-- website's fee profile, 6% + $0.30 today). Each button is its own Stripe
-- Checkout session; paying one closes the other.
--
-- The fee is part of the sale: when Afterpay is paid, an "Afterpay processing
-- fee" line is added to the invoice, the invoice total grows by the fee and the
-- whole amount is recorded as one "Online Afterpay" payment.

alter table public.pos_payment_links
  add column if not exists afterpay_session_id text unique,
  add column if not exists afterpay_checkout_url text,
  add column if not exists afterpay_fee numeric(12,2) check (afterpay_fee is null or afterpay_fee >= 0),
  add column if not exists paid_method text;

create or replace function public.pos_payment_link_payload(link_row public.pos_payment_links)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'link_code', link_row.link_code,
    'order_id', sales_order.order_code,
    'invoice_number', sales_order.invoice_number,
    'store_code', store_location.store_code,
    'store_name', store_location.store_name,
    'amount', link_row.amount,
    'customer_email', link_row.customer_email,
    'customer_name', link_row.customer_name,
    'staff_name', link_row.staff_name,
    'status', link_row.status,
    'checkout_url', link_row.checkout_url,
    'afterpay_checkout_url', link_row.afterpay_checkout_url,
    'afterpay_fee', link_row.afterpay_fee,
    'expires_at', link_row.expires_at,
    'email_sent_at', link_row.email_sent_at,
    'send_error', link_row.send_error,
    'paid_method', link_row.paid_method,
    'paid_amount', link_row.paid_amount,
    'paid_at', link_row.paid_at,
    'created_at', link_row.created_at,
    'updated_at', link_row.updated_at
  )
  from public.pos_sales_orders sales_order
  join public.store_locations store_location on store_location.id = sales_order.store_id
  where sales_order.id = link_row.sales_order_id;
$$;

create or replace function public.pos_open_payment_link(
  order_row public.pos_sales_orders,
  recipient_email text,
  link_amount numeric,
  sender_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  email_value text := lower(btrim(coalesce(recipient_email, '')));
  amount_value numeric(12,2) := round(coalesce(link_amount, 0), 2);
  balance_due numeric(12,2) := round(greatest(order_row.total - order_row.amount_paid, 0), 2);
  replaced_sessions jsonb;
  saved_link public.pos_payment_links%rowtype;
begin
  if email_value !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' or length(email_value) > 254 then
    raise exception 'A valid customer email is required for a payment link';
  end if;
  if balance_due <= 0 then raise exception 'This invoice is already fully paid'; end if;
  if amount_value < 0.50 then raise exception 'An online payment must be at least $0.50'; end if;
  if amount_value > balance_due then raise exception 'The payment link is more than the balance due'; end if;

  -- Both buttons of every older open link must stop working.
  with replaced as (
    update public.pos_payment_links link
    set status = 'replaced'
    where link.sales_order_id = order_row.id
      and link.status in ('pending', 'sent', 'failed')
    returning link.stripe_checkout_session_id, link.afterpay_session_id
  )
  select coalesce(jsonb_agg(session_id) filter (where session_id is not null), '[]'::jsonb)
  into replaced_sessions
  from replaced
  cross join lateral (values (replaced.stripe_checkout_session_id), (replaced.afterpay_session_id)) sessions(session_id);

  insert into public.pos_payment_links (
    link_code, sales_order_id, store_id, amount, customer_email, customer_name, staff_name
  ) values (
    'PL-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
    order_row.id,
    order_row.store_id,
    amount_value,
    email_value,
    coalesce(order_row.customer_name, ''),
    sender_name
  ) returning * into saved_link;

  return public.pos_payment_link_payload(saved_link)
    || jsonb_build_object('replaced_session_ids', replaced_sessions);
end;
$$;

create or replace function public.attach_pos_payment_link(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved_link public.pos_payment_links%rowtype;
  session_id text := nullif(btrim(coalesce(payload->>'stripe_checkout_session_id', '')), '');
  afterpay_id text := nullif(btrim(coalesce(payload->>'afterpay_session_id', '')), '');
  fee_value numeric(12,2) := round(nullif(payload->>'afterpay_fee', '')::numeric, 2);
begin
  if afterpay_id is not null and (fee_value is null or fee_value < 0) then
    raise exception 'Afterpay fee is required for an Afterpay session';
  end if;
  update public.pos_payment_links link
  set stripe_checkout_session_id = coalesce(session_id, link.stripe_checkout_session_id),
      checkout_url = coalesce(nullif(payload->>'checkout_url', ''), link.checkout_url),
      afterpay_session_id = coalesce(afterpay_id, link.afterpay_session_id),
      afterpay_checkout_url = coalesce(nullif(payload->>'afterpay_checkout_url', ''), link.afterpay_checkout_url),
      afterpay_fee = case when afterpay_id is not null then fee_value else link.afterpay_fee end,
      expires_at = coalesce(nullif(payload->>'expires_at', '')::timestamptz, link.expires_at),
      email_sent_at = case when coalesce((payload->>'email_sent')::boolean, false) then now() else link.email_sent_at end,
      send_error = nullif(left(coalesce(payload->>'send_error', ''), 500), ''),
      status = case when link.status <> 'pending' then link.status
        when session_id is null then 'failed' else 'sent' end
  where link.link_code = coalesce(payload->>'link_code', '')
  returning * into saved_link;
  if not found then raise exception 'Payment link not found'; end if;
  return jsonb_build_object('ok', true, 'payment_link', public.pos_payment_link_payload(saved_link));
end;
$$;

-- Server only: Stripe says the customer paid. Safe to call more than once.
create or replace function public.complete_pos_payment_link(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved_link public.pos_payment_links%rowtype;
  saved_order public.pos_sales_orders%rowtype;
  paid_value numeric(12,2) := round(coalesce(nullif(payload->>'amount', '')::numeric, -1), 2);
  session_id text := coalesce(btrim(payload->>'stripe_checkout_session_id'), '');
  by_afterpay boolean;
  fee_value numeric(12,2) := 0;
  method_value text;
  other_session text;
  balance_due numeric(12,2);
  new_amount_paid numeric(12,2);
  new_status text;
  last_payment_number integer;
  last_line_number integer;
  paid_at_value timestamptz := now();
begin
  select * into saved_link from public.pos_payment_links link
  where link.link_code = coalesce(payload->>'link_code', '')
  for update;
  if not found then raise exception 'Payment link not found'; end if;
  if session_id = '' or session_id not in (
    coalesce(saved_link.stripe_checkout_session_id, ''), coalesce(saved_link.afterpay_session_id, '')
  ) then
    raise exception 'Stripe session does not belong to this payment link';
  end if;
  by_afterpay := session_id = saved_link.afterpay_session_id;
  other_session := case when by_afterpay then saved_link.stripe_checkout_session_id else saved_link.afterpay_session_id end;

  select * into saved_order from public.pos_sales_orders sales_order
  where sales_order.id = saved_link.sales_order_id;

  if saved_link.status in ('paid', 'paid_unapplied') then
    return jsonb_build_object('ok', true, 'already_recorded', true, 'applied', saved_link.status = 'paid',
      'other_session_id', other_session,
      'payment_link', public.pos_payment_link_payload(saved_link),
      'order', public.pos_sales_order_payload(saved_order));
  end if;

  if by_afterpay then
    fee_value := coalesce(saved_link.afterpay_fee, 0);
    method_value := 'Online Afterpay';
  else
    method_value := 'Online Payment';
  end if;
  if paid_value <> saved_link.amount + fee_value then
    raise exception 'Paid amount does not match the payment link';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(saved_order.order_code, 0));
  select * into saved_order from public.pos_sales_orders sales_order
  where sales_order.id = saved_link.sales_order_id
  for update;

  balance_due := round(greatest(saved_order.total - saved_order.amount_paid, 0), 2);
  if saved_link.amount > balance_due then
    -- Settled at the counter (or by another link) before the customer paid.
    update public.pos_payment_links
    set status = 'paid_unapplied', paid_method = method_value, paid_amount = paid_value, paid_at = paid_at_value,
        stripe_payment_intent_id = nullif(payload->>'stripe_payment_intent_id', '')
    where id = saved_link.id
    returning * into saved_link;
    return jsonb_build_object('ok', true, 'already_recorded', false, 'applied', false,
      'other_session_id', other_session,
      'payment_link', public.pos_payment_link_payload(saved_link),
      'order', public.pos_sales_order_payload(saved_order));
  end if;

  -- The Afterpay fee is part of the sale: a line on the invoice, in its total.
  if fee_value > 0 then
    select coalesce(max(line.line_number), 0) into last_line_number
    from public.pos_sales_order_lines line
    where line.sales_order_id = saved_order.id;
    insert into public.pos_sales_order_lines (
      sales_order_id, line_number, line_type, product_id, sku, name, category,
      quantity, unit_price, line_total, line_payload, created_at
    ) values (
      saved_order.id, last_line_number + 1, 'special', 'special-afterpay-fee', 'AFTERPAY-FEE',
      'Afterpay processing fee', 'Payment Fees', 1, fee_value, fee_value,
      jsonb_build_object('is_special', true, 'payment_fee', true, 'payment_link', saved_link.link_code),
      paid_at_value
    );
    update public.pos_sales_orders
    set total = round(total + fee_value, 2),
        order_payload = order_payload || jsonb_build_object('total', round(total + fee_value, 2))
    where id = saved_order.id
    returning * into saved_order;
  end if;

  select coalesce(max(payment.payment_number), 0) into last_payment_number
  from public.pos_sales_order_payments payment
  where payment.sales_order_id = saved_order.id;

  insert into public.pos_sales_order_payments (
    sales_order_id, payment_number, method, amount,
    shift_id, staff_name, business_date, taken_at, created_at
  ) values (
    saved_order.id, last_payment_number + 1, method_value, paid_value,
    null, saved_link.staff_name, (paid_at_value at time zone 'Australia/Brisbane')::date,
    paid_at_value, paid_at_value
  );

  new_amount_paid := round(saved_order.amount_paid + paid_value, 2);
  new_status := case when new_amount_paid >= saved_order.total then 'paid' else 'deposit' end;
  update public.pos_sales_orders
  set amount_paid = new_amount_paid,
      payment_status = new_status,
      payment_method = (
        select string_agg(distinct payment.method, ' + ' order by payment.method)
        from public.pos_sales_order_payments payment
        where payment.sales_order_id = saved_order.id
      )
  where id = saved_order.id
  returning * into saved_order;

  if new_status = 'paid' then
    perform public.close_pos_repair_tickets_for_order(
      saved_order.id, saved_link.staff_name, saved_order.invoice_number,
      saved_order.customer_name, saved_order.customer_phone
    );
  end if;

  update public.pos_payment_links
  set status = 'paid', paid_method = method_value, paid_amount = paid_value, paid_at = paid_at_value,
      stripe_payment_intent_id = nullif(payload->>'stripe_payment_intent_id', '')
  where id = saved_link.id
  returning * into saved_link;

  return jsonb_build_object('ok', true, 'already_recorded', false, 'applied', true,
    'other_session_id', other_session,
    'payment_link', public.pos_payment_link_payload(saved_link),
    'order', public.pos_sales_order_payload(saved_order));
end;
$$;

-- Server only: Stripe closed a session without a payment. Both buttons share
-- one expiry, so either one closing ends the link.
create or replace function public.expire_pos_payment_link(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_id text := coalesce(payload->>'stripe_checkout_session_id', '');
begin
  update public.pos_payment_links link
  set status = 'expired'
  where session_id <> ''
    and session_id in (coalesce(link.stripe_checkout_session_id, ''), coalesce(link.afterpay_session_id, ''))
    and link.status in ('pending', 'sent', 'failed')
    and coalesce(link.expires_at, now()) <= now() + interval '5 minutes';
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.pos_payment_link_payload(public.pos_payment_links) from public, anon, authenticated;
revoke all on function public.pos_open_payment_link(public.pos_sales_orders, text, numeric, text) from public, anon, authenticated;
revoke all on function public.attach_pos_payment_link(jsonb) from public, anon, authenticated;
revoke all on function public.complete_pos_payment_link(jsonb) from public, anon, authenticated;
revoke all on function public.expire_pos_payment_link(jsonb) from public, anon, authenticated;
grant execute on function public.attach_pos_payment_link(jsonb) to service_role;
grant execute on function public.complete_pos_payment_link(jsonb) to service_role;
grant execute on function public.expire_pos_payment_link(jsonb) to service_role;
