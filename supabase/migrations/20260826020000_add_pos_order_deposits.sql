-- POS order deposits.
--
-- A deposit is not a separate invoice. It is a partial payment against the real
-- order, which stays open until the balance is collected:
--   * the order keeps one invoice number and the full job total
--   * balance_due = total - amount_paid, always derived, never stored twice
--   * every payment is stamped with the shift/staff/date that actually took it,
--     so the money lands in the drawer of the day it was received
--   * a repair ticket is only closed when the order becomes fully paid
--
-- Abandoned deposits are intentionally left open forever; there is no forfeit
-- action by design.

-- 1. Order level deposit state -------------------------------------------------

alter table public.pos_sales_orders
  add column if not exists payment_status text not null default 'paid',
  add column if not exists amount_paid numeric(12,2) not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conname = 'pos_sales_orders_payment_status_check'
  ) then
    alter table public.pos_sales_orders
      add constraint pos_sales_orders_payment_status_check
      check (payment_status in ('deposit', 'paid'));
  end if;
end $$;

-- Every order that existed before deposits was fully paid at checkout.
update public.pos_sales_orders
set amount_paid = total
where amount_paid = 0 and total > 0;

create index if not exists pos_sales_orders_balance_due_idx
on public.pos_sales_orders (store_id, created_at desc)
where payment_status = 'deposit';

-- 2. Payment attribution -------------------------------------------------------
-- A balance payment belongs to the shift that took it, not to the shift that
-- opened the order. Without this the deposit day is over and the pickup day is
-- short by the same amount.

alter table public.pos_sales_order_payments
  add column if not exists shift_id text,
  add column if not exists staff_name text,
  add column if not exists business_date date,
  add column if not exists taken_at timestamptz;

update public.pos_sales_order_payments payment
set
  shift_id = coalesce(payment.shift_id, sales_order.shift_id),
  staff_name = coalesce(payment.staff_name, sales_order.staff_name),
  business_date = coalesce(payment.business_date, sales_order.business_date),
  taken_at = coalesce(payment.taken_at, payment.created_at)
from public.pos_sales_orders sales_order
where sales_order.id = payment.sales_order_id
  and (
    payment.shift_id is null
    or payment.staff_name is null
    or payment.business_date is null
    or payment.taken_at is null
  );

create index if not exists pos_sales_order_payments_shift_idx
on public.pos_sales_order_payments (shift_id);

create index if not exists pos_sales_order_payments_business_date_idx
on public.pos_sales_order_payments (business_date);

-- 3. Shared helper: close the repair tickets attached to a paid order ----------

create or replace function public.close_pos_repair_tickets_for_order(
  target_order_id bigint,
  acting_staff_name text,
  target_invoice_number bigint,
  target_customer_name text,
  target_customer_phone text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.pos_repair_tickets repair_ticket
  set
    customer_name = target_customer_name,
    customer_phone = target_customer_phone,
    customer_contact = target_customer_phone,
    status = 'waiting_pickup',
    resolution = coalesce(repair_ticket.resolution, 'repaired'),
    ready_for_pickup_at = coalesce(repair_ticket.ready_for_pickup_at, now()),
    closed_at = now(),
    updated_by = acting_staff_name,
    status_updated_at = now(),
    activity = jsonb_build_array(jsonb_build_object(
      'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'type', 'paid',
      'text', 'checked out this repair on invoice #' || target_invoice_number,
      'staffName', acting_staff_name,
      'at', now()
    )) || coalesce(repair_ticket.activity, '[]'::jsonb)
  where repair_ticket.id in (
    select sales_line.repair_ticket_id
    from public.pos_sales_order_lines sales_line
    where sales_line.sales_order_id = target_order_id
      and sales_line.repair_ticket_id is not null
  )
  and repair_ticket.closed_at is null;
end;
$$;

-- 4. Order payload now carries the deposit state ------------------------------

create or replace function public.pos_sales_order_payload(order_row public.pos_sales_orders)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with line_rows as (
    select
      coalesce(
        jsonb_agg(
          sales_line.line_payload || jsonb_build_object(
            'line_id', sales_line.id,
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
            'refundable_amount', greatest(sales_line.line_total - coalesce(refunded.amount, 0), 0)
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
      select coalesce(sum(refund_line.amount), 0) as amount
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
        )
        order by payment.payment_number
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
    -- A deposit order can only ever be refunded down to what was actually received.
    'refundable_total', greatest(least(order_row.total, order_row.amount_paid) - refund_rows.refund_total, 0),
    'refund_status', case
      when refund_rows.refund_total <= 0 then 'paid'
      when refund_rows.refund_total < order_row.total then 'partially_refunded'
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
$$;

-- 5. save_pos_sales_order accepts a deposit -----------------------------------

create or replace function public.save_pos_sales_order(session_token text, payload jsonb)
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
  requested_status text;
  payment_status_value text;
  shift_id_value text;
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;
  if jsonb_typeof(payload) <> 'object' then raise exception 'Order payload must be a JSON object'; end if;

  order_code_value := coalesce(trim(payload->>'id'), '');
  if order_code_value = '' then raise exception 'Order id is required'; end if;
  if jsonb_typeof(payload->'items') <> 'array' or jsonb_array_length(payload->'items') = 0 then
    raise exception 'Order must contain at least one item';
  end if;
  if jsonb_typeof(payload->'payments') <> 'array' or jsonb_array_length(payload->'payments') = 0 then
    raise exception 'Order must contain at least one payment';
  end if;

  total_value := round(coalesce(nullif(payload->>'total', '')::numeric, 0), 2);
  if total_value < 0 then raise exception 'Order total cannot be negative'; end if;

  select round(coalesce(sum(coalesce(nullif(payment->>'amount', '')::numeric, 0)), 0), 2)
  into payment_total from jsonb_array_elements(payload->'payments') payment;

  requested_status := lower(coalesce(nullif(trim(payload->>'payment_status'), ''), 'paid'));
  if requested_status not in ('deposit', 'paid') then
    raise exception 'Unknown order payment status';
  end if;

  if payment_total <= 0 then raise exception 'Payment amount must be above zero'; end if;
  if payment_total < total_value and requested_status <> 'deposit' then
    raise exception 'Payment total is less than order total';
  end if;
  -- The stored status is derived from the money, never from the client's claim:
  -- a "deposit" that covers the whole job is simply a paid order.
  payment_status_value := case when payment_total >= total_value then 'paid' else 'deposit' end;

  select round(coalesce(sum(
    coalesce(
      nullif(item->>'line_total', '')::numeric,
      coalesce(nullif(item->>'unit_price', '')::numeric, nullif(item->>'sale_price', '')::numeric, 0)
        * greatest(coalesce(nullif(item->>'qty', '')::integer, 1), 1)
    )
  ), 0), 2)
  into item_total from jsonb_array_elements(payload->'items') item;
  if item_total <> total_value then raise exception 'Order item total does not match order total'; end if;

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
  business_date_value := coalesce(nullif(payload->>'business_date', '')::date, (created_at_value at time zone 'Australia/Brisbane')::date);
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

  if repair_item_count > 0 then
    if coalesce(trim(payload->>'customer_name'), '') = '' or lower(trim(payload->>'customer_name')) = 'walk-in customer' then
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
    ) then
      raise exception 'Repair sale item is missing ticket id';
    end if;

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

    if repair_ticket_count <> repair_item_count then
      raise exception 'Repair ticket is missing, closed, or belongs to another store';
    end if;

    if exists (
      select 1
      from public.pos_sales_order_lines sales_line
      join public.pos_repair_tickets repair_ticket on repair_ticket.id = sales_line.repair_ticket_id
      where repair_ticket.ticket_code in (
        select coalesce(
          nullif(trim(item->>'ticket_id'), ''),
          nullif(regexp_replace(coalesce(item->>'product_id', ''), '^repair-', ''), coalesce(item->>'product_id', ''))
        )
        from jsonb_array_elements(payload->'items') item
        where lower(coalesce(item->>'is_repair', 'false')) = 'true'
      )
    ) then
      raise exception 'Repair ticket has already been invoiced';
    end if;
  end if;

  insert into public.pos_store_invoice_counters (store_id, last_number)
  values (selected_store.id, 1)
  on conflict (store_id) do update set
    last_number = public.pos_store_invoice_counters.last_number + 1,
    updated_at = now()
  returning last_number into next_invoice_number;

  insert into public.pos_sales_orders (
    order_code, invoice_number, store_id, business_date, staff_name, shift_id,
    customer_name, customer_phone, customer_email, payment_method, total,
    payment_status, amount_paid, order_payload, created_at
  ) values (
    order_code_value,
    next_invoice_number,
    selected_store.id,
    business_date_value,
    selected_staff.display_name,
    shift_id_value,
    coalesce(nullif(trim(payload->>'customer_name'), ''), 'Walk-in Customer'),
    coalesce(trim(payload->>'customer_phone'), ''),
    coalesce(trim(payload->>'customer_email'), ''),
    coalesce(nullif(trim(payload->>'payment_method'), ''), 'Unknown'),
    total_value,
    payment_status_value,
    least(payment_total, total_value),
    payload || jsonb_build_object('sync_pending', false),
    created_at_value
  ) returning * into saved_order;

  insert into public.pos_sales_order_lines (
    sales_order_id, line_number, line_type, product_id, repair_ticket_id,
    sku, name, category, quantity, unit_price, line_total, line_payload, created_at
  )
  select
    saved_order.id,
    item.ordinality::integer,
    case
      when lower(coalesce(item.value->>'is_repair', 'false')) = 'true' then 'repair'
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
    round(coalesce(nullif(item.value->>'unit_price', '')::numeric, nullif(item.value->>'sale_price', '')::numeric, 0), 2),
    round(coalesce(
      nullif(item.value->>'line_total', '')::numeric,
      coalesce(nullif(item.value->>'unit_price', '')::numeric, nullif(item.value->>'sale_price', '')::numeric, 0)
        * greatest(coalesce(nullif(item.value->>'qty', '')::integer, 1), 1)
    ), 2),
    item.value,
    created_at_value
  from jsonb_array_elements(payload->'items') with ordinality as item(value, ordinality)
  left join public.pos_repair_tickets repair_ticket
    on repair_ticket.ticket_code = coalesce(
      nullif(trim(item.value->>'ticket_id'), ''),
      nullif(regexp_replace(coalesce(item.value->>'product_id', ''), '^repair-', ''), coalesce(item.value->>'product_id', ''))
    );

  insert into public.pos_sales_order_payments (
    sales_order_id, payment_number, method, amount,
    shift_id, staff_name, business_date, taken_at, created_at
  )
  select
    saved_order.id,
    payment.ordinality::integer,
    coalesce(nullif(trim(payment.value->>'method'), ''), saved_order.payment_method),
    round(coalesce(nullif(payment.value->>'amount', '')::numeric, 0), 2),
    shift_id_value,
    selected_staff.display_name,
    business_date_value,
    created_at_value,
    created_at_value
  from jsonb_array_elements(payload->'payments') with ordinality as payment(value, ordinality)
  where coalesce(nullif(payment.value->>'amount', '')::numeric, 0) > 0;

  -- A deposit leaves the repair ticket open; it is closed when the balance lands.
  if payment_status_value = 'paid' then
    perform public.close_pos_repair_tickets_for_order(
      saved_order.id,
      selected_staff.display_name,
      next_invoice_number,
      saved_order.customer_name,
      saved_order.customer_phone
    );
  end if;

  return jsonb_build_object('ok', true, 'order', public.pos_sales_order_payload(saved_order));
end;
$$;

-- 6. Collect the balance on an existing order ---------------------------------

create or replace function public.add_pos_sales_order_payment(session_token text, payload jsonb)
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
  payment_total numeric(12,2);
  balance_due numeric(12,2);
  new_amount_paid numeric(12,2);
  new_status text;
  last_payment_number integer;
  taken_at_value timestamptz;
  business_date_value date;
  shift_id_value text;
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;
  if jsonb_typeof(payload) <> 'object' then raise exception 'Payment payload must be an object'; end if;

  order_code_value := coalesce(trim(payload->>'order_id'), trim(payload->>'id'), '');
  if order_code_value = '' then raise exception 'Order id is required'; end if;
  if jsonb_typeof(payload->'payments') <> 'array' or jsonb_array_length(payload->'payments') = 0 then
    raise exception 'At least one payment is required';
  end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = coalesce(trim(payload->>'store_code'), '')
    and store_location.store_code <> 'warehouse';
  if not found then raise exception 'Store not found'; end if;

  select * into selected_staff
  from public.staff_directory staff
  where staff.active = true and lower(staff.display_name) = lower(coalesce(trim(payload->>'staff_name'), ''))
  limit 1;
  if not found then raise exception 'Staff member not found'; end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(order_code_value, 0));
  select * into saved_order
  from public.pos_sales_orders sales_order
  where sales_order.order_code = order_code_value
  for update;
  if not found then raise exception 'Invoice not found'; end if;
  if saved_order.store_id <> selected_store.id then raise exception 'Invoice belongs to another store'; end if;

  balance_due := round(greatest(saved_order.total - saved_order.amount_paid, 0), 2);
  if balance_due <= 0 then raise exception 'This invoice is already fully paid'; end if;

  select round(coalesce(sum(coalesce(nullif(payment->>'amount', '')::numeric, 0)), 0), 2)
  into payment_total from jsonb_array_elements(payload->'payments') payment;
  if payment_total <= 0 then raise exception 'Payment amount must be above zero'; end if;
  if payment_total > balance_due then raise exception 'Payment is more than the balance due'; end if;

  taken_at_value := coalesce(nullif(payload->>'taken_at', '')::timestamptz, now());
  business_date_value := coalesce(
    nullif(payload->>'business_date', '')::date,
    (taken_at_value at time zone 'Australia/Brisbane')::date
  );
  shift_id_value := nullif(trim(payload->>'shift_id'), '');

  select coalesce(max(payment.payment_number), 0)
  into last_payment_number
  from public.pos_sales_order_payments payment
  where payment.sales_order_id = saved_order.id;

  insert into public.pos_sales_order_payments (
    sales_order_id, payment_number, method, amount,
    shift_id, staff_name, business_date, taken_at, created_at
  )
  select
    saved_order.id,
    last_payment_number + payment.ordinality::integer,
    coalesce(nullif(trim(payment.value->>'method'), ''), 'Unknown'),
    round(coalesce(nullif(payment.value->>'amount', '')::numeric, 0), 2),
    shift_id_value,
    selected_staff.display_name,
    business_date_value,
    taken_at_value,
    taken_at_value
  from jsonb_array_elements(payload->'payments') with ordinality as payment(value, ordinality)
  where coalesce(nullif(payment.value->>'amount', '')::numeric, 0) > 0;

  new_amount_paid := round(saved_order.amount_paid + payment_total, 2);
  new_status := case when new_amount_paid >= saved_order.total then 'paid' else 'deposit' end;

  update public.pos_sales_orders
  set
    amount_paid = new_amount_paid,
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
      saved_order.id,
      selected_staff.display_name,
      saved_order.invoice_number,
      saved_order.customer_name,
      saved_order.customer_phone
    );
  end if;

  return jsonb_build_object('ok', true, 'order', public.pos_sales_order_payload(saved_order));
end;
$$;

-- 7. Shift totals follow the money, not the order -----------------------------

create or replace function public.get_pos_shift_payment_totals(session_token text, target_shift_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  shift_row public.pos_store_shifts%rowtype;
  totals_payload jsonb;
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;

  select * into shift_row
  from public.pos_store_shifts shift_record
  where shift_record.shift_code = coalesce(trim(target_shift_code), '')
  limit 1;
  if not found then raise exception 'Shift not found'; end if;

  with received as (
    -- Attributed by the payment's own shift so a balance collected days later
    -- lands in the drawer that actually took it.
    select payment.method, round(sum(payment.amount), 2) as amount
    from public.pos_sales_order_payments payment
    join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id
    where sales_order.store_id = shift_row.store_id
      and coalesce(payment.shift_id, sales_order.shift_id) = shift_row.shift_code
    group by payment.method
  ),
  refunded as (
    select refund.method, round(sum(refund.amount), 2) as amount
    from public.pos_sales_refunds refund
    where refund.store_id = shift_row.store_id
      and refund.created_at >= shift_row.opened_at
      and (shift_row.closed_at is null or refund.created_at <= shift_row.closed_at)
    group by refund.method
  ),
  paid_out as (
    select acquisition.payout_method as method, round(sum(acquisition.payout_amount), 2) as amount
    from public.pos_used_device_acquisitions acquisition
    where acquisition.store_id = shift_row.store_id
      and acquisition.shift_id = shift_row.shift_code
    group by acquisition.payout_method
  ),
  methods as (
    select method from received
    union select method from refunded
    union select method from paid_out
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'method', methods.method,
    'received', coalesce(received.amount, 0),
    'refunded', coalesce(refunded.amount, 0),
    'paid_out', coalesce(paid_out.amount, 0),
    'amount', coalesce(received.amount, 0) - coalesce(refunded.amount, 0) - coalesce(paid_out.amount, 0)
  ) order by methods.method), '[]'::jsonb)
  into totals_payload
  from methods
  left join received on received.method = methods.method
  left join refunded on refunded.method = methods.method
  left join paid_out on paid_out.method = methods.method;

  return jsonb_build_object(
    'ok', true,
    'shift_id', shift_row.shift_code,
    'payment_totals', totals_payload,
    'order_count', (
      select count(*) from public.pos_sales_orders sales_order
      where sales_order.store_id = shift_row.store_id and sales_order.shift_id = shift_row.shift_code
    ),
    -- Cash basis: takings are the money received in this shift, so a deposit
    -- counts on the day it is taken and the balance on the day it is collected.
    'gross_sales', (
      select coalesce(round(sum(payment.amount), 2), 0)
      from public.pos_sales_order_payments payment
      join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id
      where sales_order.store_id = shift_row.store_id
        and coalesce(payment.shift_id, sales_order.shift_id) = shift_row.shift_code
    ),
    'deposit_balance_outstanding', (
      select coalesce(round(sum(sales_order.total - sales_order.amount_paid), 2), 0)
      from public.pos_sales_orders sales_order
      where sales_order.store_id = shift_row.store_id
        and sales_order.payment_status = 'deposit'
    ),
    'used_device_acquisition_count', (
      select count(*) from public.pos_used_device_acquisitions acquisition
      where acquisition.store_id = shift_row.store_id and acquisition.shift_id = shift_row.shift_code
    ),
    'used_device_acquisition_spend', (
      select coalesce(sum(acquisition.payout_amount), 0) from public.pos_used_device_acquisitions acquisition
      where acquisition.store_id = shift_row.store_id and acquisition.shift_id = shift_row.shift_code
    )
  );
end;
$$;

-- 8. A deposit order can never be refunded for more than was received ---------

create or replace function public.enforce_pos_refund_within_amount_paid()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.pos_sales_orders%rowtype;
  refunded_total numeric(12,2);
begin
  select * into order_row
  from public.pos_sales_orders sales_order
  where sales_order.id = new.sales_order_id;
  if not found then return new; end if;

  select round(coalesce(sum(refund.amount), 0), 2)
  into refunded_total
  from public.pos_sales_refunds refund
  where refund.sales_order_id = new.sales_order_id;

  if refunded_total > round(order_row.amount_paid, 2) then
    raise exception 'Refund total % is more than the % received on this invoice',
      refunded_total, order_row.amount_paid;
  end if;

  return new;
end;
$$;

drop trigger if exists pos_sales_refunds_within_amount_paid on public.pos_sales_refunds;
create constraint trigger pos_sales_refunds_within_amount_paid
after insert on public.pos_sales_refunds
deferrable initially immediate
for each row execute function public.enforce_pos_refund_within_amount_paid();

-- 9. Grants --------------------------------------------------------------------

revoke all on function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text) from public, anon, authenticated;
grant execute on function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text) to service_role;

revoke all on function public.add_pos_sales_order_payment(text, jsonb) from public, anon, authenticated;
grant execute on function public.add_pos_sales_order_payment(text, jsonb) to anon, authenticated, service_role;

comment on column public.pos_sales_orders.payment_status is
  'deposit = balance still owing, paid = settled in full. balance_due is derived as total - amount_paid.';
comment on column public.pos_sales_order_payments.shift_id is
  'Shift that physically took this payment. A balance payment belongs to the pickup day, not to the day the order was opened.';
