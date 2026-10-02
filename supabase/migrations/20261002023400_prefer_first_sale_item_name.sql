-- RepairDesk labels an item group with its earliest saved product name.
do $migration$
declare definition text;
begin
  select pg_get_functiondef('public.get_admin_sales_by_item(text,date,date,text,text,text,text,integer,integer)'::regprocedure)
  into definition;
  if position('array_agg(name order by abs(movement_quantity) desc,business_date desc)' in definition) > 0 then
    execute replace(definition,
      'array_agg(name order by abs(movement_quantity) desc,business_date desc)',
      'array_agg(name order by business_date asc,id asc)');
  end if;
end;
$migration$;
