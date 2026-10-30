-- Paid-link notices for the till.
--
-- When a customer pays a link, every till of that store shows a notice
-- (invoice, customer, deposit or paid in full, what is still owing) until a
-- staff member there presses "Got it". The acknowledgement is stored here so
-- the notice clears on every till at once, and a till opened after the
-- payment still shows it.

alter table public.pos_payment_links
  add column if not exists acknowledged_at timestamptz,
  add column if not exists acknowledged_by text;

-- Payments taken before notices existed were already announced by the old toast.
update public.pos_payment_links
set acknowledged_at = now(), acknowledged_by = 'before payment notices'
where status in ('paid', 'paid_unapplied') and acknowledged_at is null;

create index if not exists pos_payment_links_unacknowledged_idx
  on public.pos_payment_links (store_id, paid_at desc)
  where status in ('paid', 'paid_unapplied') and acknowledged_at is null;

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
    'customer_phone', sales_order.customer_phone,
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
    'acknowledged_at', link_row.acknowledged_at,
    'acknowledged_by', link_row.acknowledged_by,
    'order_total', sales_order.total,
    'order_amount_paid', sales_order.amount_paid,
    'order_balance_due', round(greatest(sales_order.total - sales_order.amount_paid, 0), 2),
    'order_items', coalesce((
      select string_agg(
        case when line.quantity > 1 then line.quantity || ' x ' || line.name else line.name end,
        ', ' order by line.line_number)
      from public.pos_sales_order_lines line
      where line.sales_order_id = sales_order.id
    ), ''),
    'created_at', link_row.created_at,
    'updated_at', link_row.updated_at
  )
  from public.pos_sales_orders sales_order
  join public.store_locations store_location on store_location.id = sales_order.store_id
  where sales_order.id = link_row.sales_order_id;
$$;

drop function if exists public.list_pos_payment_links_for_store(text, text, text, timestamptz);

-- What the till shows: links for one invoice, everything that changed lately,
-- or (unacknowledged_only) the paid links nobody at the store has seen yet.
create or replace function public.list_pos_payment_links_for_store(
  session_token text,
  target_store_code text,
  target_order_code text default null,
  changed_since timestamptz default null,
  unacknowledged_only boolean default false
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
        and (
          case when coalesce(unacknowledged_only, false)
            then link.status in ('paid', 'paid_unapplied')
              and link.acknowledged_at is null
              and link.paid_at >= now() - interval '14 days'
            else link.updated_at >= coalesce(changed_since, now() - interval '2 days')
          end
        )
      order by link.updated_at desc
      limit 100
    ) recent
  ), '[]'::jsonb));
end;
$$;

-- A staff member at the store has seen the payment notice.
create or replace function public.acknowledge_pos_payment_link_for_store(
  session_token text,
  target_store_code text,
  target_link_code text,
  target_staff_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  access jsonb;
  saved_link public.pos_payment_links%rowtype;
begin
  access := public.verify_staff_store_access(session_token, target_store_code);
  if not coalesce((access->>'allowed')::boolean, false) then
    raise exception '%', coalesce(access->>'message', 'Store access denied');
  end if;
  update public.pos_payment_links link
  set acknowledged_at = coalesce(link.acknowledged_at, now()),
      acknowledged_by = coalesce(link.acknowledged_by, nullif(left(btrim(coalesce(target_staff_name, '')), 120), ''))
  from public.store_locations store_location
  where link.link_code = coalesce(target_link_code, '')
    and store_location.id = link.store_id
    and store_location.store_code = lower(btrim(coalesce(target_store_code, '')))
    and link.status in ('paid', 'paid_unapplied')
  returning link.* into saved_link;
  if saved_link.id is null then raise exception 'Payment notice not found in this store'; end if;
  return jsonb_build_object('ok', true, 'payment_link', public.pos_payment_link_payload(saved_link));
end;
$$;

revoke all on function public.pos_payment_link_payload(public.pos_payment_links) from public, anon, authenticated;
revoke all on function public.list_pos_payment_links_for_store(text, text, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.acknowledge_pos_payment_link_for_store(text, text, text, text) from public, anon, authenticated;
grant execute on function public.list_pos_payment_links_for_store(text, text, text, timestamptz, boolean) to service_role;
grant execute on function public.acknowledge_pos_payment_link_for_store(text, text, text, text) to service_role;
