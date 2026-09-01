-- Imported RepairDesk credit invoices carry negative line totals, and the
-- proportional split guarded on "> 0", so their money was silently dropped from
-- the category cards while still counting in the payment totals. A handful of
-- exchange invoices whose lines net to exactly zero cannot be split at all, so
-- whatever cannot be attributed is now reported instead of disappearing.
do $migration$
declare
  existing_definition text;
  patched_definition text;
  guard constant text := 'order_line_total > 0';
  anchor constant text := E'      ''refund_count'', (select count(*)::integer from refund_rows)';
begin
  select pg_get_functiondef(oid) into existing_definition
  from pg_proc
  where proname = 'get_pos_performance_report' and pronamespace = 'public'::regnamespace;

  if existing_definition is null then
    raise exception 'get_pos_performance_report was not found';
  end if;
  if (length(existing_definition) - length(replace(existing_definition, guard, ''))) / length(guard) <> 1 then
    raise exception 'expected exactly one order_line_total guard';
  end if;
  if (length(existing_definition) - length(replace(existing_definition, anchor, ''))) / length(anchor) <> 1 then
    raise exception 'expected exactly one refund_count anchor';
  end if;

  patched_definition := replace(existing_definition, guard, 'order_line_total <> 0');
  patched_definition := replace(
    patched_definition,
    anchor,
    anchor || E',\n      ''unallocated'', coalesce((select round(sum(amount), 2) from payment_rows), 0)\n'
      || E'                     - coalesce((select round(sum(received), 2) from order_received), 0)'
  );

  execute patched_definition;
end
$migration$;
