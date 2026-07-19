do $migration$
declare
  function_sql text;
  old_expression text := $old$lower(regexp_replace(trim(sales_line.category), '[^a-z0-9]+', '', 'g'))$old$;
  new_expression text := $new$regexp_replace(lower(trim(sales_line.category)), '[^a-z0-9]+', '', 'g')$new$;
begin
  select pg_get_functiondef('public.pos_today_progress_payload(bigint,date,text)'::regprocedure)
  into function_sql;

  if position(old_expression in function_sql) = 0 then
    raise exception 'Expected target category expression was not found';
  end if;

  execute replace(function_sql, old_expression, new_expression);
end;
$migration$;
