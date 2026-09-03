-- Final multi-job repair workflow.
--
-- Payment and repair-card completion are intentionally separate. A successful
-- payment leaves every card open until an authenticated staff member makes an
-- explicit per-card decision. This is the safe fallback if a browser closes or
-- loses its connection immediately after payment.

-- 1. One base line and one line per added job, each billable exactly once.
drop index if exists public.pos_sales_order_lines_repair_ticket_unique;
create unique index if not exists pos_sales_order_lines_repair_ticket_base_unique
  on public.pos_sales_order_lines (repair_ticket_id)
  where repair_ticket_id is not null and repair_job_id is null;

drop index if exists public.pos_sales_order_lines_repair_job_idx;
create unique index pos_sales_order_lines_repair_job_idx
  on public.pos_sales_order_lines (repair_job_id)
  where repair_job_id is not null;

-- 2. Added work has its own operational and approval lifecycle.
alter table public.pos_repair_ticket_jobs
  add column if not exists status text not null default 'proposed',
  add column if not exists approval_method text,
  add column if not exists approved_by_customer text,
  add column if not exists approved_by_staff text,
  add column if not exists approved_at timestamptz,
  add column if not exists completed_by text,
  add column if not exists completed_at timestamptz,
  add column if not exists sort_order integer not null default 100;

alter table public.pos_repair_ticket_jobs
  drop constraint if exists pos_repair_ticket_jobs_status_check,
  drop constraint if exists pos_repair_ticket_jobs_approval_method_check,
  add constraint pos_repair_ticket_jobs_status_check
    check (status in ('proposed', 'approved', 'in_progress', 'completed', 'cancelled')),
  add constraint pos_repair_ticket_jobs_approval_method_check
    check (approval_method is null or approval_method in ('in_person', 'phone', 'sms', 'email', 'signature'));

create index if not exists pos_repair_ticket_jobs_open_idx
  on public.pos_repair_ticket_jobs (repair_ticket_id, status, sort_order)
  where status <> 'cancelled';

-- A proposed or cancelled job must never be billed even if a stale browser
-- submits it. The unique indexes above handle concurrent duplicate checkout.
create or replace function public.validate_pos_repair_job_invoice_line()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  job_row public.pos_repair_ticket_jobs%rowtype;
begin
  if new.repair_job_id is null then return new; end if;

  select * into job_row
  from public.pos_repair_ticket_jobs job
  where job.id = new.repair_job_id
  for share;

  if not found then raise exception 'Repair job not found'; end if;
  if new.repair_ticket_id is distinct from job_row.repair_ticket_id then
    raise exception 'Repair job does not belong to this repair card';
  end if;
  if job_row.status not in ('approved', 'in_progress', 'completed') then
    raise exception 'Repair job must be approved before checkout';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_pos_repair_job_invoice_line on public.pos_sales_order_lines;
create trigger validate_pos_repair_job_invoice_line
before insert or update of repair_job_id, repair_ticket_id
on public.pos_sales_order_lines
for each row execute function public.validate_pos_repair_job_invoice_line();

revoke all on function public.validate_pos_repair_job_invoice_line() from public, anon, authenticated;

-- 3. Saving a paid invoice records the billing event but never closes a card.
-- The boolean overload remains for compatibility with the already-deployed
-- checkout function; should_close is deliberately ignored here.
create or replace function public.close_pos_repair_tickets_for_order(
  target_order_id bigint,
  acting_staff_name text,
  target_invoice_number bigint,
  target_customer_name text,
  target_customer_phone text,
  should_close boolean
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
    updated_by = acting_staff_name,
    updated_at = now(),
    activity = jsonb_build_array(jsonb_build_object(
      'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'type', 'paid',
      'text', 'billed work on invoice #' || target_invoice_number || ' and left the repair card open',
      'staffName', acting_staff_name,
      'at', now()
    )) || coalesce(repair_ticket.activity, '[]'::jsonb)
  where repair_ticket.id in (
    select distinct sales_line.repair_ticket_id
    from public.pos_sales_order_lines sales_line
    where sales_line.sales_order_id = target_order_id
      and sales_line.repair_ticket_id is not null
  )
    and repair_ticket.closed_at is null;
end;
$$;

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
  perform public.close_pos_repair_tickets_for_order(
    target_order_id,
    acting_staff_name,
    target_invoice_number,
    target_customer_name,
    target_customer_phone,
    false
  );
end;
$$;

revoke all on function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text, boolean)
  from public, anon, authenticated;
revoke all on function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text)
  from public, anon, authenticated;
grant execute on function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text, boolean)
  to service_role;
grant execute on function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text)
  to service_role;

-- 4. Return every job, its approval state and every invoice linked to the card.
create or replace function public.pos_repair_ticket_payload(ticket_row public.pos_repair_tickets)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', ticket_row.ticket_code,
    'ticket_code', ticket_row.ticket_code,
    'store_id', stores.store_code,
    'storeId', stores.store_code,
    'store_code', stores.store_code,
    'storeCode', stores.store_code,
    'store_name', stores.store_name,
    'title', ticket_row.title,
    'issue', ticket_row.issue,
    'price', ticket_row.price,
    'status', ticket_row.status,
    'deviceInStore', ticket_row.device_in_store,
    'motherboardRepair', ticket_row.motherboard_repair,
    'specialOrder', ticket_row.special_order,
    'customerName', ticket_row.customer_name,
    'customerPhone', ticket_row.customer_phone,
    'customerContact', ticket_row.customer_phone,
    'resolution', ticket_row.resolution,
    'readyForPickupAt', ticket_row.ready_for_pickup_at,
    'closedAt', ticket_row.closed_at,
    'paymentStatus', case
      when invoice_summary.balance_due > 0 then 'deposit'
      when invoice_summary.invoice_count > 0 then 'paid'
      else 'unpaid'
    end,
    'invoiceOrderId', base_invoice.order_code,
    'invoiceNumber', base_invoice.invoice_number,
    'salesOrderLineId', base_invoice.sales_order_line_id,
    'orderTotal', base_invoice.order_total,
    'depositPaid', base_invoice.amount_paid,
    'balanceDue', invoice_summary.balance_due,
    'baseInvoiced', base_invoice.sales_order_line_id is not null,
    'basePrice', base_price.amount,
    'baseJobName', coalesce(nullif(btrim(ticket_row.issue), ''), 'Repair service'),
    'jobs', jobs.rows,
    'invoiceHistory', invoice_summary.rows,
    'unbilledTotal', round(
      case when base_invoice.sales_order_line_id is null then base_price.amount else 0 end
      + jobs.unbilled_total, 2),
    'outstandingTotal', round(
      invoice_summary.balance_due
      + case when base_invoice.sales_order_line_id is null then base_price.amount else 0 end
      + jobs.unbilled_total, 2),
    'hasUnfinishedJobs', jobs.unfinished_count > 0,
    'canClose', base_invoice.sales_order_line_id is not null
      and jobs.unbilled_count = 0
      and jobs.unfinished_count = 0
      and invoice_summary.balance_due = 0,
    'createdBy', ticket_row.created_by,
    'updatedBy', ticket_row.updated_by,
    'createdAt', ticket_row.created_at,
    'updatedAt', ticket_row.updated_at,
    'statusUpdatedAt', ticket_row.status_updated_at,
    'intake', ticket_row.intake,
    'activity', ticket_row.activity,
    'comments', ticket_row.comments
  )
  from public.store_locations stores
  cross join lateral (
    select case
      when btrim(coalesce(ticket_row.price, '')) ~ '^[$]?[0-9]+([.][0-9]{1,2})?$'
        then replace(btrim(ticket_row.price), '$', '')::numeric
      else 0
    end as amount
  ) base_price
  left join lateral (
    select
      sales_line.id as sales_order_line_id,
      sales_order.order_code,
      sales_order.invoice_number,
      sales_order.total as order_total,
      sales_order.amount_paid
    from public.pos_sales_order_lines sales_line
    join public.pos_sales_orders sales_order on sales_order.id = sales_line.sales_order_id
    where sales_line.repair_ticket_id = ticket_row.id
      and sales_line.repair_job_id is null
    order by sales_order.created_at
    limit 1
  ) base_invoice on true
  cross join lateral (
    select
      coalesce(jsonb_agg(jsonb_build_object(
        'id', job.job_code,
        'jobCode', job.job_code,
        'name', job.name,
        'price', job.price,
        'note', job.note,
        'status', job.status,
        'approvalMethod', job.approval_method,
        'approvedByCustomer', job.approved_by_customer,
        'approvedByStaff', job.approved_by_staff,
        'approvedAt', job.approved_at,
        'completedBy', job.completed_by,
        'completedAt', job.completed_at,
        'invoiced', billed.sales_order_line_id is not null,
        'invoiceOrderId', billed.order_code,
        'invoiceNumber', billed.invoice_number,
        'createdBy', job.created_by,
        'createdAt', job.created_at,
        'updatedBy', job.updated_by,
        'updatedAt', job.updated_at
      ) order by job.sort_order, job.created_at, job.id), '[]'::jsonb) as rows,
      coalesce(sum(job.price) filter (
        where job.status <> 'cancelled' and billed.sales_order_line_id is null
      ), 0) as unbilled_total,
      count(*) filter (
        where job.status <> 'cancelled' and billed.sales_order_line_id is null
      ) as unbilled_count,
      count(*) filter (where job.status not in ('completed', 'cancelled')) as unfinished_count
    from public.pos_repair_ticket_jobs job
    left join lateral (
      select sales_line.id as sales_order_line_id, sales_order.order_code, sales_order.invoice_number
      from public.pos_sales_order_lines sales_line
      join public.pos_sales_orders sales_order on sales_order.id = sales_line.sales_order_id
      where sales_line.repair_job_id = job.id
      limit 1
    ) billed on true
    where job.repair_ticket_id = ticket_row.id
  ) jobs
  cross join lateral (
    select
      coalesce(jsonb_agg(jsonb_build_object(
        'orderId', linked.order_code,
        'invoiceNumber', linked.invoice_number,
        'paymentStatus', linked.payment_status,
        'total', linked.total,
        'amountPaid', linked.amount_paid,
        'balanceDue', linked.balance_due,
        'createdAt', linked.created_at,
        'lines', linked.lines
      ) order by linked.created_at desc), '[]'::jsonb) as rows,
      coalesce(sum(linked.balance_due), 0) as balance_due,
      count(*) as invoice_count
    from (
      select
        sales_order.id,
        sales_order.order_code,
        sales_order.invoice_number,
        sales_order.payment_status,
        sales_order.total,
        sales_order.amount_paid,
        round(greatest(sales_order.total - sales_order.amount_paid, 0), 2) as balance_due,
        sales_order.created_at,
        (
          select coalesce(jsonb_agg(jsonb_build_object(
            'name', ticket_line.name,
            'amount', ticket_line.line_total,
            'repairJobId', repair_job.job_code
          ) order by ticket_line.line_number), '[]'::jsonb)
          from public.pos_sales_order_lines ticket_line
          left join public.pos_repair_ticket_jobs repair_job on repair_job.id = ticket_line.repair_job_id
          where ticket_line.sales_order_id = sales_order.id
            and ticket_line.repair_ticket_id = ticket_row.id
        ) as lines
      from public.pos_sales_orders sales_order
      where exists (
        select 1
        from public.pos_sales_order_lines sales_line
        where sales_line.sales_order_id = sales_order.id
          and sales_line.repair_ticket_id = ticket_row.id
      )
    ) linked
  ) invoice_summary
  where stores.id = ticket_row.store_id;
$$;

-- 5. Authenticated add/update operations with approval and completion audit.
create or replace function public.add_pos_repair_ticket_job(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  inserted public.pos_repair_ticket_jobs%rowtype;
  job_name text := btrim(coalesce(payload->>'name', ''));
  job_note text := btrim(coalesce(payload->>'note', ''));
  raw_price text := btrim(coalesce(payload->>'price', ''));
  job_status text := coalesce(nullif(btrim(payload->>'status'), ''), 'proposed');
  approval text := nullif(btrim(payload->>'approval_method'), '');
  price_value numeric(12,2);
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Job payload must be an object'; end if;
  actor := public.pos_authorized_actor(session_token, coalesce(payload->>'store_code', payload->>'store_id'), payload->>'staff_name');

  select * into ticket_row
  from public.pos_repair_tickets
  where ticket_code = coalesce(btrim(payload->>'ticket_code'), '')
  for update;
  if not found then raise exception 'Repair ticket not found'; end if;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then raise exception 'Repair ticket belongs to another store'; end if;
  if ticket_row.closed_at is not null then raise exception 'This repair card is closed. Start a new repair instead.'; end if;
  if not ticket_row.active then raise exception 'Repair ticket is not active'; end if;

  if job_name = '' or length(job_name) > 160 then raise exception 'Repair name is required and must be under 160 characters'; end if;
  if length(job_note) > 500 then raise exception 'Repair note cannot exceed 500 characters'; end if;
  if raw_price !~ '^[$]?[0-9]+([.][0-9]{1,2})?$' then raise exception 'Repair price must be one numeric amount'; end if;
  price_value := replace(raw_price, '$', '')::numeric;
  if price_value <= 0 or price_value > 1000000 then raise exception 'Repair price must be between 0.01 and 1000000.00'; end if;
  if job_status not in ('proposed', 'approved', 'in_progress', 'completed', 'cancelled') then raise exception 'Invalid repair status'; end if;
  if approval is not null and approval not in ('in_person', 'phone', 'sms', 'email', 'signature') then raise exception 'Invalid approval method'; end if;
  if job_status in ('approved', 'in_progress', 'completed') and approval is null then raise exception 'Customer approval is required before repair or checkout'; end if;

  insert into public.pos_repair_ticket_jobs (
    job_code, repair_ticket_id, name, price, note, status, approval_method,
    approved_by_customer, approved_by_staff, approved_at, completed_by,
    completed_at, sort_order, created_by, updated_by
  ) values (
    'RJB-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint || '-' || substr(md5(random()::text), 1, 6),
    ticket_row.id, job_name, price_value, job_note, job_status, approval,
    case when approval is not null then ticket_row.customer_name end,
    case when approval is not null then actor->>'staff_name' end,
    case when approval is not null then now() end,
    case when job_status = 'completed' then actor->>'staff_name' end,
    case when job_status = 'completed' then now() end,
    coalesce((select max(job.sort_order) + 10 from public.pos_repair_ticket_jobs job where job.repair_ticket_id = ticket_row.id), 100),
    actor->>'staff_name', actor->>'staff_name'
  ) returning * into inserted;

  update public.pos_repair_tickets
  set activity = jsonb_build_array(jsonb_build_object(
        'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
        'type', 'job',
        'text', 'added repair: ' || job_name || ' ($' || to_char(price_value, 'FM999999990.00') || ') - ' || replace(job_status, '_', ' '),
        'staffName', actor->>'staff_name',
        'at', now()
      )) || coalesce(activity, '[]'::jsonb),
      updated_by = actor->>'staff_name', updated_at = now()
  where id = ticket_row.id;

  select * into ticket_row from public.pos_repair_tickets where id = ticket_row.id;
  return jsonb_build_object('ok', true, 'job_code', inserted.job_code, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;

create or replace function public.update_pos_repair_ticket_job(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  job_row public.pos_repair_ticket_jobs%rowtype;
  job_name text := btrim(coalesce(payload->>'name', ''));
  job_note text := btrim(coalesce(payload->>'note', ''));
  raw_price text := btrim(coalesce(payload->>'price', ''));
  job_status text := coalesce(nullif(btrim(payload->>'status'), ''), 'proposed');
  approval text := nullif(btrim(payload->>'approval_method'), '');
  price_value numeric(12,2);
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Job payload must be an object'; end if;
  actor := public.pos_authorized_actor(session_token, coalesce(payload->>'store_code', payload->>'store_id'), payload->>'staff_name');

  select * into job_row
  from public.pos_repair_ticket_jobs
  where job_code = coalesce(btrim(payload->>'job_code'), '')
  for update;
  if not found then raise exception 'Repair job not found'; end if;

  select * into ticket_row from public.pos_repair_tickets where id = job_row.repair_ticket_id for update;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then raise exception 'Repair ticket belongs to another store'; end if;
  if ticket_row.closed_at is not null then raise exception 'This repair card is closed.'; end if;
  if exists (select 1 from public.pos_sales_order_lines where repair_job_id = job_row.id) then
    raise exception 'This repair has already been invoiced and cannot be changed.';
  end if;

  if job_name = '' or length(job_name) > 160 then raise exception 'Repair name is required and must be under 160 characters'; end if;
  if length(job_note) > 500 then raise exception 'Repair note cannot exceed 500 characters'; end if;
  if raw_price !~ '^[$]?[0-9]+([.][0-9]{1,2})?$' then raise exception 'Repair price must be one numeric amount'; end if;
  price_value := replace(raw_price, '$', '')::numeric;
  if price_value <= 0 or price_value > 1000000 then raise exception 'Repair price must be between 0.01 and 1000000.00'; end if;
  if job_status not in ('proposed', 'approved', 'in_progress', 'completed', 'cancelled') then raise exception 'Invalid repair status'; end if;
  if approval is not null and approval not in ('in_person', 'phone', 'sms', 'email', 'signature') then raise exception 'Invalid approval method'; end if;
  if job_status in ('approved', 'in_progress', 'completed') and approval is null then raise exception 'Customer approval is required before repair or checkout'; end if;

  update public.pos_repair_ticket_jobs
  set
    name = job_name,
    price = price_value,
    note = job_note,
    status = job_status,
    approval_method = approval,
    approved_by_customer = case when approval is not null then ticket_row.customer_name else null end,
    approved_by_staff = case when approval is not null then coalesce(job_row.approved_by_staff, actor->>'staff_name') else null end,
    approved_at = case when approval is not null then coalesce(job_row.approved_at, now()) else null end,
    completed_by = case when job_status = 'completed' then coalesce(job_row.completed_by, actor->>'staff_name') else null end,
    completed_at = case when job_status = 'completed' then coalesce(job_row.completed_at, now()) else null end,
    updated_by = actor->>'staff_name',
    updated_at = now()
  where id = job_row.id;

  update public.pos_repair_tickets
  set activity = jsonb_build_array(jsonb_build_object(
        'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
        'type', 'job',
        'text', 'updated repair: ' || job_name || ' ($' || to_char(price_value, 'FM999999990.00') || ') - ' || replace(job_status, '_', ' '),
        'staffName', actor->>'staff_name',
        'at', now()
      )) || coalesce(activity, '[]'::jsonb),
      updated_by = actor->>'staff_name', updated_at = now()
  where id = ticket_row.id;

  select * into ticket_row from public.pos_repair_tickets where id = ticket_row.id;
  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;

-- 6. Explicit per-card decision made only after a paid invoice exists.
alter table public.pos_repair_tickets
  drop constraint if exists pos_repair_tickets_resolution_check;
alter table public.pos_repair_tickets
  add constraint pos_repair_tickets_resolution_check
  check (resolution is null or resolution in (
    'repaired', 'no_fault_found', 'customer_declined', 'unrepairable',
    'cancelled', 'returned_unrepaired', 'referred'
  ));

create or replace function public.finalize_pos_repair_ticket_after_checkout(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  order_row public.pos_sales_orders%rowtype;
  decision text := lower(btrim(coalesce(payload->>'decision', '')));
  next_status text := coalesce(nullif(lower(btrim(payload->>'next_status')), ''), 'repairing');
  result_value text := coalesce(nullif(lower(btrim(payload->>'resolution')), ''), 'repaired');
  unbilled_count integer;
  unfinished_count integer;
  open_balance_count integer;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Payload must be an object'; end if;
  actor := public.pos_authorized_actor(session_token, coalesce(payload->>'store_code', payload->>'store_id'), payload->>'staff_name');

  select * into ticket_row
  from public.pos_repair_tickets ticket
  where ticket.ticket_code = coalesce(btrim(payload->>'ticket_code'), '')
  for update;
  if not found then raise exception 'Repair ticket not found'; end if;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then raise exception 'Repair ticket belongs to another store'; end if;

  select * into order_row
  from public.pos_sales_orders sales_order
  where sales_order.order_code = coalesce(btrim(payload->>'order_code'), '')
    and sales_order.store_id = ticket_row.store_id;
  if not found then raise exception 'Paid invoice not found'; end if;
  if order_row.payment_status <> 'paid' or round(order_row.amount_paid, 2) < round(order_row.total, 2) then
    raise exception 'Repair card cannot be completed before full payment';
  end if;
  if not exists (
    select 1 from public.pos_sales_order_lines sales_line
    where sales_line.sales_order_id = order_row.id
      and sales_line.repair_ticket_id = ticket_row.id
  ) then raise exception 'Invoice does not belong to this repair card'; end if;

  if decision = 'keep' then
    if ticket_row.closed_at is not null then raise exception 'This repair card is already closed'; end if;
    if next_status not in ('need_to_order', 'waiting_shipping', 'repairing', 'waiting_pickup', 'waiting_customer_confirmation', 'over_3_months_uncollected') then
      raise exception 'Invalid next repair status';
    end if;

    update public.pos_repair_tickets
    set status = next_status,
        resolution = null,
        closed_at = null,
        ready_for_pickup_at = case when next_status in ('waiting_pickup', 'over_3_months_uncollected') then now() else null end,
        updated_by = actor->>'staff_name',
        status_updated_at = now(),
        updated_at = now(),
        activity = jsonb_build_array(jsonb_build_object(
          'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
          'type', 'status',
          'text', 'kept this card open after invoice #' || order_row.invoice_number || ' in ' || replace(next_status, '_', ' '),
          'staffName', actor->>'staff_name',
          'at', now()
        )) || coalesce(activity, '[]'::jsonb)
    where id = ticket_row.id;
  elsif decision = 'finish' then
    if ticket_row.closed_at is not null then
      return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
    end if;
    if result_value not in ('repaired', 'no_fault_found', 'customer_declined', 'unrepairable', 'cancelled', 'returned_unrepaired', 'referred') then
      raise exception 'Invalid repair outcome';
    end if;

    select count(*) into unbilled_count
    from (
      select 1
      where not exists (
        select 1 from public.pos_sales_order_lines sales_line
        where sales_line.repair_ticket_id = ticket_row.id and sales_line.repair_job_id is null
      )
      union all
      select 1
      from public.pos_repair_ticket_jobs job
      where job.repair_ticket_id = ticket_row.id
        and job.status <> 'cancelled'
        and not exists (select 1 from public.pos_sales_order_lines sales_line where sales_line.repair_job_id = job.id)
    ) missing;

    select count(*) into unfinished_count
    from public.pos_repair_ticket_jobs job
    where job.repair_ticket_id = ticket_row.id
      and job.status not in ('completed', 'cancelled');

    select count(distinct sales_order.id) into open_balance_count
    from public.pos_sales_orders sales_order
    join public.pos_sales_order_lines sales_line on sales_line.sales_order_id = sales_order.id
    where sales_line.repair_ticket_id = ticket_row.id
      and round(sales_order.amount_paid, 2) < round(sales_order.total, 2);

    if unbilled_count > 0 then raise exception 'Unbilled repair work remains on this card'; end if;
    if unfinished_count > 0 then raise exception 'Repair work must be completed or cancelled before closing this card'; end if;
    if open_balance_count > 0 then raise exception 'An invoice balance is still owing on this card'; end if;

    update public.pos_repair_tickets
    set status = 'waiting_pickup',
        resolution = result_value,
        ready_for_pickup_at = coalesce(ready_for_pickup_at, now()),
        closed_at = now(),
        updated_by = actor->>'staff_name',
        status_updated_at = now(),
        updated_at = now(),
        activity = jsonb_build_array(jsonb_build_object(
          'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
          'type', 'finished',
          'text', 'finished this repair card after invoice #' || order_row.invoice_number || ' - ' || replace(result_value, '_', ' '),
          'staffName', actor->>'staff_name',
          'at', now()
        )) || coalesce(activity, '[]'::jsonb)
    where id = ticket_row.id;
  else
    raise exception 'Decision must be keep or finish';
  end if;

  select * into ticket_row from public.pos_repair_tickets where id = ticket_row.id;
  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;

revoke all on function public.add_pos_repair_ticket_job(text, jsonb) from public, anon, authenticated;
revoke all on function public.update_pos_repair_ticket_job(text, jsonb) from public, anon, authenticated;
revoke all on function public.delete_pos_repair_ticket_job(text, jsonb) from public, anon, authenticated;
revoke all on function public.finalize_pos_repair_ticket_after_checkout(text, jsonb) from public, anon, authenticated;
grant execute on function public.add_pos_repair_ticket_job(text, jsonb) to service_role;
grant execute on function public.update_pos_repair_ticket_job(text, jsonb) to service_role;
grant execute on function public.delete_pos_repair_ticket_job(text, jsonb) to service_role;
grant execute on function public.finalize_pos_repair_ticket_after_checkout(text, jsonb) to service_role;

comment on function public.finalize_pos_repair_ticket_after_checkout(text, jsonb) is
  'Authenticated post-payment decision for one repair card. Payment never closes cards automatically.';
