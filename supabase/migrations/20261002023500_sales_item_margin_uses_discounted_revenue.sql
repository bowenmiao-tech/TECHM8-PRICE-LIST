-- Match RepairDesk's margin denominator when a sale line has a discount.
do $migration$
declare definition text;
begin
  select pg_get_functiondef('public.get_admin_sales_by_item(text,date,date,text,text,text,text,integer,integer)'::regprocedure)
  into definition;
  definition := replace(definition,
    'totals.cogs is null or totals.total=0 then null else round((totals.total-totals.discount-totals.cogs)*100/totals.total,2)',
    'totals.cogs is null or totals.total=totals.discount then null else round((totals.total-totals.discount-totals.cogs)*100/(totals.total-totals.discount),2)');
  definition := replace(definition,
    'page.cogs is null or page.total=0 then null else round((page.total-page.discount-page.cogs)*100/page.total,2)',
    'page.cogs is null or page.total=page.discount then null else round((page.total-page.discount-page.cogs)*100/(page.total-page.discount),2)');
  execute definition;
end;
$migration$;
