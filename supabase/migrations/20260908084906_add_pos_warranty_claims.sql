-- Warranty eligibility is derived from saved invoice lines for both historical and future orders.
-- Claims are append-only; they never create sales, refunds, or inventory movements.
create table public.pos_warranty_claims (
  id uuid primary key,
  sales_order_line_id bigint not null references public.pos_sales_order_lines(id),
  staff_id bigint not null references public.staff_directory(id),
  staff_name text not null,
  claimed_at timestamptz not null default clock_timestamp()
);
create index pos_warranty_claims_line_idx on public.pos_warranty_claims(sales_order_line_id, claimed_at);
alter table public.pos_warranty_claims enable row level security;
revoke all on public.pos_warranty_claims from public, anon, authenticated;
grant select, insert on public.pos_warranty_claims to service_role;

create or replace function public.pos_line_warranty(sales_line public.pos_sales_order_lines, purchase_date date)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  p jsonb := sales_line.line_payload;
  title text := coalesce(sales_line.name, '');
  duration text := coalesce(nullif(trim(p->>'warranty_duration'), ''), nullif(trim(p->>'source_warranty_duration'), ''), '');
  end_text text := coalesce(nullif(trim(p->>'warranty_end_date'), ''), nullif(trim(p->>'source_warranty_end_date'), ''), '');
  start_text text := coalesce(nullif(trim(p->>'warranty_start_date'), ''), nullif(trim(p->>'source_warranty_start_date'), ''), '');
  starts date := purchase_date;
  ends date;
  term text[];
  one_time boolean := title ~* '(one[ -]?time|once|1[ -]?time).*free replacement';
  eligible boolean := false;
  history jsonb;
  used_count integer;
  returned integer;
  remaining integer;
  reason text := '';
begin
  if title ~* 'free replacement|warranty' then
    term := regexp_match(title, '([0-9]+)[[:space:]]*(day|month|year)s?', 'i');
  end if;
  if term is not null then duration := term[1] || ' ' || term[2] || 's'; end if;
  if duration = '' and not sales_line.legacy_import and sales_line.line_type in ('retail', 'repair')
    and title !~* 'gift[ -]?card|voucher|deposit|discount|warranty replacement' then
    duration := '6 Months';
  end if;
  if lower(trim(duration)) in ('-', 'n/a', 'none', 'no warranty', '0', '0 months', '0 days', '0 years') then
    duration := '';
    end_text := '';
  else
    eligible := duration <> '' or end_text not in ('', '-', 'N/A')
      or title ~* 'free replacement|warranty';
  end if;
  if title ~* 'no warranty|without warranty|^[0-9.[:space:]]*warranty replacement[[:space:]]*$' then eligible := false; end if;
  begin
    if start_text ~ '^\d{4}-\d{2}-\d{2}$' or start_text ~ '^[A-Za-z]{3} [0-9]{1,2}, [0-9]{4}$' then starts := start_text::date; end if;
  exception when others then starts := purchase_date;
  end;
  -- A specific promise in the item name (e.g. 12-month free replacement) takes precedence over generic import dates.
  if term is null then
    begin
      if end_text ~ '^\d{4}-\d{2}-\d{2}$' or end_text ~ '^[A-Za-z]{3} [0-9]{1,2}, [0-9]{4}$' then ends := end_text::date; end if;
    exception when others then ends := null;
    end;
  end if;
  if ends is null then
    term := regexp_match(duration, '^([0-9]+)[[:space:]]*(day|month|year)s?$', 'i');
    if term is not null then
      if term[1]::integer = 0 then eligible := false;
      elsif term[1]::integer <= 36500 then ends := (starts + (term[1] || ' ' || term[2])::interval)::date;
      end if;
    end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'claimed_at', c.claimed_at, 'staff_name', c.staff_name)
    order by c.claimed_at desc), '[]'::jsonb), count(*)::integer into history, used_count
    from public.pos_warranty_claims c where c.sales_order_line_id = sales_line.id;
  select coalesce(sum(r.returned_quantity), 0)::integer into returned
    from public.pos_sales_refund_lines r where r.sales_order_line_id = sales_line.id;
  remaining := greatest(sales_line.quantity - returned - used_count, 0);
  if not eligible then reason := 'No warranty recorded';
  elsif sales_line.quantity <= returned or sales_line.line_total < 0 then reason := 'Returned / credit item';
  elsif starts > (current_timestamp at time zone 'Australia/Brisbane')::date then reason := 'Warranty has not started';
  elsif ends < (current_timestamp at time zone 'Australia/Brisbane')::date then reason := 'Warranty expired';
  elsif one_time and remaining = 0 then reason := 'Free replacement claimed';
  end if;
  return jsonb_build_object('eligible', eligible, 'duration', duration, 'starts_on', starts,
    'expires_on', ends, 'one_time', one_time, 'remaining', case when one_time then remaining else null end,
    'can_claim', eligible and reason = '', 'reason', reason, 'claims', history);
end;
$$;
revoke all on function public.pos_line_warranty(public.pos_sales_order_lines, date) from public, anon, authenticated;
grant execute on function public.pos_line_warranty(public.pos_sales_order_lines, date) to service_role;

CREATE OR REPLACE FUNCTION public.pos_sales_order_payload(order_row pos_sales_orders)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with line_rows as (
    select
      coalesce(
        jsonb_agg(
          sales_line.line_payload || jsonb_build_object(
            'line_id', sales_line.id,
            'warranty', public.pos_line_warranty(sales_line, order_row.business_date),
            'line_number', sales_line.line_number,
            'line_type', sales_line.line_type,
            'product_id', sales_line.product_id,
            'ticket_id', repair_ticket.ticket_code,
            'sku', sales_line.sku,
            'name', sales_line.name,
            'category', sales_line.category,
            'qty', sales_line.quantity,
            'unit_price', sales_line.unit_price,
            'sale_price', sales_line.unit_price,
            'line_total', sales_line.line_total,
            'refunded_amount', coalesce(refunded.amount, 0),
            'refunded_quantity', coalesce(refunded.returned_quantity, 0),
            'refundable_amount', greatest(sales_line.line_total - coalesce(refunded.amount, 0), 0),
            'refundable_quantity', greatest(sales_line.quantity - coalesce(refunded.returned_quantity, 0), 0)
          )
          order by sales_line.line_number
        ),
        '[]'::jsonb
      ) as items,
      bool_or(sales_line.line_type = 'repair') as has_repair,
      bool_or(sales_line.line_type <> 'repair') as has_non_repair
    from public.pos_sales_order_lines sales_line
    left join public.pos_repair_tickets repair_ticket on repair_ticket.id = sales_line.repair_ticket_id
    left join lateral (
      select
        coalesce(sum(refund_line.amount), 0) as amount,
        coalesce(sum(refund_line.returned_quantity), 0) as returned_quantity
      from public.pos_sales_refund_lines refund_line
      where refund_line.sales_order_line_id = sales_line.id
    ) refunded on true
    where sales_line.sales_order_id = order_row.id
  ),
  payment_rows as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'method', payment.method,
          'amount', payment.amount,
          'staff_name', payment.staff_name,
          'shift_id', payment.shift_id,
          'business_date', payment.business_date,
          'taken_at', coalesce(payment.taken_at, payment.created_at)
        ) order by payment.payment_number
      ),
      '[]'::jsonb
    ) as payments
    from public.pos_sales_order_payments payment
    where payment.sales_order_id = order_row.id
  ),
  refund_rows as (
    select
      coalesce(sum(refund.amount), 0) as refund_total,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', refund.refund_code,
            'staff_name', refund.staff_name,
            'method', refund.method,
            'reason', refund.reason,
            'amount', refund.amount,
            'shift_id', refund.shift_id,
            'business_date', refund.business_date,
            'created_at', refund.created_at
          ) order by refund.created_at desc
        ) filter (where refund.id is not null),
        '[]'::jsonb
      ) as refunds
    from public.pos_sales_refunds refund
    where refund.sales_order_id = order_row.id
  )
  select order_row.order_payload || jsonb_build_object(
    'id', order_row.order_code,
    'invoice_number', order_row.invoice_number,
    'store_db_code', store_location.store_code,
    'store_name', store_location.store_name,
    'business_date', order_row.business_date,
    'staff_name', order_row.staff_name,
    'shift_id', order_row.shift_id,
    'customer_name', order_row.customer_name,
    'customer_phone', order_row.customer_phone,
    'customer_email', order_row.customer_email,
    'payment_method', order_row.payment_method,
    'payments', payment_rows.payments,
    'items', line_rows.items,
    'sale_type', case
      when coalesce(line_rows.has_repair, false) and coalesce(line_rows.has_non_repair, false) then 'mixed'
      when coalesce(line_rows.has_repair, false) then 'repair'
      else 'retail'
    end,
    'total', order_row.total,
    'payment_status', order_row.payment_status,
    'amount_paid', order_row.amount_paid,
    'balance_due', round(greatest(order_row.total - order_row.amount_paid, 0), 2),
    'refund_total', refund_rows.refund_total,
    'refundable_total', greatest(least(order_row.total, order_row.amount_paid) - refund_rows.refund_total, 0),
    'refund_status', case
      when refund_rows.refund_total <= 0 then 'paid'
      when refund_rows.refund_total < least(order_row.total, order_row.amount_paid) then 'partially_refunded'
      else 'refunded'
    end,
    'refunds', refund_rows.refunds,
    'receipt_email_count', order_row.receipt_email_count,
    'last_receipt_email', order_row.last_receipt_email,
    'receipt_emailed_at', order_row.receipt_emailed_at,
    'created_at', order_row.created_at,
    'database_saved_at', order_row.updated_at,
    'sync_pending', false
  )
  from public.store_locations store_location
  cross join line_rows
  cross join payment_rows
  cross join refund_rows
  where store_location.id = order_row.store_id;
$function$;


create or replace function public.claim_pos_warranty_for_store(
  session_token text, target_store_code text, target_order_code text, target_line_id bigint, request_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  access_result jsonb;
  selected_order public.pos_sales_orders%rowtype;
  selected_line public.pos_sales_order_lines%rowtype;
  existing_claim public.pos_warranty_claims%rowtype;
  warranty jsonb;
begin
  access_result := public.verify_staff_store_access(session_token, target_store_code);
  if not coalesce((access_result->>'ok')::boolean, false) or not coalesce((access_result->>'allowed')::boolean, false) then
    raise exception '%', coalesce(access_result->>'message', 'Store access denied');
  end if;
  if request_id is null then raise exception 'Claim request id is required'; end if;
  -- Lock the order first, matching payment/refund serialization, then the exact invoice line.
  select o.* into selected_order from public.pos_sales_orders o
    join public.store_locations s on s.id = o.store_id
    where o.order_code = trim(target_order_code) and s.store_code = lower(trim(target_store_code))
    for update of o;
  if not found then raise exception 'Invoice not found in the current store'; end if;
  select * into selected_line from public.pos_sales_order_lines l
    where l.id = target_line_id and l.sales_order_id = selected_order.id for update;
  if not found then raise exception 'Invoice item not found'; end if;
  select * into existing_claim from public.pos_warranty_claims where id = request_id;
  if found then
    if existing_claim.sales_order_line_id <> selected_line.id then raise exception 'Claim request already used'; end if;
    return jsonb_build_object('ok', true, 'order', public.pos_sales_order_payload(selected_order));
  end if;
  warranty := public.pos_line_warranty(selected_line, selected_order.business_date);
  if not coalesce((warranty->>'can_claim')::boolean, false) then
    raise exception '%', coalesce(warranty->>'reason', 'Warranty cannot be claimed');
  end if;
  insert into public.pos_warranty_claims(id, sales_order_line_id, staff_id, staff_name)
    values(request_id, selected_line.id, (access_result->>'staff_id')::bigint, access_result->>'staff_name');
  return jsonb_build_object('ok', true, 'order', public.pos_sales_order_payload(selected_order));
end;
$$;
-- Only the existing staff-session Edge Function can invoke the mutation.
revoke all on function public.claim_pos_warranty_for_store(text, text, text, bigint, uuid) from public, anon, authenticated;
grant execute on function public.claim_pos_warranty_for_store(text, text, text, bigint, uuid) to service_role;
