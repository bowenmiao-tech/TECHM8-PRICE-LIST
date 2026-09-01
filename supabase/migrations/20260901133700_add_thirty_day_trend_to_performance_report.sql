-- Adds a 30-day daily takings series for the trend chart on the performance
-- page. The window always ends on the report's end date and is independent of
-- the selected range, so "Today" still shows a month of context.
--
-- Patched into the stored definition so the rest of the function, which has
-- been extended since it was written, stays byte-identical.
do $migration$
declare
  existing_definition text;
  patched_definition text;
  cte_anchor constant text := E'\n  payment_methods as (';
  key_anchor constant text := E'\n    ''date_to'', to_value,';
  cte_block constant text := E'\n'
    '  -- Daily takings for the trend chart: a fixed 30-day window ending on the\n'
    '  -- report end date, aggregated once per day rather than per row.\n'
    '  trend_payments as (\n'
    '    select coalesce(payment.business_date, (payment.created_at at time zone ''Australia/Brisbane'')::date) as day,\n'
    '           sum(payment.amount) as received\n'
    '    from public.pos_sales_order_payments payment\n'
    '    join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id\n'
    '    where sales_order.store_id = selected_store.id\n'
    '      and coalesce(payment.business_date, (payment.created_at at time zone ''Australia/Brisbane'')::date)\n'
    '          between to_value - 29 and to_value\n'
    '    group by 1\n'
    '  ),\n'
    '  trend_refunds as (\n'
    '    select coalesce(refund.business_date, (refund.created_at at time zone ''Australia/Brisbane'')::date) as day,\n'
    '           sum(refund.amount) as refunded\n'
    '    from public.pos_sales_refunds refund\n'
    '    where refund.store_id = selected_store.id\n'
    '      and coalesce(refund.business_date, (refund.created_at at time zone ''Australia/Brisbane'')::date)\n'
    '          between to_value - 29 and to_value\n'
    '    group by 1\n'
    '  ),\n'
    '  daily_trend_rows as (\n'
    '    select\n'
    '      day_series::date as day,\n'
    '      coalesce(trend_payments.received, 0) as received,\n'
    '      coalesce(trend_refunds.refunded, 0) as refunded\n'
    '    from generate_series(to_value - 29, to_value, interval ''1 day'') as day_series\n'
    '    left join trend_payments on trend_payments.day = day_series::date\n'
    '    left join trend_refunds on trend_refunds.day = day_series::date\n'
    '  ),';
  key_block constant text := E'\n'
    '    ''daily_trend'', coalesce((\n'
    '      select jsonb_agg(jsonb_build_object(\n'
    '        ''date'', day,\n'
    '        ''received'', round(received, 2),\n'
    '        ''refunded'', round(refunded, 2),\n'
    '        ''net'', round(received - refunded, 2)\n'
    '      ) order by day)\n'
    '      from daily_trend_rows\n'
    '    ), ''[]''::jsonb),';
begin
  select pg_get_functiondef(oid) into existing_definition
  from pg_proc
  where proname = 'get_pos_performance_report' and pronamespace = 'public'::regnamespace;

  if existing_definition is null then
    raise exception 'get_pos_performance_report was not found';
  end if;
  if position(cte_anchor in existing_definition) = 0 then
    raise exception 'payment_methods CTE anchor was not found';
  end if;
  if position(key_anchor in existing_definition) = 0 then
    raise exception 'date_to key anchor was not found';
  end if;
  if position('daily_trend' in existing_definition) > 0 then
    raise exception 'daily_trend is already present';
  end if;

  patched_definition := replace(existing_definition, cte_anchor, cte_block || cte_anchor);
  patched_definition := replace(patched_definition, key_anchor, key_anchor || key_block);

  execute patched_definition;
end
$migration$;
