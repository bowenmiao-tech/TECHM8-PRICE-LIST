-- Let staff mark an open repair card as a mainboard repair, or undo it.
--
-- Cards are often booked in as an inspection and only turn into a board repair
-- after diagnosis. motherboard_repair could only be set on the intake form, so
-- those cards never showed the red "Mainboard" tag on the Repair Board.
--
-- A dedicated entry point, like set_pos_repair_ticket_label:
-- upsert_pos_repair_ticket rewrites the whole card from the browser's copy and
-- demands a valid price, so flipping one flag through it could overwrite price
-- or status.

create or replace function public.set_pos_repair_ticket_mainboard(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  flag_text text := lower(btrim(coalesce(payload->>'motherboard_repair', '')));
  new_flag boolean;
begin
  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Mainboard payload must be an object';
  end if;
  if flag_text not in ('true', 'false') then
    raise exception 'motherboard_repair must be true or false';
  end if;
  new_flag := flag_text = 'true';

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
  if ticket_row.card_kind = 'memo' then
    raise exception 'Memo cards cannot be marked as a mainboard repair';
  end if;

  if ticket_row.motherboard_repair = new_flag then
    return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
  end if;

  update public.pos_repair_tickets
  set motherboard_repair = new_flag,
      updated_by = actor->>'staff_name',
      updated_at = now(),
      activity = jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'type', 'mainboard',
        -- Tells preserve_pos_repair_activity this change already has its line.
        'field', 'motherboard_repair',
        'text', case
          when new_flag then 'marked this card as a mainboard repair'
          else 'removed the mainboard repair mark'
        end,
        'staffName', actor->>'staff_name',
        'at', now()
      )) || coalesce(activity, '[]'::jsonb)
  where id = ticket_row.id
  returning * into ticket_row;

  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;

revoke all on function public.set_pos_repair_ticket_mainboard(text, jsonb) from public;
revoke all on function public.set_pos_repair_ticket_mainboard(text, jsonb) from anon;
revoke all on function public.set_pos_repair_ticket_mainboard(text, jsonb) from authenticated;
grant execute on function public.set_pos_repair_ticket_mainboard(text, jsonb) to service_role;

comment on function public.set_pos_repair_ticket_mainboard(text, jsonb) is
  'Turns the Mainboard tag on or off for one repair card in the caller''s store. Does not touch the device, price, status or invoice.';

-- The activity trigger also writes a generic "updated motherboard repair" line
-- for any changed column. Skip that when the change arrives with its own line
-- naming the column, so the card history does not say it twice.
do $migration$
declare
  definition text;
  patched text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'preserve_pos_repair_activity' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'preserve_pos_repair_activity was not found'; end if;

  patched := replace(
    definition,
    $anchor$    ) fields(key,label) where (to_jsonb(old)->key) is distinct from (to_jsonb(new)->key);$anchor$,
    $replacement$    ) fields(key,label) where (to_jsonb(old)->key) is distinct from (to_jsonb(new)->key)
      and not exists(select 1 from jsonb_array_elements(incoming) e where e->>'field' = fields.key);$replacement$
  );
  if patched = definition then
    raise exception 'mainboard patch: the activity details anchor was not found';
  end if;
  execute patched;
end;
$migration$;
