-- Lets the admin portal's Repair Board move cards, the same way the POS board
-- does: between columns and up and down inside a column.
--
-- The admin board runs on an admin session and reads get_admin_repair_follow_up,
-- so it cannot use move_pos_repair_ticket, which authorises a staff member
-- against one store. This is the admin-gated equivalent. It is deliberately the
-- only thing it can change: status, its timestamps, and board position.

-- The admin board needs to see the order before it can preserve it.
do $migration$
declare
  definition text;
  patched text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'get_admin_repair_follow_up' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'get_admin_repair_follow_up was not found'; end if;

  patched := replace(
    definition,
    $anchor$'display_label', ticket.display_label,$anchor$,
    $replacement$'display_label', ticket.display_label,
    'board_position', coalesce(ticket.board_position, 0),$replacement$
  );
  if patched = definition then
    raise exception 'admin board move: the display_label anchor was not found';
  end if;
  execute patched;
end;
$migration$;

create or replace function public.move_admin_repair_ticket(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ticket_row public.pos_repair_tickets%rowtype;
  target_status text := lower(btrim(coalesce(payload->>'status', '')));
  ordered_codes jsonb := coalesce(payload->'ordered_codes', '[]'::jsonb);
  previous_status text;
  moved_count integer := 0;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;
  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Move payload must be an object';
  end if;
  if jsonb_typeof(ordered_codes) <> 'array' then
    raise exception 'ordered_codes must be an array';
  end if;
  if jsonb_array_length(ordered_codes) > 300 then
    raise exception 'Too many cards in one reorder';
  end if;
  if target_status not in (
    'need_to_order', 'waiting_shipping', 'repairing',
    'waiting_pickup', 'waiting_customer_confirmation', 'over_3_months_uncollected'
  ) then
    raise exception 'Invalid board column';
  end if;

  select * into ticket_row
  from public.pos_repair_tickets
  where ticket_code = coalesce(btrim(payload->>'ticket_code'), '')
  for update;
  if not found then raise exception 'Repair ticket not found'; end if;
  if ticket_row.closed_at is not null then
    raise exception 'Closed repair cards cannot be moved';
  end if;
  if not ticket_row.active then raise exception 'Repair ticket is not active'; end if;

  previous_status := ticket_row.status;

  if previous_status <> target_status then
    update public.pos_repair_tickets
    set status = target_status,
        -- Same rule the checkout finaliser uses, so the uncollected automation
        -- keeps working off a real ready time.
        ready_for_pickup_at = case
          when target_status in ('waiting_pickup', 'over_3_months_uncollected')
            then coalesce(ready_for_pickup_at, now())
          else null
        end,
        status_updated_at = now(),
        updated_by = 'Admin portal',
        updated_at = now(),
        activity = jsonb_build_array(jsonb_build_object(
          'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
          'type', 'status',
          'text', 'moved this ticket from ' || replace(previous_status, '_', ' ')
                  || ' to ' || replace(target_status, '_', ' ') || ' in the admin portal',
          'staffName', 'Admin portal',
          'at', now()
        )) || coalesce(activity, '[]'::jsonb)
    where id = ticket_row.id
    returning * into ticket_row;
  end if;

  -- Only cards in the same store and column are repositioned; anything else in
  -- the list is ignored rather than trusted.
  with requested as (
    select entry.value #>> '{}' as ticket_code,
           entry.ordinality * 10 as position
    from jsonb_array_elements(ordered_codes) with ordinality as entry(value, ordinality)
  ), applied as (
    update public.pos_repair_tickets ticket
    set board_position = requested.position,
        updated_at = now()
    from requested
    where ticket.ticket_code = requested.ticket_code
      and ticket.store_id = ticket_row.store_id
      and ticket.status = target_status
      and ticket.closed_at is null
      and ticket.active = true
    returning 1
  )
  select count(*) into moved_count from applied;

  return jsonb_build_object(
    'ok', true,
    'ticket_code', ticket_row.ticket_code,
    'status', ticket_row.status,
    'reordered', moved_count
  );
end;
$$;

revoke all on function public.move_admin_repair_ticket(text, jsonb) from public;
grant execute on function public.move_admin_repair_ticket(text, jsonb) to anon;
grant execute on function public.move_admin_repair_ticket(text, jsonb) to authenticated;
grant execute on function public.move_admin_repair_ticket(text, jsonb) to service_role;

comment on function public.move_admin_repair_ticket(text, jsonb) is
  'Admin-session-only Repair Board move: changes one card''s column and rewrites the manual order of that column. Touches nothing else on the card.';
