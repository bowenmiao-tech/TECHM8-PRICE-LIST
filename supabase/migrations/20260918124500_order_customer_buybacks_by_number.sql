-- Two purchases from the same seller in the same transaction share an
-- `acquired_at`, and the history panel then showed them in whichever order the
-- planner felt like. The buyback number is the tiebreaker: it is allocated in
-- the order the purchases were made, so ordering by it is ordering by time.
do $migration$
declare
  definition text;
  patched text;
  previous text;
begin
  select replace(pg_get_functiondef(oid), chr(13), '') into definition
  from pg_proc
  where proname = 'get_pos_customer_buybacks' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'get_pos_customer_buybacks was not found'; end if;

  patched := definition;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.acquired_at desc), '[]'::jsonb)$anchor$,
    $replacement$  select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.acquired_at desc, row_data.buyback_number desc), '[]'::jsonb)$replacement$
  );
  if patched = previous then
    raise exception 'buyback ordering patch: the aggregate anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$    order by acquisition.acquired_at desc
    limit safe_limit$anchor$,
    $replacement$    order by acquisition.acquired_at desc, acquisition.buyback_number desc
    limit safe_limit$replacement$
  );
  if patched = previous then
    raise exception 'buyback ordering patch: the subquery anchor was not found';
  end if;

  execute patched;
end;
$migration$;
