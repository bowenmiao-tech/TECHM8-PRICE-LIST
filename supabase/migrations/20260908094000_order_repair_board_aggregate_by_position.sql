-- The aggregate is what actually decides the order the POS receives; the inner
-- subquery order is discarded. A brand new card carries position 0 and so still
-- arrives at the top of its column, which is where the old newest-first order
-- put it.
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
    $anchor$order by ticket.status_updated_at desc, ticket.created_at desc$anchor$,
    $replacement$order by ticket.board_position, ticket.status_updated_at desc, ticket.created_at desc$replacement$
  );
  if patched = definition then
    raise exception 'board order patch: the aggregate order anchor was not found';
  end if;
  execute patched;
end;
$migration$;
