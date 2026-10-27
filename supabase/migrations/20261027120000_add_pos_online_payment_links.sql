-- Online payment links.
--
-- Staff can finish a sale by emailing the customer a Stripe Checkout link
-- instead of taking the money at the counter. The sale is saved straight away
-- as an invoice with the link amount still owing (the same "deposit" state a
-- part payment leaves), so the till is free for the next customer. When Stripe
-- tells the website the customer has paid, the website calls this project and
-- the payment is recorded on that invoice as "Online Payment".
--
-- An online payment is not money in the till, so it carries no shift.
-- The Stripe side (session, email, webhook) lives in the website project,
-- which already holds the Stripe keys; see supabase/functions/pos-payment-link.

create table if not exists public.pos_payment_links (
  id bigint generated always as identity primary key,
  link_code text not null unique,
  sales_order_id bigint not null references public.pos_sales_orders(id),
  store_id bigint not null references public.store_locations(id),
  amount numeric(12,2) not null check (amount >= 0.50),
  customer_email text not null,
  customer_name text not null default '',
  staff_name text not null,
  -- pending: saved, Stripe not asked yet. sent: the customer has a live link.
  -- failed: Stripe or the email failed; send again from the invoice.
  -- replaced: a newer link for the same invoice took over. expired: Stripe closed it.
  -- paid: recorded on the invoice. paid_unapplied: paid, but the invoice had
  -- already been settled another way - it needs a refund in Stripe.
  status text not null default 'pending'
    check (status in ('pending', 'sent', 'failed', 'replaced', 'expired', 'paid', 'paid_unapplied')),
  stripe_checkout_session_id text unique,
  checkout_url text,
  expires_at timestamptz,
  email_sent_at timestamptz,
  send_error text,
  stripe_payment_intent_id text,
  paid_amount numeric(12,2),
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists pos_payment_links_order_idx on public.pos_payment_links (sales_order_id);
create index if not exists pos_payment_links_store_updated_idx on public.pos_payment_links (store_id, updated_at desc);

alter table public.pos_payment_links enable row level security;
revoke all on table public.pos_payment_links from public, anon, authenticated;
grant select, insert, update on table public.pos_payment_links to service_role;

drop trigger if exists pos_payment_links_set_updated_at on public.pos_payment_links;
create trigger pos_payment_links_set_updated_at
before update on public.pos_payment_links
for each row execute function public.set_updated_at();

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
    'expires_at', link_row.expires_at,
    'email_sent_at', link_row.email_sent_at,
    'send_error', link_row.send_error,
    'paid_amount', link_row.paid_amount,
    'paid_at', link_row.paid_at,
    'created_at', link_row.created_at,
    'updated_at', link_row.updated_at
  )
  from public.pos_sales_orders sales_order
  join public.store_locations store_location on store_location.id = sales_order.store_id
  where sales_order.id = link_row.sales_order_id;
$$;

-- Opens a link on an invoice the caller has already locked. Any older link
-- still open for the same invoice is replaced, and its Stripe session ids are
-- handed back so the website can close them: only one link can be paid.
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

  with replaced as (
    update public.pos_payment_links link
    set status = 'replaced'
    where link.sales_order_id = order_row.id
      and link.status in ('pending', 'sent', 'failed')
    returning link.stripe_checkout_session_id
  )
  select coalesce(jsonb_agg(stripe_checkout_session_id) filter (where stripe_checkout_session_id is not null), '[]'::jsonb)
  into replaced_sessions
  from replaced;

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

-- Checkout with the rest (or part) of the sale paid by link. Payments already
-- taken at the counter are saved as usual; the link amount stays owing.
create or replace function public.save_pos_sales_order_with_payment_link_for_store(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  shift_context jsonb;
  link_details jsonb := payload->'payment_link';
  total_value numeric(12,2);
  payment_total numeric(12,2);
  link_amount numeric(12,2);
  link_email text;
  order_code_value text := coalesce(trim(payload->>'id'), '');
  sanitized_payload jsonb;
  -- The order save needs a payment to exist. When nothing was taken at the
  -- counter, a 1c placeholder stands in and is removed again in this same
  -- transaction, so nobody ever sees it.
  needs_placeholder boolean;
  saved_order public.pos_sales_orders%rowtype;
  link_result jsonb;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Order payload must be a JSON object'; end if;
  if jsonb_typeof(link_details) <> 'object' then raise exception 'Payment link details are required'; end if;
  if jsonb_typeof(payload->'exchange_refund') = 'object' then
    raise exception 'An exchange cannot be paid by payment link';
  end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(payload->'items', '[]'::jsonb)) item
    where lower(coalesce(item->>'is_used_device', 'false')) = 'true'
  ) then raise exception 'Used devices must be paid in full before they leave the store'; end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(payload->'payments', '[]'::jsonb)) payment
    where lower(trim(payment->>'method')) in ('store credit', 'exchange credit', 'online payment')
  ) then raise exception 'Store Credit cannot be combined with a payment link'; end if;

  shift_context := public.pos_open_shift_context(
    session_token,
    coalesce(payload->>'store_db_code', payload->>'store_code', payload->>'store_id'),
    payload->>'shift_id', payload->>'staff_name', true
  );

  total_value := round(coalesce(nullif(payload->>'total', '')::numeric, 0), 2);
  select round(coalesce(sum(coalesce(nullif(payment->>'amount', '')::numeric, 0)), 0), 2)
  into payment_total from jsonb_array_elements(coalesce(payload->'payments', '[]'::jsonb)) payment;
  link_amount := round(coalesce(nullif(link_details->>'amount', '')::numeric, 0), 2);
  link_email := lower(btrim(coalesce(link_details->>'email', '')));

  if total_value <= 0 then raise exception 'There is nothing to pay online'; end if;
  if payment_total < 0 then raise exception 'Payment amount cannot be negative'; end if;
  if link_amount < 0.50 then raise exception 'An online payment must be at least $0.50'; end if;
  if payment_total + link_amount > total_value then
    raise exception 'The payment link is more than the balance due';
  end if;

  -- A retried save of the same sale returns what was saved; it never opens a second link.
  select * into saved_order from public.pos_sales_orders sales_order
  where sales_order.order_code = order_code_value;
  if found then
    if saved_order.store_id <> nullif(shift_context->>'store_id', '')::bigint then
      raise exception 'Order store cannot be changed';
    end if;
    return jsonb_build_object('ok', true, 'order', public.pos_sales_order_payload(saved_order), 'payment_link', null);
  end if;

  needs_placeholder := payment_total = 0;
  sanitized_payload := (payload - 'payment_link') || jsonb_build_object(
    'store_db_code', shift_context->>'store_code',
    'store_code', shift_context->>'store_code',
    'store_id', shift_context->>'store_code',
    'store_name', shift_context->>'store_name',
    'staff_name', shift_context->>'staff_name',
    'shift_id', shift_context->>'shift_id',
    'business_date', shift_context->>'business_date',
    'created_at', now(),
    'customer_email', coalesce(nullif(btrim(payload->>'customer_email'), ''), link_email),
    'payment_status', 'deposit',
    'close_repair_tickets', false,
    'payment_method', case when needs_placeholder then 'Online Payment' else payload->>'payment_method' end,
    'payments', case when needs_placeholder
      then jsonb_build_array(jsonb_build_object('method', 'Online Payment', 'amount', 0.01))
      else payload->'payments' end
  );

  perform public.save_pos_sales_order(session_token, sanitized_payload);

  select * into saved_order from public.pos_sales_orders sales_order
  where sales_order.order_code = order_code_value
  for update;
  if not found then raise exception 'The sale could not be saved'; end if;

  if needs_placeholder then
    delete from public.pos_sales_order_payments payment where payment.sales_order_id = saved_order.id;
    update public.pos_sales_orders
    set amount_paid = 0,
        payment_status = 'deposit',
        order_payload = order_payload || jsonb_build_object(
          'payments', '[]'::jsonb, 'amount_paid', 0, 'payment_status', 'deposit'
        )
    where id = saved_order.id
    returning * into saved_order;
  end if;

  link_result := public.pos_open_payment_link(saved_order, link_email, link_amount, shift_context->>'staff_name');
  return jsonb_build_object(
    'ok', true,
    'order', public.pos_sales_order_payload(saved_order),
    'payment_link', link_result
  );
end;
$$;

-- A new link for an invoice that already exists: a balance owing, a link that
-- expired, or one the customer never received.
create or replace function public.create_pos_payment_link_for_store(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  shift_context jsonb;
  saved_order public.pos_sales_orders%rowtype;
  order_code_value text := coalesce(trim(payload->>'order_id'), '');
  link_email text := lower(btrim(coalesce(payload->>'email', '')));
  link_result jsonb;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Payment link payload must be an object'; end if;
  shift_context := public.pos_open_shift_context(
    session_token, payload->>'store_code', payload->>'shift_id', payload->>'staff_name', true
  );
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(order_code_value, 0));
  select * into saved_order
  from public.pos_sales_orders sales_order
  where sales_order.order_code = order_code_value
    and sales_order.store_id = nullif(shift_context->>'store_id', '')::bigint
  for update;
  if not found then raise exception 'Invoice not found in the current store'; end if;

  link_result := public.pos_open_payment_link(
    saved_order, link_email, nullif(payload->>'amount', '')::numeric, shift_context->>'staff_name'
  );
  if coalesce(btrim(saved_order.customer_email), '') = '' then
    update public.pos_sales_orders set customer_email = link_email
    where id = saved_order.id
    returning * into saved_order;
  end if;
  return jsonb_build_object('ok', true, 'order', public.pos_sales_order_payload(saved_order), 'payment_link', link_result);
end;
$$;

-- Server only: the website's answer after it asked Stripe for the session and emailed it.
create or replace function public.attach_pos_payment_link(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved_link public.pos_payment_links%rowtype;
  session_id text := nullif(btrim(coalesce(payload->>'stripe_checkout_session_id', '')), '');
begin
  update public.pos_payment_links link
  set stripe_checkout_session_id = coalesce(session_id, link.stripe_checkout_session_id),
      checkout_url = coalesce(nullif(payload->>'checkout_url', ''), link.checkout_url),
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
  balance_due numeric(12,2);
  new_amount_paid numeric(12,2);
  new_status text;
  last_payment_number integer;
  paid_at_value timestamptz := now();
begin
  select * into saved_link from public.pos_payment_links link
  where link.link_code = coalesce(payload->>'link_code', '')
  for update;
  if not found then raise exception 'Payment link not found'; end if;
  if session_id = '' or session_id is distinct from saved_link.stripe_checkout_session_id then
    raise exception 'Stripe session does not belong to this payment link';
  end if;

  select * into saved_order from public.pos_sales_orders sales_order
  where sales_order.id = saved_link.sales_order_id;

  if saved_link.status in ('paid', 'paid_unapplied') then
    return jsonb_build_object('ok', true, 'already_recorded', true, 'applied', saved_link.status = 'paid',
      'payment_link', public.pos_payment_link_payload(saved_link),
      'order', public.pos_sales_order_payload(saved_order));
  end if;
  if paid_value <> saved_link.amount then raise exception 'Paid amount does not match the payment link'; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(saved_order.order_code, 0));
  select * into saved_order from public.pos_sales_orders sales_order
  where sales_order.id = saved_link.sales_order_id
  for update;

  balance_due := round(greatest(saved_order.total - saved_order.amount_paid, 0), 2);
  if paid_value > balance_due then
    -- Settled at the counter (or by another link) before the customer paid.
    update public.pos_payment_links
    set status = 'paid_unapplied', paid_amount = paid_value, paid_at = paid_at_value,
        stripe_payment_intent_id = nullif(payload->>'stripe_payment_intent_id', '')
    where id = saved_link.id
    returning * into saved_link;
    return jsonb_build_object('ok', true, 'already_recorded', false, 'applied', false,
      'payment_link', public.pos_payment_link_payload(saved_link),
      'order', public.pos_sales_order_payload(saved_order));
  end if;

  select coalesce(max(payment.payment_number), 0) into last_payment_number
  from public.pos_sales_order_payments payment
  where payment.sales_order_id = saved_order.id;

  insert into public.pos_sales_order_payments (
    sales_order_id, payment_number, method, amount,
    shift_id, staff_name, business_date, taken_at, created_at
  ) values (
    saved_order.id, last_payment_number + 1, 'Online Payment', paid_value,
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
  set status = 'paid', paid_amount = paid_value, paid_at = paid_at_value,
      stripe_payment_intent_id = nullif(payload->>'stripe_payment_intent_id', '')
  where id = saved_link.id
  returning * into saved_link;

  return jsonb_build_object('ok', true, 'already_recorded', false, 'applied', true,
    'payment_link', public.pos_payment_link_payload(saved_link),
    'order', public.pos_sales_order_payload(saved_order));
end;
$$;

-- Server only: Stripe closed the session without a payment.
create or replace function public.expire_pos_payment_link(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.pos_payment_links link
  set status = 'expired'
  where link.stripe_checkout_session_id = coalesce(payload->>'stripe_checkout_session_id', '')
    and link.status in ('pending', 'sent', 'failed');
  return jsonb_build_object('ok', true);
end;
$$;

-- What the till shows: links for one invoice, or everything that changed lately.
create or replace function public.list_pos_payment_links_for_store(
  session_token text,
  target_store_code text,
  target_order_code text default null,
  changed_since timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  access jsonb;
begin
  access := public.verify_staff_store_access(session_token, target_store_code);
  if not coalesce((access->>'allowed')::boolean, false) then
    raise exception '%', coalesce(access->>'message', 'Store access denied');
  end if;
  return jsonb_build_object('ok', true, 'payment_links', coalesce((
    select jsonb_agg(public.pos_payment_link_payload(recent.link_row) order by (recent.link_row).updated_at desc)
    from (
      select link as link_row
      from public.pos_payment_links link
      join public.pos_sales_orders sales_order on sales_order.id = link.sales_order_id
      join public.store_locations store_location on store_location.id = link.store_id
      where store_location.store_code = lower(btrim(coalesce(target_store_code, '')))
        and (nullif(btrim(coalesce(target_order_code, '')), '') is null or sales_order.order_code = btrim(target_order_code))
        and link.updated_at >= coalesce(changed_since, now() - interval '2 days')
      order by link.updated_at desc
      limit 100
    ) recent
  ), '[]'::jsonb));
end;
$$;

revoke all on function public.pos_payment_link_payload(public.pos_payment_links) from public, anon, authenticated;
revoke all on function public.pos_open_payment_link(public.pos_sales_orders, text, numeric, text) from public, anon, authenticated;
revoke all on function public.save_pos_sales_order_with_payment_link_for_store(text, jsonb) from public, anon, authenticated;
revoke all on function public.create_pos_payment_link_for_store(text, jsonb) from public, anon, authenticated;
revoke all on function public.attach_pos_payment_link(jsonb) from public, anon, authenticated;
revoke all on function public.complete_pos_payment_link(jsonb) from public, anon, authenticated;
revoke all on function public.expire_pos_payment_link(jsonb) from public, anon, authenticated;
revoke all on function public.list_pos_payment_links_for_store(text, text, text, timestamptz) from public, anon, authenticated;

grant execute on function public.save_pos_sales_order_with_payment_link_for_store(text, jsonb) to service_role;
grant execute on function public.create_pos_payment_link_for_store(text, jsonb) to service_role;
grant execute on function public.attach_pos_payment_link(jsonb) to service_role;
grant execute on function public.complete_pos_payment_link(jsonb) to service_role;
grant execute on function public.expire_pos_payment_link(jsonb) to service_role;
grant execute on function public.list_pos_payment_links_for_store(text, text, text, timestamptz) to service_role;
