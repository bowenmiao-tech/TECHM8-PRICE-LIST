-- Lets staff order cards inside a Repair Board column, not just move them
-- between columns.
--
-- Ordering is kept separate from the status change on purpose. Moving a card to
-- another column still goes through upsert_pos_repair_ticket, which refuses a
-- card without a customer name and phone and writes the activity entry. This
-- function only rewrites positions, so dragging can never bypass those rules or
-- quietly change anything else about a card.

alter table public.pos_repair_tickets
  add column if not exists board_position integer not null default 0;

comment on column public.pos_repair_tickets.board_position is
  'Manual order of a card within its Repair Board column. Lower sorts first.';

-- Seed the existing cards in the order the board already shows them, so nothing
-- jumps around the first time this ships.
with ordered as (
  select id,
         row_number() over (
           partition by store_id, status
           order by status_updated_at desc nulls last, created_at desc
         ) * 10 as position
  from public.pos_repair_tickets
  where closed_at is null and active = true
)
update public.pos_repair_tickets ticket
set board_position = ordered.position
from ordered
where ordered.id = ticket.id
  and ticket.board_position = 0;

create index if not exists pos_repair_tickets_board_order_idx
  on public.pos_repair_tickets (store_id, status, board_position);

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
    $anchor$    'status', ticket_row.status,$anchor$,
    $replacement$    'status', ticket_row.status,
    'boardPosition', coalesce(ticket_row.board_position, 0),$replacement$
  );
  if patched = definition then
    raise exception 'board position patch: the payload status anchor was not found';
  end if;
  execute patched;
end;
$migration$;

create or replace function public.move_pos_repair_ticket(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  target_status text := lower(btrim(coalesce(payload->>'status', '')));
  ordered_codes jsonb := coalesce(payload->'ordered_codes', '[]'::jsonb);
  moved_count integer := 0;
begin
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

  actor := public.pos_authorized_actor(
    session_token,
    coalesce(payload->>'store_code', payload->>'store_id'),
    payload->>'staff_name'
  );

  -- Only cards in the caller's own store, in that column, and still open are
  -- repositioned. Anything else in the list is ignored rather than trusted.
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
      and ticket.store_id = nullif(actor->>'store_id', '')::bigint
      and ticket.status = target_status
      and ticket.closed_at is null
      and ticket.active = true
    returning 1
  )
  select count(*) into moved_count from applied;

  return jsonb_build_object('ok', true, 'reordered', moved_count);
end;
$$;

revoke all on function public.move_pos_repair_ticket(text, jsonb) from public;
revoke all on function public.move_pos_repair_ticket(text, jsonb) from anon;
revoke all on function public.move_pos_repair_ticket(text, jsonb) from authenticated;
grant execute on function public.move_pos_repair_ticket(text, jsonb) to service_role;

comment on function public.move_pos_repair_ticket(text, jsonb) is
  'Rewrites the manual card order for one Repair Board column in the caller''s store. Never changes status, price, or any other field.';
