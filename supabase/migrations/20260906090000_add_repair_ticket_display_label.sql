-- A board label staff can edit, separate from the device title.
--
-- Service quotes carry a fixed brand and model, so every "Onsite/Remote
-- Assistance (Hardware) Laptop/PC Inspection" card on the board reads the same
-- and staff cannot tell them apart.
--
-- The device title is deliberately left alone rather than made editable,
-- because it is not display-only: it is written into the repair card intake
-- that the customer signs, and it is matched against the repair price list to
-- suggest prices for extra jobs. Renaming it would corrupt both. Invoice lines
-- are already unaffected either way; they are built from the base job name or
-- the job's own name, never from the title.

alter table public.pos_repair_tickets
  add column if not exists display_label text not null default '';

comment on column public.pos_repair_tickets.display_label is
  'Staff-editable label shown on the Repair Board only. Never used for invoices or the signed repair card.';

-- Expose it to the POS.
do $migration$
declare
  definition text;
  patched text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'pos_repair_ticket_payload' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'pos_repair_ticket_payload was not found'; end if;

  patched := replace(
    definition,
    $anchor$    'title', ticket_row.title,$anchor$,
    $replacement$    'title', ticket_row.title,
    'displayLabel', coalesce(ticket_row.display_label, ''),$replacement$
  );
  if patched = definition then
    raise exception 'display label patch: the payload title anchor was not found';
  end if;
  execute patched;
end;
$migration$;

-- Let the board search find what staff typed.
do $migration$
declare
  definition text;
  patched text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'search_pos_repair_tickets' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'search_pos_repair_tickets was not found'; end if;

  patched := replace(
    definition,
    $anchor$        or repair_ticket.ticket_code ilike '%' || query_value || '%'$anchor$,
    $replacement$        or repair_ticket.ticket_code ilike '%' || query_value || '%'
        or repair_ticket.display_label ilike '%' || query_value || '%'$replacement$
  );
  if patched = definition then
    raise exception 'display label patch: the search ticket_code anchor was not found';
  end if;
  execute patched;
end;
$migration$;

-- A dedicated entry point. upsert_pos_repair_ticket rewrites the whole card and
-- demands a valid price, so renaming through it could overwrite price or status.
create or replace function public.set_pos_repair_ticket_label(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  new_label text := btrim(coalesce(payload->>'display_label', ''));
  previous_label text;
begin
  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Label payload must be an object';
  end if;
  if length(new_label) > 80 then
    raise exception 'Label must be 80 characters or fewer';
  end if;

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
  if not ticket_row.active then raise exception 'Repair ticket is not active'; end if;

  previous_label := coalesce(ticket_row.display_label, '');
  if previous_label = new_label then
    return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
  end if;

  update public.pos_repair_tickets
  set display_label = new_label,
      updated_by = actor->>'staff_name',
      updated_at = now(),
      activity = jsonb_build_array(jsonb_build_object(
        'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
        'type', 'label',
        'text', case
          when new_label = '' then 'cleared the board label'
          when previous_label = '' then 'set the board label to "' || new_label || '"'
          else 'renamed the board label to "' || new_label || '"'
        end,
        'staffName', actor->>'staff_name',
        'at', now()
      )) || coalesce(activity, '[]'::jsonb)
  where id = ticket_row.id
  returning * into ticket_row;

  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;

revoke all on function public.set_pos_repair_ticket_label(text, jsonb) from public;
revoke all on function public.set_pos_repair_ticket_label(text, jsonb) from anon;
revoke all on function public.set_pos_repair_ticket_label(text, jsonb) from authenticated;
grant execute on function public.set_pos_repair_ticket_label(text, jsonb) to service_role;

comment on function public.set_pos_repair_ticket_label(text, jsonb) is
  'Sets the Repair Board display label for one ticket in the caller''s store. Does not touch the device title, price, or status.';
