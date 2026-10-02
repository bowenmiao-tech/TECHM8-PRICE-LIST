-- Keep previously deployed versions in sync with the reviewed definitions.
do $migration$
declare
  definition text;
begin
  select pg_get_functiondef('public.backfill_repairdesk_north_lakes_sales_items(jsonb)'::regprocedure)
  into definition;
  if position('''RD-NL-INV-'' || item->>''invoice_number''' in definition) > 0 then
    execute replace(definition,
      '''RD-NL-INV-'' || item->>''invoice_number''',
      '''RD-NL-INV-'' || (item->>''invoice_number'')');
  end if;

  select pg_get_functiondef('public.get_admin_sales_by_item(text,date,date,text,text,text,text,integer,integer)'::regprocedure)
  into definition;
  if position('order by qty desc,total desc,product_name limit limit_value' in definition) > 0 then
    definition := replace(definition,
      'order by qty desc,total desc,product_name limit limit_value',
      'order by qty desc,total desc,product_name,item_type,item_key,repair_category,category,brand,model limit limit_value');
    definition := replace(definition,
      'order by page.qty desc,page.total desc,page.product_name)',
      'order by page.qty desc,page.total desc,page.product_name,page.item_type,page.item_key,page.repair_category,page.category,page.brand,page.model)');
    execute definition;
  end if;
end;
$migration$;
