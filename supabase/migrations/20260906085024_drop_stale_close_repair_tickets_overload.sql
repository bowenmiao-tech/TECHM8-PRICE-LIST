-- Adding the should_close parameter with CREATE OR REPLACE did not replace the
-- old function: it created a second overload and left the five-argument version
-- in place. Postgres prefers an exact argument match over a default, so any
-- five-argument call silently reached the old body and closed the card no
-- matter what the caller asked for.
--
-- Both callers now pass the flag explicitly, so the stale overload is dead code
-- and is removed rather than left as a trap for the next caller.
do $migration$
declare
  stale_oid oid;
  caller record;
begin
  select oid into stale_oid
  from pg_proc
  where proname = 'close_pos_repair_tickets_for_order'
    and pronamespace = 'public'::regnamespace
    and pg_get_function_identity_arguments(oid) = 'bigint, text, bigint, text, text';

  if stale_oid is null then
    raise notice 'five-argument overload already gone';
    return;
  end if;

  -- Refuse to drop it while anything could still resolve to it.
  for caller in
    select p.proname
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.oid <> stale_oid
      and p.proname <> 'close_pos_repair_tickets_for_order'
      and pg_get_functiondef(p.oid) ilike '%close_pos_repair_tickets_for_order%'
      and pg_get_functiondef(p.oid) not ilike '%close_repair_tickets%'
  loop
    raise exception 'still has a five-argument caller: %', caller.proname;
  end loop;

  execute 'drop function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text)';
end
$migration$;
