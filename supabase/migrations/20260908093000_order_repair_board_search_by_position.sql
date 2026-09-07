-- First half of pushing the board order server-side. This patches the ORDER BY
-- inside the subquery that selects the tickets. On its own it changes nothing
-- the POS can see, because the surrounding jsonb_agg re-orders the rows; the
-- aggregate is patched in the migration that follows.
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
    $anchor$repair_ticket.status_updated_at desc, repair_ticket.created_at desc$anchor$,
    $replacement$repair_ticket.board_position, repair_ticket.status_updated_at desc, repair_ticket.created_at desc$replacement$
  );
  if patched = definition then
    raise exception 'board order patch: the search order anchor was not found';
  end if;
  execute patched;
end;
$migration$;
