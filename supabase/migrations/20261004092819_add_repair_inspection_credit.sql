-- Keep the repair's quoted price while applying the original inspection fee
-- once. The invoice line records the net amount; its payload records the gross
-- repair price, credit, and the inspection invoice that supplied the credit.
alter table public.pos_repair_ticket_jobs
  add column inspection_credit numeric(12,2) not null default 0;

alter table public.pos_repair_ticket_jobs
  add constraint pos_repair_ticket_jobs_inspection_credit_check
  check (inspection_credit >= 0 and inspection_credit <= price);

create unique index pos_repair_ticket_one_inspection_credit
  on public.pos_repair_ticket_jobs (repair_ticket_id)
  where inspection_credit > 0 and status <> 'cancelled';

create or replace function public.pos_validate_repair_inspection_credit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  ticket_row public.pos_repair_tickets%rowtype;
  inspection_price numeric(12,2);
begin
  if new.inspection_credit = 0 then return new; end if;
  select * into ticket_row from public.pos_repair_tickets where id = new.repair_ticket_id;
  if not found then raise exception 'Repair card not found'; end if;
  if coalesce(ticket_row.issue, '') !~* '(inspection|diagnos|check)' then
    raise exception 'The original repair on this card must be an inspection';
  end if;
  inspection_price := replace(ticket_row.price, '$', '')::numeric;
  if new.inspection_credit > inspection_price then
    raise exception 'Inspection credit cannot exceed the inspection price';
  end if;
  return new;
end;
$$;

create trigger pos_repair_ticket_jobs_inspection_credit_guard
before insert or update of price, inspection_credit, repair_ticket_id
on public.pos_repair_ticket_jobs
for each row execute function public.pos_validate_repair_inspection_credit();

-- Extend the card's existing payload without changing its legacy import logic.
do $migration$
declare
  definition text;
  patched text;
begin
  select pg_get_functiondef(p.oid) into definition
  from pg_proc p
  where p.proname = 'pos_repair_ticket_payload'
    and p.pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'pos_repair_ticket_payload not found'; end if;
  if position('inspectionCredit' in definition) > 0 then raise exception 'Credit payload is already installed'; end if;
  if position('''price'', job.price,' in definition) = 0
    or position('sum(job.price) filter' in definition) = 0
    or position('''amount'', ticket_line.line_total,' in definition) = 0 then
    raise exception 'Repair payload has changed; review credit migration';
  end if;
  patched := replace(definition, '''price'', job.price,',
    '''price'', job.price, ''inspectionCredit'', job.inspection_credit,');
  patched := replace(patched, 'sum(job.price) filter',
    'sum(job.price - job.inspection_credit) filter');
  patched := replace(patched, '''amount'', ticket_line.line_total,',
    '''amount'', ticket_line.line_total, ''grossPrice'', coalesce(repair_job.price, ticket_line.line_total), ''inspectionCredit'', coalesce(repair_job.inspection_credit, 0),');
  execute patched;
end
$migration$;

do $migration$
declare
  definition text;
begin
  definition := pg_get_functiondef('public.get_admin_repair_follow_up(text)'::regprocedure);
  if position('''price'', job.price' in definition) = 0 then
    raise exception 'Admin repair report has changed; review credit migration';
  end if;
  execute replace(definition, '''price'', job.price',
    '''price'', job.price, ''inspection_credit'', job.inspection_credit');
end
$migration$;

-- Existing add/update rules still own approval, status, audit, and price
-- validation. Wrap them so a credit and its job are saved atomically.
alter function public.add_pos_repair_ticket_job(text,jsonb)
  rename to add_pos_repair_ticket_job_before_inspection_credit;
alter function public.update_pos_repair_ticket_job(text,jsonb)
  rename to update_pos_repair_ticket_job_before_inspection_credit;

create function public.add_pos_repair_ticket_job(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
  credit numeric(12,2);
  raw_credit text := btrim(coalesce(payload->>'inspection_credit', '0'));
  job_row public.pos_repair_ticket_jobs%rowtype;
  ticket_row public.pos_repair_tickets%rowtype;
begin
  if raw_credit !~ '^[0-9]+([.][0-9]{1,2})?$' then
    raise exception 'Inspection credit must be a valid amount';
  end if;
  credit := raw_credit::numeric;
  result := public.add_pos_repair_ticket_job_before_inspection_credit(session_token, payload);
  select * into job_row from public.pos_repair_ticket_jobs
  where job_code = result->>'job_code' for update;
  if credit > 0 then
    update public.pos_repair_ticket_jobs set inspection_credit = credit where id = job_row.id;
    update public.pos_repair_tickets
    set activity = jsonb_build_array(jsonb_build_object(
      'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'type', 'job',
      'text', 'applied inspection credit $' || to_char(credit, 'FM999999990.00') || ' to ' || job_row.name,
      'staffName', job_row.created_by, 'at', now()
    )) || coalesce(activity, '[]'::jsonb)
    where id = job_row.repair_ticket_id;
  end if;
  select * into ticket_row from public.pos_repair_tickets where id = job_row.repair_ticket_id;
  return jsonb_build_object('ok', true, 'job_code', job_row.job_code,
    'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;

create function public.update_pos_repair_ticket_job(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
  raw_credit text;
  credit numeric(12,2);
  old_credit numeric(12,2);
  job_row public.pos_repair_ticket_jobs%rowtype;
  ticket_row public.pos_repair_tickets%rowtype;
begin
  select * into job_row from public.pos_repair_ticket_jobs
  where job_code = btrim(coalesce(payload->>'job_code', '')) for update;
  if not found then raise exception 'Repair job not found'; end if;
  old_credit := job_row.inspection_credit;
  raw_credit := btrim(coalesce(payload->>'inspection_credit', old_credit::text));
  if raw_credit !~ '^[0-9]+([.][0-9]{1,2})?$' then
    raise exception 'Inspection credit must be a valid amount';
  end if;
  credit := raw_credit::numeric;
  if credit < old_credit then
    update public.pos_repair_ticket_jobs set inspection_credit = credit where id = job_row.id;
  end if;
  result := public.update_pos_repair_ticket_job_before_inspection_credit(session_token, payload);
  if credit > old_credit then
    update public.pos_repair_ticket_jobs set inspection_credit = credit where id = job_row.id;
  end if;
  if credit is distinct from old_credit then
    update public.pos_repair_tickets
    set activity = jsonb_build_array(jsonb_build_object(
      'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'type', 'job',
      'text', case when credit = 0 then 'removed inspection credit from ' || job_row.name
        else 'set inspection credit to $' || to_char(credit, 'FM999999990.00') || ' for ' || job_row.name end,
      'staffName', coalesce(payload->>'staff_name', job_row.updated_by), 'at', now()
    )) || coalesce(activity, '[]'::jsonb)
    where id = job_row.repair_ticket_id;
  end if;
  select * into ticket_row from public.pos_repair_tickets where id = job_row.repair_ticket_id;
  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;

revoke all on function public.add_pos_repair_ticket_job(text,jsonb) from public, anon, authenticated;
revoke all on function public.update_pos_repair_ticket_job(text,jsonb) from public, anon, authenticated;
grant execute on function public.add_pos_repair_ticket_job(text,jsonb) to service_role;
grant execute on function public.update_pos_repair_ticket_job(text,jsonb) to service_role;
revoke all on function public.add_pos_repair_ticket_job_before_inspection_credit(text,jsonb) from public, anon, authenticated;
revoke all on function public.update_pos_repair_ticket_job_before_inspection_credit(text,jsonb) from public, anon, authenticated;

-- Both positive and zero-dollar checkouts pass through this entry point.
-- Check the source and the net amount before delegating to the existing
-- invoice writer. A client cannot invent or reuse an inspection credit.
alter function public.save_pos_sales_order(text,jsonb)
  rename to save_pos_sales_order_before_inspection_credit;

create function public.save_pos_sales_order(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  item_index integer;
  normalized jsonb := payload;
  job_row public.pos_repair_ticket_jobs%rowtype;
  ticket_row public.pos_repair_tickets%rowtype;
  source_line public.pos_sales_order_lines%rowtype;
  source_invoice public.pos_sales_orders%rowtype;
  credit_source jsonb;
  net_price numeric(12,2);
  same_invoice_base_count integer;
  refunded_amount numeric(12,2);
begin
  if jsonb_typeof(payload) <> 'object' or jsonb_typeof(payload->'items') <> 'array' then
    return public.save_pos_sales_order_before_inspection_credit(session_token, payload);
  end if;

  for item, item_index in
    select value, (ordinality - 1)::integer
    from jsonb_array_elements(payload->'items') with ordinality
  loop
    if coalesce(item->>'repair_job_id', '') = '' then continue; end if;
    select * into job_row from public.pos_repair_ticket_jobs
      where job_code = item->>'repair_job_id';
    if not found or job_row.inspection_credit <= 0 then
      if item ? 'inspection_credit' then
        raise exception 'This repair has no inspection credit';
      end if;
      continue;
    end if;
    select * into ticket_row from public.pos_repair_tickets
      where id = job_row.repair_ticket_id for update;
    select * into job_row from public.pos_repair_ticket_jobs
      where id = job_row.id;
    if coalesce(item->>'ticket_id', '') <> ticket_row.ticket_code
      or lower(coalesce(item->>'is_repair', 'false')) <> 'true' then
      raise exception 'Inspection credit must belong to this repair card';
    end if;
    if coalesce(nullif(item->>'qty', '')::integer, 1) <> 1 then
      raise exception 'A credited repair must have quantity one';
    end if;
    net_price := job_row.price - job_row.inspection_credit;
    if round(coalesce(nullif(item->>'unit_price', '')::numeric, -1), 2) <> net_price
      or round(coalesce(nullif(item->>'line_total', '')::numeric, -1), 2) <> net_price then
      raise exception 'Inspection credit does not match the repair price';
    end if;

    select line.* into source_line
    from public.pos_sales_order_lines line
    where line.repair_ticket_id = ticket_row.id and line.repair_job_id is null
    limit 1;
    if found then
      select * into source_invoice from public.pos_sales_orders
        where id = source_line.sales_order_id for update;
      select * into source_line from public.pos_sales_order_lines
        where id = source_line.id for update;
      select coalesce(sum(refund_line.amount), 0) into refunded_amount
      from public.pos_sales_refund_lines refund_line
      where refund_line.sales_order_line_id = source_line.id;
      if source_invoice.payment_status <> 'paid'
        or source_line.line_total - refunded_amount < job_row.inspection_credit then
        raise exception 'The inspection invoice must be paid and not refunded before its fee can be credited';
      end if;
      credit_source := jsonb_build_object('kind', 'earlier_invoice',
        'invoice_number', source_invoice.invoice_number,
        'invoice_order_id', source_invoice.order_code,
        'line_id', source_line.id);
    else
      select count(*) into same_invoice_base_count
      from jsonb_array_elements(payload->'items') base_item
      where base_item->>'ticket_id' = ticket_row.ticket_code
        and lower(coalesce(base_item->>'is_repair', 'false')) = 'true'
        and coalesce(base_item->>'repair_job_id', '') = ''
        and round(coalesce(nullif(base_item->>'line_total', '')::numeric, 0), 2) >= job_row.inspection_credit;
      if same_invoice_base_count <> 1 then
        raise exception 'Add the inspection to this invoice before applying its credit';
      end if;
      credit_source := jsonb_build_object('kind', 'same_invoice');
    end if;

    normalized := jsonb_set(normalized, array['items', item_index::text],
      item || jsonb_build_object(
        'original_unit_price', job_row.price,
        'inspection_credit', job_row.inspection_credit,
        'inspection_credit_source', credit_source,
        'price_overridden', false
      ));
  end loop;
  return public.save_pos_sales_order_before_inspection_credit(session_token, normalized);
end;
$$;

revoke all on function public.save_pos_sales_order(text,jsonb) from public, anon, authenticated;
grant execute on function public.save_pos_sales_order(text,jsonb) to service_role;
revoke all on function public.save_pos_sales_order_before_inspection_credit(text,jsonb)
  from public, anon, authenticated;

-- The same inspection payment cannot later be refunded while its credit is
-- still used by a billed repair.
create or replace function public.pos_guard_refund_of_credited_inspection()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  source_line public.pos_sales_order_lines%rowtype;
  credited_amount numeric(12,2);
  refunded_amount numeric(12,2);
begin
  select * into source_line from public.pos_sales_order_lines
    where id = new.sales_order_line_id;
  if source_line.repair_ticket_id is null or source_line.repair_job_id is not null then
    return new;
  end if;
  select coalesce(max(job.inspection_credit), 0) into credited_amount
  from public.pos_repair_ticket_jobs job
  join public.pos_sales_order_lines repair_line on repair_line.repair_job_id = job.id
  where job.repair_ticket_id = source_line.repair_ticket_id
    and (repair_line.line_total = 0 or repair_line.line_total > (
      select coalesce(sum(repair_refund.amount), 0)
      from public.pos_sales_refund_lines repair_refund
      where repair_refund.sales_order_line_id = repair_line.id
    ));
  if credited_amount = 0 then return new; end if;
  select coalesce(sum(refund_line.amount), 0) into refunded_amount
  from public.pos_sales_refund_lines refund_line
  where refund_line.sales_order_line_id = source_line.id;
  if source_line.line_total - refunded_amount - new.amount < credited_amount then
    raise exception 'This inspection fee was credited to a later repair and cannot be refunded twice';
  end if;
  return new;
end;
$$;

create trigger pos_sales_refund_lines_credited_inspection_guard
before insert on public.pos_sales_refund_lines
for each row execute function public.pos_guard_refund_of_credited_inspection();

-- Recompile the store-scoped entry point so it resolves the new checkout
-- wrapper after the original function was renamed.
do $migration$
begin
  execute pg_get_functiondef('public.save_pos_sales_order_for_store(text,jsonb)'::regprocedure);
end
$migration$;
