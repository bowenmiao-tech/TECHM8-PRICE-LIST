-- A repair is reported on the Brisbane day its card first becomes ready for
-- pickup (or is closed directly). Added jobs have their own completion date.
-- POS invoices alone never create a completed-repair row.
create or replace function public.daily_report_completed_repair_suggestions(
  target_store_id bigint,
  target_date date
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with completed as (
    select
      'ticket:' || ticket.id::text as source_key,
      ticket.ticket_code,
      coalesce(ticket.ready_for_pickup_at, ticket.closed_at) as completed_at,
      coalesce(nullif(btrim(ticket.title), ''), ticket.ticket_code) as model_and_color,
      coalesce(nullif(btrim(ticket.issue), ''), 'Repair completed') as problem_and_parts_used,
      coalesce(ticket.updated_by, '') as tech_name,
      invoice.invoice_number,
      invoice.amount_today
    from public.pos_repair_tickets ticket
    left join lateral (
      select
        string_agg(sales_order.invoice_number::text, ', ' order by sales_order.invoice_number) as invoice_number,
        sum(sales_line.line_total) filter (
          where sales_order.business_date = target_date
            and sales_order.payment_status = 'paid'
        ) as amount_today
      from public.pos_sales_order_lines sales_line
      join public.pos_sales_orders sales_order on sales_order.id = sales_line.sales_order_id
      where sales_line.repair_ticket_id = ticket.id
        and sales_line.repair_job_id is null
        and sales_line.line_type = 'repair'
    ) invoice on true
    where ticket.store_id = target_store_id
      and ticket.card_kind = 'repair'
      and ticket.status in ('waiting_pickup', 'over_3_months_uncollected', 'closed')
      and (ticket.resolution is null or ticket.resolution in ('repaired', 'no_fault_found'))
      and (coalesce(ticket.ready_for_pickup_at, ticket.closed_at) at time zone 'Australia/Brisbane')::date = target_date

    union all

    select
      'job:' || job.id::text as source_key,
      ticket.ticket_code,
      job.completed_at,
      coalesce(nullif(btrim(ticket.title), ''), ticket.ticket_code),
      job.name,
      coalesce(job.completed_by, ''),
      invoice.invoice_number,
      invoice.amount_today
    from public.pos_repair_ticket_jobs job
    join public.pos_repair_tickets ticket on ticket.id = job.repair_ticket_id
    left join lateral (
      select
        string_agg(sales_order.invoice_number::text, ', ' order by sales_order.invoice_number) as invoice_number,
        sum(sales_line.line_total) filter (
          where sales_order.business_date = target_date
            and sales_order.payment_status = 'paid'
        ) as amount_today
      from public.pos_sales_order_lines sales_line
      join public.pos_sales_orders sales_order on sales_order.id = sales_line.sales_order_id
      where sales_line.repair_job_id = job.id
        and sales_line.line_type = 'repair'
    ) invoice on true
    where ticket.store_id = target_store_id
      and ticket.card_kind = 'repair'
      and job.status = 'completed'
      and (job.completed_at at time zone 'Australia/Brisbane')::date = target_date
  ), rows_with_signature as (
    select
      completed.*,
      md5(jsonb_build_array(
        completed.source_key,
        completed.completed_at,
        completed.model_and_color,
        completed.problem_and_parts_used,
        completed.tech_name,
        completed.invoice_number,
        completed.amount_today
      )::text) as source_signature
    from completed
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'source_key', source_key,
    'source_signature', source_signature,
    'ticket_code', ticket_code,
    'completed_at', completed_at,
    'model_and_color', model_and_color,
    'problem_and_parts_used', problem_and_parts_used,
    'tech_name', tech_name,
    'invoice_number', coalesce(invoice_number, ''),
    'amount', case when amount_today is null then '' else amount_today::text end
  ) order by completed_at, source_key), '[]'::jsonb)
  from rows_with_signature;
$$;

revoke all on function public.daily_report_completed_repair_suggestions(bigint, date)
  from public, anon, authenticated;
grant execute on function public.daily_report_completed_repair_suggestions(bigint, date)
  to service_role;

create or replace function public.get_daily_report_repair_suggestions(
  session_token text,
  target_store_code text,
  target_date date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_profile jsonb;
  session_staff public.staff_directory%rowtype;
  selected_store public.store_locations%rowtype;
  is_admin boolean := false;
  report_date_value date := coalesce(target_date, (now() at time zone 'Australia/Brisbane')::date);
begin
  session_profile := public.verify_staff_session(session_token);
  if not coalesce((session_profile->>'ok')::boolean, false) then
    raise exception 'Invalid session';
  end if;

  select * into session_staff
  from public.staff_directory staff
  where staff.id = nullif(session_profile->>'staff_id', '')::bigint
    and staff.active = true
  limit 1;
  if session_staff.id is null then raise exception 'Active staff account not found'; end if;

  is_admin := lower(btrim(coalesce(session_staff.email, ''))) = 'techm8contact@gmail.com';
  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse'
    and store_location.store_code = lower(btrim(coalesce(target_store_code, '')))
  limit 1;
  if selected_store.id is null then raise exception 'Store not found'; end if;
  if not is_admin and not public.staff_has_store_access(session_staff.id, selected_store.id) then
    raise exception 'This staff account is not assigned to the selected store';
  end if;

  return jsonb_build_object(
    'report_date', report_date_value,
    'repair_lines', public.daily_report_completed_repair_suggestions(selected_store.id, report_date_value)
  );
end;
$$;

revoke all on function public.get_daily_report_repair_suggestions(text, text, date)
  from public, anon, authenticated;
grant execute on function public.get_daily_report_repair_suggestions(text, text, date)
  to anon, authenticated, service_role;

-- Keep the existing staff/store checks and require an explicit confirmation
-- for every nonblank row. Recheck current completed work at submission time.
create or replace function public.submit_daily_report(
  session_token text,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_profile jsonb;
  session_staff public.staff_directory%rowtype;
  selected_store public.store_locations%rowtype;
  selected_staff public.staff_directory%rowtype;
  is_admin boolean := false;
  report_date_value date;
  repair_lines jsonb;
  suggestions jsonb;
  repair_line jsonb;
  suggestion jsonb;
  source_count integer;
begin
  session_profile := public.verify_staff_session(session_token);
  if not coalesce((session_profile->>'ok')::boolean, false) then
    raise exception 'Invalid session';
  end if;
  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Payload must be a JSON object';
  end if;

  select * into session_staff
  from public.staff_directory staff
  where staff.id = nullif(session_profile->>'staff_id', '')::bigint
    and staff.active = true
  limit 1;
  if session_staff.id is null then raise exception 'Active staff account not found'; end if;

  is_admin := lower(btrim(coalesce(session_staff.email, ''))) = 'techm8contact@gmail.com';
  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse'
    and store_location.store_code = lower(btrim(coalesce(payload->>'store_code', '')))
  limit 1;
  if selected_store.id is null then raise exception 'Store not found'; end if;
  if not is_admin and not public.staff_has_store_access(session_staff.id, selected_store.id) then
    raise exception 'This staff account is not assigned to the selected store';
  end if;

  select * into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and staff.display_name = btrim(coalesce(payload->>'staff_name', ''))
  limit 1;
  if selected_staff.id is null then raise exception 'Staff member not found'; end if;
  if not is_admin and selected_staff.id <> session_staff.id then
    raise exception 'Another staff member''s daily report is read-only';
  end if;

  report_date_value := coalesce(nullif(payload->>'report_date', '')::date,
    (now() at time zone 'Australia/Brisbane')::date);
  repair_lines := coalesce(payload->'repair_lines', '[]'::jsonb);
  if jsonb_typeof(repair_lines) <> 'array' then
    raise exception 'Repair rows must be an array';
  end if;
  suggestions := public.daily_report_completed_repair_suggestions(selected_store.id, report_date_value);

  for repair_line in select value from jsonb_array_elements(repair_lines) loop
    if jsonb_typeof(repair_line) <> 'object' then
      raise exception 'Invalid repair row';
    end if;
    if btrim(coalesce(repair_line->>'model_and_color', '')) <> ''
      or btrim(coalesce(repair_line->>'problem_and_parts_used', '')) <> ''
      or btrim(coalesce(repair_line->>'invoice_number', '')) <> ''
      or btrim(coalesce(repair_line->>'amount', '')) <> '' then
      if coalesce(repair_line->>'confirmed', 'false') <> 'true' then
        raise exception 'Confirm each repair row before submitting';
      end if;
    end if;
    if nullif(repair_line->>'source_key', '') is not null
      and not exists (
        select 1 from jsonb_array_elements(suggestions) item
        where item->>'source_key' = repair_line->>'source_key'
          and item->>'source_signature' = repair_line->>'source_signature'
      ) then
      raise exception 'A completed repair changed. Refresh and confirm it again';
    end if;
  end loop;

  for suggestion in select value from jsonb_array_elements(suggestions) loop
    select count(*) into source_count
    from jsonb_array_elements(repair_lines) item
    where item->>'source_key' = suggestion->>'source_key'
      and item->>'source_signature' = suggestion->>'source_signature'
      and item->>'confirmed' = 'true';
    if source_count <> 1 then
      raise exception 'Each completed repair must appear once and be confirmed';
    end if;
  end loop;

  return public.submit_daily_report_internal(payload, 'staff', false);
end;
$$;
