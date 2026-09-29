-- Staff expect to move a Done card like any other card: pick a column in the
-- status list or drag it, and it is back on the board. The reopen note is now
-- optional (the move itself is logged in activity; staff add comments after),
-- and every board column is a valid destination.

create or replace function public.reopen_pos_repair_ticket(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  reason text := btrim(coalesce(payload->>'reason', ''));
  next_status text := coalesce(nullif(lower(btrim(payload->>'status')), ''), 'repairing');
  device_back boolean;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Payload must be an object'; end if;
  actor := public.pos_authorized_actor(session_token, coalesce(payload->>'store_code', payload->>'store_id'), payload->>'staff_name');

  if char_length(reason) > 2000 then raise exception 'Keep the follow-up note under 2,000 characters'; end if;
  if next_status not in ('need_to_order', 'waiting_shipping', 'repairing', 'waiting_pickup', 'waiting_customer_confirmation', 'over_3_months_uncollected') then
    raise exception 'Invalid board column';
  end if;
  device_back := coalesce(nullif(payload->>'device_in_store', '')::boolean, true);

  select * into ticket_row
  from public.pos_repair_tickets ticket
  where ticket.ticket_code = coalesce(btrim(payload->>'ticket_code'), '')
  for update;
  if not found then raise exception 'Repair ticket not found'; end if;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then raise exception 'Repair ticket belongs to another store'; end if;
  if not ticket_row.active then raise exception 'Deleted repair tickets cannot be reopened'; end if;
  if ticket_row.closed_at is null then raise exception 'This card is already open on the Repair Board'; end if;

  -- Type 'status' stops the activity trigger adding a second "moved" event;
  -- the reopened flag lets the board show which cards are follow-ups.
  update public.pos_repair_tickets
  set status = next_status,
      resolution = null,
      closed_at = null,
      ready_for_pickup_at = case when next_status in ('waiting_pickup', 'over_3_months_uncollected') then now() else null end,
      device_in_store = device_back,
      board_position = 0,
      updated_by = actor->>'staff_name',
      status_updated_at = now(),
      updated_at = now(),
      activity = jsonb_build_array(jsonb_build_object(
        'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
        'type', 'status',
        'reopened', true,
        'text', 'reopened this card for a follow-up check (was closed as '
          || replace(coalesce(ticket_row.resolution, 'done'), '_', ' ')
          || ') in ' || replace(next_status, '_', ' '),
        'staffName', actor->>'staff_name',
        'at', now()
      )) || coalesce(activity, '[]'::jsonb)
  where id = ticket_row.id;

  if reason <> '' then
    insert into public.pos_repair_ticket_updates(id, repair_ticket_id, kind, body, author)
    values (gen_random_uuid(), ticket_row.id, 'comment', 'Follow-up check: ' || reason, actor->>'staff_name');
  end if;

  select * into ticket_row from public.pos_repair_tickets where id = ticket_row.id;
  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$function$;

comment on function public.reopen_pos_repair_ticket(text, jsonb) is
  'Puts a Done (closed, not deleted) repair or memo card back into any Repair Board column. An optional reason is saved as a note on the card. Invoices, jobs and history are untouched.';

revoke all on function public.reopen_pos_repair_ticket(text, jsonb) from public, anon, authenticated;
grant execute on function public.reopen_pos_repair_ticket(text, jsonb) to service_role;
