-- Carry board_position through ticket_rows before the final JSON projection.
do $migration$
declare
  definition text;
  patched text;
begin
  select pg_get_functiondef('public.get_admin_repair_follow_up(text)'::regprocedure) into definition;
  patched := replace(definition,
    'coalesce(ticket.display_label, '''') as display_label,',
    'coalesce(ticket.display_label, '''') as display_label,
      ticket.board_position,');
  if patched = definition then
    raise exception 'Admin repair board projection anchor was not found';
  end if;
  execute patched;
end;
$migration$;
