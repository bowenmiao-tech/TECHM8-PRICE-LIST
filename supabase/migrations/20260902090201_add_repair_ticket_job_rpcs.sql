-- Add, reprice and remove the extra repairs on a card.
--
-- Prices are set by staff rather than derived, because an inspection fee is
-- sometimes credited against the follow-up repair and sometimes not.
--
-- A job that has already been billed is frozen: it cannot be repriced or
-- removed, so an invoice can never be contradicted after the fact. A card that
-- has been closed takes no new jobs at all - that is a new repair.

create or replace function public.add_pos_repair_ticket_job(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  job_name text := btrim(coalesce(payload->>'name', ''));
  job_note text := btrim(coalesce(payload->>'note', ''));
  raw_price text := btrim(coalesce(payload->>'price', ''));
  price_value numeric(12,2);
  inserted public.pos_repair_ticket_jobs%rowtype;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Job payload must be an object'; end if;

  actor := public.pos_authorized_actor(
    session_token,
    coalesce(payload->>'store_code', payload->>'store_id'),
    payload->>'staff_name'
  );

  select * into ticket_row
  from public.pos_repair_tickets
  where ticket_code = coalesce(btrim(payload->>'ticket_code'), '')
  for update;
  if not found then raise exception 'Repair ticket not found'; end if;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then
    raise exception 'Repair ticket belongs to another store';
  end if;
  if ticket_row.closed_at is not null then
    raise exception 'This repair card is closed. Start a new repair instead.';
  end if;
  if not ticket_row.active then raise exception 'Repair ticket is not active'; end if;

  if job_name = '' then raise exception 'Repair name is required'; end if;
  if length(job_name) > 160 then raise exception 'Repair name cannot exceed 160 characters'; end if;
  if length(job_note) > 500 then raise exception 'Repair note cannot exceed 500 characters'; end if;
  if raw_price !~ '^[$]?[0-9]+([.][0-9]{1,2})?$' then
    raise exception 'Repair price must be one numeric amount';
  end if;
  price_value := replace(raw_price, '$', '')::numeric;
  if price_value <= 0 or price_value > 1000000 then
    raise exception 'Repair price must be between 0.01 and 1000000.00';
  end if;

  insert into public.pos_repair_ticket_jobs (
    job_code, repair_ticket_id, name, price, note, created_by, updated_by
  ) values (
    'RJB-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint
      || '-' || substr(md5(random()::text), 1, 6),
    ticket_row.id, job_name, price_value, job_note,
    actor->>'staff_name', actor->>'staff_name'
  ) returning * into inserted;

  update public.pos_repair_tickets
  set activity = jsonb_build_array(jsonb_build_object(
        'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
        'type', 'job',
        'text', 'added repair: ' || job_name || ' ($' || to_char(price_value, 'FM999999990.00') || ')',
        'staffName', actor->>'staff_name',
        'at', now()
      )) || coalesce(activity, '[]'::jsonb),
      updated_by = actor->>'staff_name',
      updated_at = now()
  where id = ticket_row.id;

  select * into ticket_row from public.pos_repair_tickets where id = ticket_row.id;
  return jsonb_build_object('ok', true, 'job_code', inserted.job_code,
                            'ticket', public.pos_repair_ticket_payload(ticket_row));
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
  price_value numeric(12,2);
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Job payload must be an object'; end if;

  actor := public.pos_authorized_actor(
    session_token,
    coalesce(payload->>'store_code', payload->>'store_id'),
    payload->>'staff_name'
  );

  select * into job_row
  from public.pos_repair_ticket_jobs
  where job_code = coalesce(btrim(payload->>'job_code'), '')
  for update;
  if not found then raise exception 'Repair job not found'; end if;

  select * into ticket_row from public.pos_repair_tickets where id = job_row.repair_ticket_id for update;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then
    raise exception 'Repair ticket belongs to another store';
  end if;
  if ticket_row.closed_at is not null then
    raise exception 'This repair card is closed.';
  end if;
  if exists (select 1 from public.pos_sales_order_lines where repair_job_id = job_row.id) then
    raise exception 'This repair has already been invoiced and cannot be changed.';
  end if;

  if job_name = '' then raise exception 'Repair name is required'; end if;
  if length(job_name) > 160 then raise exception 'Repair name cannot exceed 160 characters'; end if;
  if length(job_note) > 500 then raise exception 'Repair note cannot exceed 500 characters'; end if;
  if raw_price !~ '^[$]?[0-9]+([.][0-9]{1,2})?$' then
    raise exception 'Repair price must be one numeric amount';
  end if;
  price_value := replace(raw_price, '$', '')::numeric;
  if price_value <= 0 or price_value > 1000000 then
    raise exception 'Repair price must be between 0.01 and 1000000.00';
  end if;

  update public.pos_repair_ticket_jobs
  set name = job_name, price = price_value, note = job_note,
      updated_by = actor->>'staff_name', updated_at = now()
  where id = job_row.id;

  update public.pos_repair_tickets
  set activity = jsonb_build_array(jsonb_build_object(
        'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
        'type', 'job',
        'text', 'updated repair: ' || job_name || ' ($' || to_char(price_value, 'FM999999990.00') || ')',
        'staffName', actor->>'staff_name',
        'at', now()
      )) || coalesce(activity, '[]'::jsonb),
      updated_by = actor->>'staff_name',
      updated_at = now()
  where id = ticket_row.id;

  select * into ticket_row from public.pos_repair_tickets where id = ticket_row.id;
  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;

create or replace function public.delete_pos_repair_ticket_job(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  job_row public.pos_repair_ticket_jobs%rowtype;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Job payload must be an object'; end if;

  actor := public.pos_authorized_actor(
    session_token,
    coalesce(payload->>'store_code', payload->>'store_id'),
    payload->>'staff_name'
  );

  select * into job_row
  from public.pos_repair_ticket_jobs
  where job_code = coalesce(btrim(payload->>'job_code'), '')
  for update;
  if not found then raise exception 'Repair job not found'; end if;

  select * into ticket_row from public.pos_repair_tickets where id = job_row.repair_ticket_id for update;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then
    raise exception 'Repair ticket belongs to another store';
  end if;
  if ticket_row.closed_at is not null then
    raise exception 'This repair card is closed.';
  end if;
  if exists (select 1 from public.pos_sales_order_lines where repair_job_id = job_row.id) then
    raise exception 'This repair has already been invoiced and cannot be removed.';
  end if;

  delete from public.pos_repair_ticket_jobs where id = job_row.id;

  update public.pos_repair_tickets
  set activity = jsonb_build_array(jsonb_build_object(
        'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
        'type', 'job',
        'text', 'removed repair: ' || job_row.name,
        'staffName', actor->>'staff_name',
        'at', now()
      )) || coalesce(activity, '[]'::jsonb),
      updated_by = actor->>'staff_name',
      updated_at = now()
  where id = ticket_row.id;

  select * into ticket_row from public.pos_repair_tickets where id = ticket_row.id;
  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;

revoke all on function public.add_pos_repair_ticket_job(text, jsonb) from public, anon, authenticated;
revoke all on function public.update_pos_repair_ticket_job(text, jsonb) from public, anon, authenticated;
revoke all on function public.delete_pos_repair_ticket_job(text, jsonb) from public, anon, authenticated;
grant execute on function public.add_pos_repair_ticket_job(text, jsonb) to service_role;
grant execute on function public.update_pos_repair_ticket_job(text, jsonb) to service_role;
grant execute on function public.delete_pos_repair_ticket_job(text, jsonb) to service_role;
