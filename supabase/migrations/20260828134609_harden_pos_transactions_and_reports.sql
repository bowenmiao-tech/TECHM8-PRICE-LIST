-- Harden POS authorization and money/inventory audit fields. All public entry
-- points bind the acting employee to the signed-in custom staff session and to
-- an open, cash-confirmed shift in the selected store.

alter table public.pos_sales_refund_lines
  add column if not exists returned_quantity integer not null default 0;

alter table public.pos_sales_refund_lines
  drop constraint if exists pos_sales_refund_lines_returned_quantity_check;
alter table public.pos_sales_refund_lines
  add constraint pos_sales_refund_lines_returned_quantity_check
  check (returned_quantity >= 0);

alter table public.pos_sales_refunds
  add column if not exists shift_id text,
  add column if not exists business_date date;

create index if not exists pos_sales_refunds_shift_id_idx
  on public.pos_sales_refunds (shift_id);
create index if not exists pos_sales_refunds_store_business_date_idx
  on public.pos_sales_refunds (store_id, business_date);

-- The only administrator is Bowen's account. All other enabled accounts have
-- one role and are constrained by their assigned default store.
update public.staff_directory
set job_role = case
  when lower(trim(email)) = 'techm8contact@gmail.com' then 'admin'
  else 'staff'
end
where job_role is distinct from case
  when lower(trim(email)) = 'techm8contact@gmail.com' then 'admin'
  else 'staff'
end;

create or replace function public.pos_authorized_actor(
  session_token text,
  target_store_code text,
  requested_staff_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  access_result jsonb;
  selected_store public.store_locations%rowtype;
  selected_actor public.staff_directory%rowtype;
  signed_staff_id bigint;
  signed_email text;
  is_admin boolean;
  requested_name text := nullif(trim(coalesce(requested_staff_name, '')), '');
begin
  access_result := public.verify_staff_store_access(session_token, target_store_code);
  if not coalesce((access_result->>'ok')::boolean, false)
    or not coalesce((access_result->>'allowed')::boolean, false) then
    raise exception '%', coalesce(access_result->>'message', 'Store access denied');
  end if;

  signed_staff_id := nullif(access_result->>'staff_id', '')::bigint;
  signed_email := lower(trim(coalesce(access_result->>'staff_email', '')));
  is_admin := signed_email = 'techm8contact@gmail.com';

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse'
    and store_location.store_code = lower(trim(coalesce(target_store_code, '')))
  limit 1;
  if not found then raise exception 'Store not found'; end if;

  if is_admin and requested_name is not null then
    select * into selected_actor
    from public.staff_directory staff
    where staff.active = true
      and lower(staff.display_name) = lower(requested_name)
      and (
        staff.default_store_id = selected_store.id
        or lower(trim(staff.email)) = 'techm8contact@gmail.com'
      )
    limit 1;
    if not found then
      raise exception 'The selected staff member is not assigned to this store';
    end if;
  else
    select * into selected_actor
    from public.staff_directory staff
    where staff.id = signed_staff_id and staff.active = true
    limit 1;
    if not found then raise exception 'Staff member not found'; end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'is_admin', is_admin,
    'signed_staff_id', signed_staff_id,
    'staff_id', selected_actor.id,
    'staff_name', selected_actor.display_name,
    'staff_email', lower(trim(selected_actor.email)),
    'store_id', selected_store.id,
    'store_code', selected_store.store_code,
    'store_name', selected_store.store_name
  );
end;
$$;

create or replace function public.pos_open_shift_context(
  session_token text,
  target_store_code text,
  target_shift_code text,
  requested_staff_name text default null,
  require_opening_cash boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_context jsonb;
  shift_row public.pos_store_shifts%rowtype;
  today_value date := (now() at time zone 'Australia/Brisbane')::date;
begin
  actor_context := public.pos_authorized_actor(
    session_token,
    target_store_code,
    requested_staff_name
  );

  if nullif(trim(coalesce(target_shift_code, '')), '') is null then
    raise exception 'An open store shift is required';
  end if;

  select * into shift_row
  from public.pos_store_shifts shift_record
  where shift_record.shift_code = trim(target_shift_code)
    and shift_record.store_id = nullif(actor_context->>'store_id', '')::bigint
    and shift_record.business_date = today_value
    and shift_record.status = 'open'
  for update;
  if not found then raise exception 'Today''s open shift was not found for this store'; end if;

  if require_opening_cash and shift_row.opening_confirmed_at is null then
    raise exception 'Enter and confirm today''s opening cash before using the POS';
  end if;

  return actor_context || jsonb_build_object(
    'shift_id', shift_row.shift_code,
    'business_date', shift_row.business_date,
    'opening_confirmed', shift_row.opening_confirmed_at is not null
  );
end;
$$;

create or replace function public.save_pos_sales_order_for_store(
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
  sanitized_payload jsonb;
  total_value numeric(12,2);
  payment_total numeric(12,2);
begin
  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Order payload must be a JSON object';
  end if;

  shift_context := public.pos_open_shift_context(
    session_token,
    coalesce(payload->>'store_db_code', payload->>'store_code', payload->>'store_id'),
    payload->>'shift_id',
    payload->>'staff_name',
    true
  );

  total_value := round(coalesce(nullif(payload->>'total', '')::numeric, 0), 2);
  select round(coalesce(sum(coalesce(nullif(payment->>'amount', '')::numeric, 0)), 0), 2)
  into payment_total
  from jsonb_array_elements(coalesce(payload->'payments', '[]'::jsonb)) payment;

  if total_value <= 0 then raise exception 'Order total must be above zero'; end if;
  if payment_total <= 0 then raise exception 'Payment amount must be above zero'; end if;
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
    'payment_status', case when payment_total >= total_value then 'paid' else 'deposit' end
  );

  return public.save_pos_sales_order(session_token, sanitized_payload);
end;
$$;

create or replace function public.add_pos_sales_order_payment_for_store(
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
  selected_order public.pos_sales_orders%rowtype;
  sanitized_payload jsonb;
  order_code_value text := coalesce(trim(payload->>'order_id'), trim(payload->>'id'), '');
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Payment payload must be an object'; end if;

  shift_context := public.pos_open_shift_context(
    session_token,
    payload->>'store_code',
    payload->>'shift_id',
    payload->>'staff_name',
    true
  );

  select * into selected_order
  from public.pos_sales_orders sales_order
  where sales_order.order_code = order_code_value
    and sales_order.store_id = nullif(shift_context->>'store_id', '')::bigint
  for update;
  if not found then raise exception 'Invoice not found in the current store'; end if;

  sanitized_payload := payload || jsonb_build_object(
    'store_code', shift_context->>'store_code',
    'staff_name', shift_context->>'staff_name',
    'shift_id', shift_context->>'shift_id',
    'business_date', shift_context->>'business_date',
    'taken_at', now()
  );
  return public.add_pos_sales_order_payment(session_token, sanitized_payload);
end;
$$;

create or replace function public.refund_pos_sales_order_for_store(
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
  selected_order public.pos_sales_orders%rowtype;
  refund_row public.pos_sales_refunds%rowtype;
  order_code_value text := coalesce(trim(payload->>'order_id'), '');
  reason_value text := coalesce(trim(payload->>'reason'), '');
  method_value text := coalesce(trim(payload->>'refund_method'), '');
  refund_total numeric(12,2);
  already_refunded numeric(12,2);
  requested_count integer;
  distinct_count integer;
  valid_count integer;
  sanitized_payload jsonb;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Refund payload must be an object'; end if;
  if order_code_value = '' then raise exception 'Order id is required'; end if;
  if reason_value = '' then raise exception 'Refund reason is required'; end if;
  if method_value = '' then raise exception 'Refund method is required'; end if;
  if jsonb_typeof(payload->'lines') <> 'array' or jsonb_array_length(payload->'lines') = 0 then
    raise exception 'Select at least one refund line';
  end if;

  shift_context := public.pos_open_shift_context(
    session_token,
    payload->>'store_code',
    payload->>'shift_id',
    payload->>'staff_name',
    true
  );

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('refund:' || order_code_value, 0));
  select * into selected_order
  from public.pos_sales_orders sales_order
  where sales_order.order_code = order_code_value
    and sales_order.store_id = nullif(shift_context->>'store_id', '')::bigint
  for update;
  if not found then raise exception 'Invoice not found in the current store'; end if;

  select
    count(*),
    count(distinct nullif(line->>'line_id', '')::bigint),
    round(coalesce(sum(coalesce(nullif(line->>'amount', '')::numeric, 0)), 0), 2)
  into requested_count, distinct_count, refund_total
  from jsonb_array_elements(payload->'lines') line;
  if requested_count <> distinct_count then raise exception 'Each refund line may only be selected once'; end if;
  if refund_total <= 0 then raise exception 'Refund amount must be above zero'; end if;

  select round(coalesce(sum(existing_refund.amount), 0), 2)
  into already_refunded
  from public.pos_sales_refunds existing_refund
  where existing_refund.sales_order_id = selected_order.id;
  if refund_total > greatest(selected_order.amount_paid - already_refunded, 0) then
    raise exception 'Refund is more than the amount received';
  end if;

  with requested as (
    select
      nullif(line->>'line_id', '')::bigint as line_id,
      round(coalesce(nullif(line->>'amount', '')::numeric, 0), 2) as amount,
      greatest(coalesce(nullif(line->>'quantity', '')::integer, 0), 0) as returned_quantity
    from jsonb_array_elements(payload->'lines') line
  )
  select count(*) into valid_count
  from requested
  join public.pos_sales_order_lines sales_line
    on sales_line.id = requested.line_id
    and sales_line.sales_order_id = selected_order.id
  left join lateral (
    select
      coalesce(sum(existing_line.amount), 0) as amount,
      coalesce(sum(existing_line.returned_quantity), 0) as returned_quantity
    from public.pos_sales_refund_lines existing_line
    where existing_line.sales_order_line_id = sales_line.id
  ) refunded on true
  where requested.amount > 0
    and requested.amount <= sales_line.line_total - refunded.amount
    and requested.returned_quantity <= sales_line.quantity - refunded.returned_quantity
    and (
      requested.returned_quantity = 0
      or sales_line.line_type in ('product', 'retail', 'used_device')
    );

  if valid_count <> requested_count then
    raise exception 'Refund line amount or returned quantity is invalid';
  end if;

  sanitized_payload := payload || jsonb_build_object(
    'store_code', shift_context->>'store_code',
    'staff_name', shift_context->>'staff_name',
    'shift_id', shift_context->>'shift_id',
    'business_date', shift_context->>'business_date',
    'created_at', now()
  );

  insert into public.pos_sales_refunds (
    refund_code, sales_order_id, store_id, staff_name, method, reason,
    amount, refund_payload, shift_id, business_date, created_at
  ) values (
    'RFD-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 18)),
    selected_order.id,
    selected_order.store_id,
    shift_context->>'staff_name',
    method_value,
    reason_value,
    refund_total,
    sanitized_payload,
    shift_context->>'shift_id',
    nullif(shift_context->>'business_date', '')::date,
    now()
  ) returning * into refund_row;

  insert into public.pos_sales_refund_lines (
    refund_id, sales_order_line_id, amount, returned_quantity
  )
  select
    refund_row.id,
    sales_line.id,
    round(nullif(requested->>'amount', '')::numeric, 2),
    greatest(coalesce(nullif(requested->>'quantity', '')::integer, 0), 0)
  from jsonb_array_elements(payload->'lines') requested
  join public.pos_sales_order_lines sales_line
    on sales_line.id = nullif(requested->>'line_id', '')::bigint
    and sales_line.sales_order_id = selected_order.id;

  return jsonb_build_object(
    'ok', true,
    'refund_id', refund_row.refund_code,
    'order', public.pos_sales_order_payload(selected_order)
  );
end;
$$;

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
$$;

create or replace function public.get_pos_shift_payment_totals(
  session_token text,
  target_shift_code text
)
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
      and refund.shift_id = shift_row.shift_code
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
        and sales_order.shift_id = shift_row.shift_code
        and sales_order.payment_status = 'deposit'
    ),
    'used_device_acquisition_count', (
      select count(*) from public.pos_used_device_acquisitions acquisition
      where acquisition.store_id = shift_row.store_id and acquisition.shift_id = shift_row.shift_code
    ),
    'used_device_acquisition_spend', (
      select coalesce(sum(acquisition.payout_amount), 0)
      from public.pos_used_device_acquisitions acquisition
      where acquisition.store_id = shift_row.store_id and acquisition.shift_id = shift_row.shift_code
    )
  );
end;
$$;

create or replace function public.get_pos_shift_payment_totals_for_store(
  session_token text,
  target_store_code text,
  target_shift_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_context jsonb;
begin
  actor_context := public.pos_authorized_actor(session_token, target_store_code, null);
  if not exists (
    select 1 from public.pos_store_shifts shift_record
    where shift_record.shift_code = coalesce(trim(target_shift_code), '')
      and shift_record.store_id = nullif(actor_context->>'store_id', '')::bigint
  ) then
    raise exception 'Shift not found in the current store';
  end if;
  return public.get_pos_shift_payment_totals(session_token, target_shift_code);
end;
$$;

create or replace function public.save_pos_shift_opening_for_store(
  session_token text,
  target_store_code text,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  shift_context jsonb;
  sanitized_payload jsonb;
begin
  shift_context := public.pos_open_shift_context(
    session_token,
    target_store_code,
    payload->>'shift_id',
    payload->>'staff_name',
    false
  );
  sanitized_payload := payload || jsonb_build_object(
    'staff_name', shift_context->>'staff_name',
    'shift_id', shift_context->>'shift_id'
  );
  return public.save_pos_shift_opening(session_token, sanitized_payload);
end;
$$;

create or replace function public.close_pos_store_shift_for_store(
  session_token text,
  target_store_code text,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  shift_context jsonb;
  sanitized_payload jsonb;
begin
  shift_context := public.pos_open_shift_context(
    session_token,
    target_store_code,
    payload->>'shift_id',
    payload->>'staff_name',
    true
  );
  sanitized_payload := payload || jsonb_build_object(
    'staff_name', shift_context->>'staff_name',
    'shift_id', shift_context->>'shift_id'
  );
  return public.close_pos_store_shift(session_token, sanitized_payload);
end;
$$;

create or replace function public.get_pos_sales_report(
  session_token text,
  target_store_code text,
  date_from date,
  date_to date,
  target_staff_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_context jsonb;
  selected_store public.store_locations%rowtype;
  from_value date := coalesce(date_from, (now() at time zone 'Australia/Brisbane')::date);
  to_value date := coalesce(date_to, date_from, (now() at time zone 'Australia/Brisbane')::date);
  staff_value text := nullif(trim(coalesce(target_staff_name, '')), '');
  report_payload jsonb;
begin
  actor_context := public.pos_authorized_actor(session_token, target_store_code, null);
  if from_value > to_value then raise exception 'Start date must not be after end date'; end if;
  if to_value - from_value > 366 then raise exception 'Report range cannot exceed 367 days'; end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.id = nullif(actor_context->>'store_id', '')::bigint;

  with sale_orders as (
    select sales_order.*
    from public.pos_sales_orders sales_order
    where sales_order.store_id = selected_store.id
      and sales_order.business_date between from_value and to_value
      and (staff_value is null or lower(sales_order.staff_name) = lower(staff_value))
  ),
  payment_rows as (
    select payment.*
    from public.pos_sales_order_payments payment
    join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id
    where sales_order.store_id = selected_store.id
      and coalesce(payment.business_date, (payment.created_at at time zone 'Australia/Brisbane')::date)
        between from_value and to_value
      and (staff_value is null or lower(coalesce(payment.staff_name, sales_order.staff_name)) = lower(staff_value))
  ),
  refund_rows as (
    select refund.*,
      coalesce(refund.business_date, (refund.created_at at time zone 'Australia/Brisbane')::date) as report_date
    from public.pos_sales_refunds refund
    where refund.store_id = selected_store.id
      and coalesce(refund.business_date, (refund.created_at at time zone 'Australia/Brisbane')::date)
        between from_value and to_value
      and (staff_value is null or lower(refund.staff_name) = lower(staff_value))
  ),
  sale_lines as (
    select sales_line.*
    from public.pos_sales_order_lines sales_line
    join sale_orders sales_order on sales_order.id = sales_line.sales_order_id
  ),
  refunded_lines as (
    select refund_line.amount, refund_line.returned_quantity,
      sales_line.line_type, sales_line.category
    from public.pos_sales_refund_lines refund_line
    join refund_rows refund on refund.id = refund_line.refund_id
    join public.pos_sales_order_lines sales_line on sales_line.id = refund_line.sales_order_line_id
  ),
  summary as (
    select
      coalesce((select sum(total) from sale_orders), 0)::numeric(12,2) as gross_sales,
      coalesce((select sum(amount) from refund_rows), 0)::numeric(12,2) as refunds,
      coalesce((select count(*) from sale_orders), 0)::integer as invoice_count,
      coalesce((select count(*) from refund_rows), 0)::integer as refund_count,
      coalesce((select sum(quantity) from sale_lines), 0)::integer as item_units
  )
  select jsonb_build_object(
    'ok', true,
    'store_code', selected_store.store_code,
    'store_name', selected_store.store_name,
    'date_from', from_value,
    'date_to', to_value,
    'staff_name', staff_value,
    'summary', jsonb_build_object(
      'gross_sales', summary.gross_sales,
      'refunds', summary.refunds,
      'net_sales', summary.gross_sales - summary.refunds,
      'gst', round((summary.gross_sales - summary.refunds) / 11, 2),
      'invoice_count', summary.invoice_count,
      'refund_count', summary.refund_count,
      'item_units', summary.item_units,
      'average_sale', case when summary.invoice_count > 0 then round(summary.gross_sales / summary.invoice_count, 2) else 0 end
    ),
    'payment_totals', (
      select coalesce(jsonb_agg(jsonb_build_object('method', grouped.method, 'amount', grouped.amount) order by grouped.amount desc), '[]'::jsonb)
      from (
        select payment.method, round(sum(payment.amount), 2) as amount
        from payment_rows payment group by payment.method
      ) grouped
    ),
    'refund_method_totals', (
      select coalesce(jsonb_agg(jsonb_build_object('method', grouped.method, 'amount', grouped.amount) order by grouped.amount desc), '[]'::jsonb)
      from (
        select refund.method, round(sum(refund.amount), 2) as amount
        from refund_rows refund group by refund.method
      ) grouped
    ),
    'sale_type_totals', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'type', grouped.line_type,
        'gross', grouped.gross,
        'refunds', grouped.refunds,
        'net', grouped.gross - grouped.refunds,
        'units', grouped.units
      ) order by grouped.gross - grouped.refunds desc), '[]'::jsonb)
      from (
        select keys.line_type,
          coalesce((select sum(line_total) from sale_lines where sale_lines.line_type = keys.line_type), 0)::numeric(12,2) as gross,
          coalesce((select sum(amount) from refunded_lines where refunded_lines.line_type = keys.line_type), 0)::numeric(12,2) as refunds,
          coalesce((select sum(quantity) from sale_lines where sale_lines.line_type = keys.line_type), 0)::integer as units
        from (
          select line_type from sale_lines
          union select line_type from refunded_lines
        ) keys
      ) grouped
    ),
    'category_totals', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'category', grouped.category,
        'gross', grouped.gross,
        'refunds', grouped.refunds,
        'net', grouped.gross - grouped.refunds,
        'units', grouped.units
      ) order by grouped.gross - grouped.refunds desc), '[]'::jsonb)
      from (
        select keys.category,
          coalesce((select sum(line_total) from sale_lines where coalesce(nullif(trim(sale_lines.category), ''), 'Uncategorized') = keys.category), 0)::numeric(12,2) as gross,
          coalesce((select sum(amount) from refunded_lines where coalesce(nullif(trim(refunded_lines.category), ''), 'Uncategorized') = keys.category), 0)::numeric(12,2) as refunds,
          coalesce((select sum(quantity) from sale_lines where coalesce(nullif(trim(sale_lines.category), ''), 'Uncategorized') = keys.category), 0)::integer as units
        from (
          select coalesce(nullif(trim(category), ''), 'Uncategorized') as category from sale_lines
          union select coalesce(nullif(trim(category), ''), 'Uncategorized') from refunded_lines
        ) keys
      ) grouped
    ),
    'staff_totals', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'staff_name', grouped.staff_name,
        'gross', grouped.gross,
        'refunds', grouped.refunds,
        'net', grouped.gross - grouped.refunds,
        'invoice_count', grouped.invoice_count,
        'refund_count', grouped.refund_count
      ) order by grouped.gross - grouped.refunds desc), '[]'::jsonb)
      from (
        select keys.staff_name,
          coalesce((select sum(total) from sale_orders where lower(sale_orders.staff_name) = lower(keys.staff_name)), 0)::numeric(12,2) as gross,
          coalesce((select sum(amount) from refund_rows where lower(refund_rows.staff_name) = lower(keys.staff_name)), 0)::numeric(12,2) as refunds,
          coalesce((select count(*) from sale_orders where lower(sale_orders.staff_name) = lower(keys.staff_name)), 0)::integer as invoice_count,
          coalesce((select count(*) from refund_rows where lower(refund_rows.staff_name) = lower(keys.staff_name)), 0)::integer as refund_count
        from (
          select staff_name from sale_orders
          union select staff_name from refund_rows
        ) keys
      ) grouped
    ),
    'daily_totals', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'date', grouped.business_date,
        'gross', grouped.gross,
        'refunds', grouped.refunds,
        'net', grouped.gross - grouped.refunds,
        'invoice_count', grouped.invoice_count
      ) order by grouped.business_date), '[]'::jsonb)
      from (
        select keys.business_date,
          coalesce((select sum(total) from sale_orders where sale_orders.business_date = keys.business_date), 0)::numeric(12,2) as gross,
          coalesce((select sum(amount) from refund_rows where refund_rows.report_date = keys.business_date), 0)::numeric(12,2) as refunds,
          coalesce((select count(*) from sale_orders where sale_orders.business_date = keys.business_date), 0)::integer as invoice_count
        from (
          select business_date from sale_orders
          union select report_date from refund_rows
        ) keys
      ) grouped
    )
  ) into report_payload
  from summary;

  return report_payload;
end;
$$;

-- A used device may be discounted by staff, but it cannot be marked up above
-- its approved sale price and it can only be sold once.
create or replace function public.prepare_pos_used_device_sale_line()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  device_row public.pos_used_devices%rowtype;
  order_row public.pos_sales_orders%rowtype;
  device_code_value text;
begin
  if lower(coalesce(new.line_payload->>'is_used_device', 'false')) <> 'true' then return new; end if;

  device_code_value := coalesce(
    nullif(trim(new.line_payload->>'used_device_id'), ''),
    nullif(regexp_replace(new.product_id, '^used-', ''), new.product_id)
  );
  if device_code_value is null then raise exception 'Used device id is required'; end if;

  select * into order_row from public.pos_sales_orders where id = new.sales_order_id;
  select * into device_row
  from public.pos_used_devices device
  where device.device_code = device_code_value
  for update;
  if not found then raise exception 'Used device not found'; end if;
  if device_row.store_id <> order_row.store_id then raise exception 'Used device belongs to another store'; end if;
  if device_row.status <> 'ready_for_sale' then raise exception 'Used device is no longer available for sale'; end if;
  if new.quantity <> 1 then raise exception 'Used devices can only be sold once per line'; end if;
  if round(new.unit_price, 2) <= 0 then raise exception 'Used device sale price must be above zero'; end if;
  if round(new.unit_price, 2) > round(device_row.sale_price, 2) then
    raise exception 'Used device price cannot exceed the approved sale price';
  end if;

  new.line_type := 'used_device';
  new.used_device_id := device_row.id;
  new.product_id := 'used-' || device_row.device_code;
  new.sku := device_row.device_code;
  return new;
end;
$$;

create or replace function public.return_refunded_pos_used_device()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  sales_line public.pos_sales_order_lines%rowtype;
  refund_row public.pos_sales_refunds%rowtype;
  device_row public.pos_used_devices%rowtype;
  returned_total integer;
  refunded_total numeric(12,2);
begin
  select * into sales_line from public.pos_sales_order_lines where id = new.sales_order_line_id;
  if sales_line.used_device_id is null then return new; end if;

  select
    coalesce(sum(returned_quantity), 0),
    round(coalesce(sum(amount), 0), 2)
  into returned_total, refunded_total
  from public.pos_sales_refund_lines
  where sales_order_line_id = sales_line.id;
  if returned_total < 1 then return new; end if;

  select * into refund_row from public.pos_sales_refunds where id = new.refund_id;
  update public.pos_used_devices
  set status = 'inspection',
      sold_order_id = null,
      sold_order_line_id = null,
      sold_at = null,
      ready_at = null,
      updated_by = refund_row.staff_name
  where id = sales_line.used_device_id
    and status = 'sold'
    and sold_order_line_id = sales_line.id
  returning * into device_row;

  if found then
    insert into public.pos_used_device_transactions (
      transaction_code, device_id, store_id, transaction_type, from_status,
      to_status, amount, payment_method, related_sales_order_id,
      related_sales_order_line_id, staff_name, counterparty_name,
      counterparty_phone, notes, transaction_payload
    ) values (
      'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
      device_row.id, device_row.store_id, 'refund_return', 'sold', 'inspection',
      refunded_total, refund_row.method, sales_line.sales_order_id, sales_line.id,
      refund_row.staff_name, '', '', 'Returned device moved back to inspection',
      jsonb_build_object('refund_code', refund_row.refund_code, 'reason', refund_row.reason)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists pos_sales_refund_lines_return_used_device on public.pos_sales_refund_lines;
create trigger pos_sales_refund_lines_return_used_device
after insert or update of returned_quantity on public.pos_sales_refund_lines
for each row execute function public.return_refunded_pos_used_device();

-- Existing repair records can still receive comments/status updates. Any edit
-- to the intake fields, however, must leave a complete ticket.
create or replace function public.pos_repair_intake_is_complete(
  ticket_title text,
  ticket_issue text,
  ticket_customer_name text,
  ticket_customer_phone text,
  ticket_price text,
  ticket_intake jsonb
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select
    trim(coalesce(ticket_title, '')) <> ''
    and trim(coalesce(ticket_issue, '')) <> ''
    and trim(coalesce(ticket_customer_name, '')) <> ''
    and lower(trim(coalesce(ticket_customer_name, ''))) <> 'walk-in customer'
    and regexp_replace(coalesce(ticket_customer_phone, ''), '[^0-9]', '', 'g') ~ '^[0-9]{8,12}$'
    and case
      when btrim(coalesce(ticket_price, '')) ~ '^[$]?[0-9]+([.][0-9]{1,2})?$'
      then replace(btrim(ticket_price), '$', '')::numeric > 0
      else false
    end
    and coalesce(jsonb_typeof(coalesce(ticket_intake, '{}'::jsonb)->'quote'), '') = 'object'
    and trim(coalesce(ticket_intake#>>'{quote,brand}', '')) <> ''
    and trim(coalesce(ticket_intake#>>'{quote,model}', '')) <> ''
    and trim(coalesce(ticket_intake#>>'{quote,issue}', '')) <> ''
    and (
      (ticket_intake->>'deviceIdType' = 'imei'
        and regexp_replace(coalesce(ticket_intake->>'deviceImei', ''), '[^0-9]', '', 'g') ~ '^[0-9]{15}$')
      or (ticket_intake->>'deviceIdType' = 'sn' and trim(coalesce(ticket_intake->>'deviceSerial', '')) <> '')
      or (ticket_intake->>'deviceIdType' = 'none' and trim(coalesce(ticket_intake->>'deviceIdUnavailable', '')) <> '')
    )
    and (
      (ticket_intake->>'passwordType' = 'text' and trim(coalesce(ticket_intake->>'password', '')) <> '')
      or (ticket_intake->>'passwordType' = 'pattern' and trim(coalesce(ticket_intake->>'patternValue', '')) <> '')
      or (ticket_intake->>'passwordType' = 'none' and trim(coalesce(ticket_intake->>'passwordNoneReason', '')) <> '')
    )
    and (
      (ticket_intake->>'testable' = 'no' and trim(coalesce(ticket_intake->>'cannotTestReason', '')) <> '')
      or (
        ticket_intake->>'testable' = 'yes'
        and ticket_intake->>'testProfile' in ('mobile', 'computer')
        and coalesce(jsonb_typeof(ticket_intake->'tests'), '') = 'object'
        and ticket_intake->'tests' <> '{}'::jsonb
      )
    );
$$;

create or replace function public.enforce_complete_updated_pos_repair_ticket()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.pos_repair_intake_is_complete(
    new.title, new.issue, new.customer_name, new.customer_phone, new.price, new.intake
  ) then
    raise exception 'Repair ticket intake is incomplete';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_complete_updated_pos_repair_ticket_trigger
  on public.pos_repair_tickets;
create trigger enforce_complete_updated_pos_repair_ticket_trigger
before update of title, issue, customer_name, customer_phone, price, intake
on public.pos_repair_tickets
for each row execute function public.enforce_complete_updated_pos_repair_ticket();

create or replace function public.prevent_pos_record_store_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.store_id is distinct from old.store_id then
    raise exception 'The record store cannot be changed';
  end if;
  return new;
end;
$$;

drop trigger if exists pos_repair_ticket_store_immutable on public.pos_repair_tickets;
create trigger pos_repair_ticket_store_immutable
before update of store_id on public.pos_repair_tickets
for each row execute function public.prevent_pos_record_store_change();

drop trigger if exists pos_held_cart_store_immutable on public.pos_held_carts;
create trigger pos_held_cart_store_immutable
before update of store_id on public.pos_held_carts
for each row execute function public.prevent_pos_record_store_change();

drop trigger if exists pos_used_device_store_immutable on public.pos_used_devices;
create trigger pos_used_device_store_immutable
before update of store_id on public.pos_used_devices
for each row execute function public.prevent_pos_record_store_change();

drop trigger if exists pos_used_device_acquisition_store_immutable on public.pos_used_device_acquisitions;
create trigger pos_used_device_acquisition_store_immutable
before update of store_id on public.pos_used_device_acquisitions
for each row execute function public.prevent_pos_record_store_change();

create or replace function public.delete_pos_repair_ticket_for_store(
  session_token text,
  target_store_code text,
  target_ticket_code text,
  requested_staff_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_context jsonb;
begin
  actor_context := public.pos_authorized_actor(
    session_token, target_store_code, requested_staff_name
  );
  if not exists (
    select 1 from public.pos_repair_tickets repair_ticket
    where repair_ticket.ticket_code = coalesce(trim(target_ticket_code), '')
      and repair_ticket.store_id = nullif(actor_context->>'store_id', '')::bigint
      and repair_ticket.active = true
  ) then
    raise exception 'Repair ticket not found in the current store';
  end if;
  return public.delete_pos_repair_ticket(
    session_token,
    target_ticket_code,
    actor_context->>'staff_name'
  );
end;
$$;

-- Public/browser-callable functions are limited to scoped entry points. The
-- Edge Functions use the service role for the internal helpers after verifying
-- the same custom staff session and selected store.
revoke all on function public.pos_authorized_actor(text, text, text)
  from public, anon, authenticated;
revoke all on function public.pos_open_shift_context(text, text, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.pos_authorized_actor(text, text, text) to service_role;
grant execute on function public.pos_open_shift_context(text, text, text, text, boolean) to service_role;

revoke execute on function public.save_pos_sales_order(text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.add_pos_sales_order_payment(text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.refund_pos_sales_order(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.save_pos_sales_order(text, jsonb) to service_role;
grant execute on function public.add_pos_sales_order_payment(text, jsonb) to service_role;
grant execute on function public.refund_pos_sales_order(text, jsonb) to service_role;

revoke all on function public.save_pos_sales_order_for_store(text, jsonb)
  from public, anon, authenticated;
revoke all on function public.add_pos_sales_order_payment_for_store(text, jsonb)
  from public, anon, authenticated;
revoke all on function public.refund_pos_sales_order_for_store(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.save_pos_sales_order_for_store(text, jsonb)
  to anon, authenticated, service_role;
grant execute on function public.add_pos_sales_order_payment_for_store(text, jsonb)
  to anon, authenticated, service_role;
grant execute on function public.refund_pos_sales_order_for_store(text, jsonb)
  to anon, authenticated, service_role;

revoke execute on function public.get_pos_shift_payment_totals(text, text)
  from public, anon, authenticated;
revoke execute on function public.save_pos_shift_opening(text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.close_pos_store_shift(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.get_pos_shift_payment_totals(text, text) to service_role;
grant execute on function public.save_pos_shift_opening(text, jsonb) to service_role;
grant execute on function public.close_pos_store_shift(text, jsonb) to service_role;

revoke all on function public.get_pos_shift_payment_totals_for_store(text, text, text)
  from public, anon, authenticated;
revoke all on function public.save_pos_shift_opening_for_store(text, text, jsonb)
  from public, anon, authenticated;
revoke all on function public.close_pos_store_shift_for_store(text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.get_pos_shift_payment_totals_for_store(text, text, text)
  to anon, authenticated, service_role;
grant execute on function public.save_pos_shift_opening_for_store(text, text, jsonb)
  to anon, authenticated, service_role;
grant execute on function public.close_pos_store_shift_for_store(text, text, jsonb)
  to anon, authenticated, service_role;

revoke execute on function public.get_pos_store_shift(text, text)
  from public, anon, authenticated;
revoke execute on function public.open_pos_store_shift(text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.get_pos_held_carts(text, text)
  from public, anon, authenticated;
revoke execute on function public.save_pos_held_cart(text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.restore_pos_held_cart(text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.get_pos_store_shift(text, text) to service_role;
grant execute on function public.open_pos_store_shift(text, jsonb) to service_role;
grant execute on function public.get_pos_held_carts(text, text) to service_role;
grant execute on function public.save_pos_held_cart(text, jsonb) to service_role;
grant execute on function public.restore_pos_held_cart(text, text, text, text) to service_role;

revoke execute on function public.search_pos_customers(text, text, text, integer)
  from public, anon, authenticated;
revoke execute on function public.upsert_pos_customer(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.search_pos_customers(text, text, text, integer) to service_role;
grant execute on function public.upsert_pos_customer(text, jsonb) to service_role;

revoke execute on function public.search_pos_repair_tickets(text, text, text, integer)
  from public, anon, authenticated;
revoke execute on function public.upsert_pos_repair_ticket(text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.delete_pos_repair_ticket(text, text, text)
  from public, anon, authenticated;
grant execute on function public.search_pos_repair_tickets(text, text, text, integer) to service_role;
grant execute on function public.upsert_pos_repair_ticket(text, jsonb) to service_role;
grant execute on function public.delete_pos_repair_ticket(text, text, text) to service_role;
revoke all on function public.delete_pos_repair_ticket_for_store(text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.delete_pos_repair_ticket_for_store(text, text, text, text)
  to anon, authenticated, service_role;

revoke execute on function public.search_pos_used_devices(text, text, text, text, integer)
  from public, anon, authenticated;
revoke execute on function public.create_pos_used_device_acquisition(text, jsonb)
  from public, anon, authenticated;
revoke execute on function public.update_pos_used_device(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.search_pos_used_devices(text, text, text, text, integer) to service_role;
grant execute on function public.create_pos_used_device_acquisition(text, jsonb) to service_role;
grant execute on function public.update_pos_used_device(text, jsonb) to service_role;
revoke execute on function public.get_pos_used_device_transactions(text, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.get_pos_used_device_transactions(text, text, text, integer) to service_role;

revoke execute on function public.get_pos_sales_report(text, text, date, date, text)
  from public, anon, authenticated;
revoke execute on function public.get_pos_today_progress(text, text, text, date)
  from public, anon, authenticated;
revoke execute on function public.record_pos_google_review(text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.get_pos_sales_report(text, text, date, date, text) to service_role;
grant execute on function public.get_pos_today_progress(text, text, text, date) to service_role;
grant execute on function public.record_pos_google_review(text, text, text, text) to service_role;

revoke all on function public.pos_repair_intake_is_complete(text, text, text, text, text, jsonb)
  from public, anon, authenticated;
revoke all on function public.enforce_complete_updated_pos_repair_ticket()
  from public, anon, authenticated;
revoke all on function public.prevent_pos_record_store_change()
  from public, anon, authenticated;
revoke all on function public.prepare_pos_used_device_sale_line()
  from public, anon, authenticated;
revoke all on function public.return_refunded_pos_used_device()
  from public, anon, authenticated;

comment on function public.save_pos_sales_order_for_store(text, jsonb) is
  'Creates one POS invoice only for an assigned store and a cash-confirmed open shift.';
comment on column public.pos_sales_refund_lines.returned_quantity is
  'Physical units returned; drives idempotent product stock restoration.';
