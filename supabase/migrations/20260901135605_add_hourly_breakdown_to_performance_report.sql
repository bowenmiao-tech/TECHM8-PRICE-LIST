-- When a single day is selected the 30-day trend says very little, so the
-- report also returns that day broken down by hour: takings and how many
-- invoices were rung up, which is the store's proxy for foot traffic.
--
-- Only populated for a single-day range; a date range returns an empty array.
-- The window is padded out to at least 9am-5pm so a quiet day still reads as a
-- trading day rather than one lonely bar.
do $migration$
declare
  existing_definition text;
  patched_definition text;
  cte_anchor constant text := E'\n  payment_methods as (';
  key_anchor constant text := E'\n    ''date_to'', to_value,';
  cte_block constant text := E'\n'
    '  hourly_payments as (\n'
    '    select extract(hour from coalesce(payment.taken_at, payment.created_at) at time zone ''Australia/Brisbane'')::int as hour,\n'
    '           sum(payment.amount) as received,\n'
    '           count(distinct payment.sales_order_id) as order_count\n'
    '    from public.pos_sales_order_payments payment\n'
    '    join public.pos_sales_orders sales_order on sales_order.id = payment.sales_order_id\n'
    '    where sales_order.store_id = selected_store.id\n'
    '      and from_value = to_value\n'
    '      and coalesce(payment.business_date, (payment.created_at at time zone ''Australia/Brisbane'')::date) = from_value\n'
    '    group by 1\n'
    '  ),\n'
    '  hourly_refunds as (\n'
    '    select extract(hour from refund.created_at at time zone ''Australia/Brisbane'')::int as hour,\n'
    '           sum(refund.amount) as refunded\n'
    '    from public.pos_sales_refunds refund\n'
    '    where refund.store_id = selected_store.id\n'
    '      and from_value = to_value\n'
    '      and coalesce(refund.business_date, (refund.created_at at time zone ''Australia/Brisbane'')::date) = from_value\n'
    '    group by 1\n'
    '  ),\n'
    '  hourly_bounds as (\n'
    '    select min(hour) as first_hour, max(hour) as last_hour\n'
    '    from (\n'
    '      select hour from hourly_payments\n'
    '      union all\n'
    '      select hour from hourly_refunds\n'
    '    ) active_hours\n'
    '  ),\n'
    '  hourly_rows as (\n'
    '    select\n'
    '      hour_series as hour,\n'
    '      coalesce(hourly_payments.received, 0) as received,\n'
    '      coalesce(hourly_refunds.refunded, 0) as refunded,\n'
    '      coalesce(hourly_payments.order_count, 0) as order_count\n'
    '    from hourly_bounds\n'
    '    cross join generate_series(\n'
    '      least(hourly_bounds.first_hour, 9),\n'
    '      greatest(hourly_bounds.last_hour, 17)\n'
    '    ) as hour_series\n'
    '    left join hourly_payments on hourly_payments.hour = hour_series\n'
    '    left join hourly_refunds on hourly_refunds.hour = hour_series\n'
    '    where hourly_bounds.first_hour is not null\n'
    '  ),';
  key_block constant text := E'\n'
    '    ''hourly_trend'', coalesce((\n'
    '      select jsonb_agg(jsonb_build_object(\n'
    '        ''hour'', hour,\n'
    '        ''received'', round(received, 2),\n'
    '        ''refunded'', round(refunded, 2),\n'
    '        ''net'', round(received - refunded, 2),\n'
    '        ''order_count'', order_count\n'
    '      ) order by hour)\n'
    '      from hourly_rows\n'
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
  if position('hourly_trend' in existing_definition) > 0 then
    raise exception 'hourly_trend is already present';
  end if;

  patched_definition := replace(existing_definition, cte_anchor, cte_block || cte_anchor);
  patched_definition := replace(patched_definition, key_anchor, key_anchor || key_block);

  execute patched_definition;
end
$migration$;
