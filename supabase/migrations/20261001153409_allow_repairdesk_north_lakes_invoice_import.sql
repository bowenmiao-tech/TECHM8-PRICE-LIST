do $migration$
declare
  definition text;
  old_store_rule text := '(''techm8 fairfield'', ''TechM8 Fairfield'', ''fairfield'', ''RD-FF-INV-'', 11877::bigint)';
  new_store_rule text := '(''techm8 fairfield'', ''TechM8 Fairfield'', ''fairfield'', ''RD-FF-INV-'', 11877::bigint),
      (''techm8 north lakes'', ''TechM8 North Lakes'', ''northlakes'', ''RD-NL-INV-'', 4937::bigint)';
  old_line_type text := 'line_number_value,' || chr(10)
    || '        ''retail'',' || chr(10)
    || '        coalesce(trim(item->>''product_id''), '''')';
  new_line_type text := 'line_number_value,' || chr(10)
    || '        case when lower(coalesce(item->>''line_type'', '''')) in (''retail'', ''repair'', ''used_device'')' || chr(10)
    || '          then lower(item->>''line_type'') else ''retail'' end,' || chr(10)
    || '        coalesce(trim(item->>''product_id''), '''')';
begin
  select pg_get_functiondef('public.import_repairdesk_sales_batch(jsonb)'::regprocedure)
  into definition;

  if position(old_store_rule in definition) = 0
    or position(old_line_type in definition) = 0 then
    raise exception 'RepairDesk import function has changed; review it before approving North Lakes';
  end if;

  definition := replace(definition, old_store_rule, new_store_rule);
  definition := replace(definition, old_line_type, new_line_type);
  execute definition;
end;
$migration$;

revoke all on function public.import_repairdesk_sales_batch(jsonb) from public;
revoke all on function public.import_repairdesk_sales_batch(jsonb) from anon;
revoke all on function public.import_repairdesk_sales_batch(jsonb) from authenticated;
grant execute on function public.import_repairdesk_sales_batch(jsonb) to service_role;

comment on function public.import_repairdesk_sales_batch(jsonb) is
  'Idempotently imports approved TechM8 Toowong, Fairfield, and North Lakes RepairDesk invoice history without changing inventory or active shifts.';
