-- Tablet intakes could not be saved at all. The POS offered a Tablet test
-- profile that reused the mobile checklist, but this trigger only recognised
-- 'computer' and 'mobile', so every tablet ticket was rejected with
-- "Function test profile is required".
--
-- Phones and tablets are one category now, so 'tablet' is accepted as an alias
-- for 'mobile' rather than getting its own branch. Keeping the alias also means
-- a staff browser still running the old cached page keeps working.
do $migration$
declare
  def text;
  patched text;
  anchor constant text := E'elsif test_profile = ''mobile'' then';
begin
  select pg_get_functiondef(oid) into def
  from pg_proc
  where proname = 'enforce_complete_new_pos_repair_ticket' and pronamespace = 'public'::regnamespace;
  if def is null then raise exception 'enforce_complete_new_pos_repair_ticket not found'; end if;

  if (length(def) - length(replace(def, anchor, ''))) / length(anchor) <> 1 then
    raise exception 'expected exactly one mobile test-profile branch';
  end if;

  patched := replace(def, anchor, E'elsif test_profile in (''mobile'', ''tablet'') then');
  execute patched;
end
$migration$;
