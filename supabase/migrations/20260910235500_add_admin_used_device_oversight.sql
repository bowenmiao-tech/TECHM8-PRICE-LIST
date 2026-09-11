-- Admin oversight for the second-hand device business.
--
-- Until now the admin portal showed one figure for used devices: their share of
-- net sales. Nothing showed what was paid out, to whom, by which staff member,
-- what it cost to make each device sellable, or which purchases look wrong.
-- Buying second-hand goods for cash is the part of this business with the most
-- exposure, so it gets its own three views:
--
--   overview  - per store: what went out, what came back, what is still sitting
--               on the shelf, and how old it is.
--   register  - the second-hand dealer register itself, one row per purchase
--               with the seller details, ready to hand to an auditor.
--   alerts    - the patterns worth a person looking at, ordered by severity.
--
-- All three are admin-session only. The register carries identity details, so
-- it is never exposed to a staff session.

create or replace function public.get_admin_used_device_overview(
  session_token text,
  date_from date default null,
  date_to date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  from_value date := coalesce(date_from, (now() at time zone 'Australia/Brisbane')::date);
  to_value date := coalesce(date_to, date_from, (now() at time zone 'Australia/Brisbane')::date);
  result_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  if from_value > to_value then raise exception 'Start date must not be after end date'; end if;
  if to_value - from_value > 366 then raise exception 'Report range cannot exceed 367 days'; end if;

  with selected_stores as materialized (
    select store_location.id, store_location.store_code, store_location.store_name
    from public.store_locations store_location
    where store_location.active = true and store_location.store_code <> 'warehouse'
  ),
  purchases as (
    select
      acquisition.store_id,
      count(*)::integer as purchase_count,
      round(sum(acquisition.payout_amount), 2) as paid_out,
      round(sum(acquisition.payout_amount) filter (where acquisition.payout_method = 'Cash'), 2) as paid_out_cash,
      round(sum(acquisition.payout_amount) filter (where acquisition.payout_method = 'Bank Transfer'), 2) as paid_out_transfer
    from public.pos_used_device_acquisitions acquisition
    join selected_stores store on store.id = acquisition.store_id
    where (acquisition.acquired_at at time zone 'Australia/Brisbane')::date between from_value and to_value
    group by acquisition.store_id
  ),
  sales as (
    select
      device.store_id,
      count(*)::integer as sold_count,
      round(sum(ledger.amount), 2) as sold_revenue,
      round(sum(ledger.amount - device.purchase_cost), 2) as realized_margin
    from public.pos_used_device_transactions ledger
    join public.pos_used_devices device on device.id = ledger.device_id
    join selected_stores store on store.id = device.store_id
    where ledger.transaction_type = 'sale'
      and (ledger.created_at at time zone 'Australia/Brisbane')::date between from_value and to_value
    group by device.store_id
  ),
  -- Stock is a position, not a period: it is reported as it stands today.
  stock as (
    select
      device.store_id,
      count(*)::integer as in_stock,
      count(*) filter (where device.status = 'inspection')::integer as inspection_count,
      count(*) filter (where device.status = 'ready_for_sale')::integer as ready_count,
      round(sum(device.purchase_cost), 2) as stock_cost,
      round(sum(device.sale_price), 2) as stock_retail,
      count(*) filter (where device.acquired_at < now() - interval '90 days')::integer as aged_over_90,
      count(*) filter (where device.clean_check_status = 'Pending')::integer as pending_checks,
      count(*) filter (where device.clean_check_status = 'Blocked')::integer as blocked_in_stock,
      count(*) filter (
        where device.evidence_required and not exists (
          select 1 from public.pos_used_device_updates entry
          where entry.device_id = device.id and entry.kind = 'photo' and entry.stage = 'intake'
        )
      )::integer as missing_intake_evidence
    from public.pos_used_devices device
    join selected_stores store on store.id = device.store_id
    where device.status in ('inspection', 'ready_for_sale')
    group by device.store_id
  ),
  store_rows as (
    select
      store.store_code,
      store.store_name,
      coalesce(purchases.purchase_count, 0) as purchase_count,
      coalesce(purchases.paid_out, 0) as paid_out,
      coalesce(purchases.paid_out_cash, 0) as paid_out_cash,
      coalesce(purchases.paid_out_transfer, 0) as paid_out_transfer,
      coalesce(sales.sold_count, 0) as sold_count,
      coalesce(sales.sold_revenue, 0) as sold_revenue,
      coalesce(sales.realized_margin, 0) as realized_margin,
      coalesce(stock.in_stock, 0) as in_stock,
      coalesce(stock.inspection_count, 0) as inspection_count,
      coalesce(stock.ready_count, 0) as ready_count,
      coalesce(stock.stock_cost, 0) as stock_cost,
      coalesce(stock.stock_retail, 0) as stock_retail,
      coalesce(stock.aged_over_90, 0) as aged_over_90,
      coalesce(stock.pending_checks, 0) as pending_checks,
      coalesce(stock.blocked_in_stock, 0) as blocked_in_stock,
      coalesce(stock.missing_intake_evidence, 0) as missing_intake_evidence
    from selected_stores store
    left join purchases on purchases.store_id = store.id
    left join sales on sales.store_id = store.id
    left join stock on stock.store_id = store.id
  )
  select jsonb_build_object(
    'ok', true,
    'date_from', from_value,
    'date_to', to_value,
    'stores', coalesce(jsonb_agg(to_jsonb(store_rows) order by store_rows.store_name), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'purchase_count', coalesce(sum(purchase_count), 0),
        'paid_out', coalesce(round(sum(paid_out), 2), 0),
        'paid_out_cash', coalesce(round(sum(paid_out_cash), 2), 0),
        'paid_out_transfer', coalesce(round(sum(paid_out_transfer), 2), 0),
        'sold_count', coalesce(sum(sold_count), 0),
        'sold_revenue', coalesce(round(sum(sold_revenue), 2), 0),
        'realized_margin', coalesce(round(sum(realized_margin), 2), 0),
        'in_stock', coalesce(sum(in_stock), 0),
        'stock_cost', coalesce(round(sum(stock_cost), 2), 0),
        'stock_retail', coalesce(round(sum(stock_retail), 2), 0),
        'aged_over_90', coalesce(sum(aged_over_90), 0),
        'pending_checks', coalesce(sum(pending_checks), 0),
        'blocked_in_stock', coalesce(sum(blocked_in_stock), 0),
        'missing_intake_evidence', coalesce(sum(missing_intake_evidence), 0)
      ) from store_rows
    )
  ) into result_payload
  from store_rows;

  return result_payload;
end;
$$;

-- One row per purchase, with everything the second-hand dealer register has to
-- show. Admin only: this is the identity data.
create or replace function public.get_admin_used_device_register(
  session_token text,
  payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  from_value date := coalesce(nullif(payload->>'date_from', '')::date, (now() at time zone 'Australia/Brisbane')::date - 30);
  to_value date := coalesce(nullif(payload->>'date_to', '')::date, (now() at time zone 'Australia/Brisbane')::date);
  store_value text := trim(coalesce(payload->>'store_code', ''));
  query_value text := trim(coalesce(payload->>'search', ''));
  safe_limit integer := least(greatest(coalesce(nullif(payload->>'limit', '')::integer, 500), 1), 5000);
  rows_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  if from_value > to_value then raise exception 'Start date must not be after end date'; end if;
  if to_value - from_value > 732 then raise exception 'Register range cannot exceed 733 days'; end if;

  select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.acquired_at desc), '[]'::jsonb)
  into rows_payload
  from (
    select
      acquisition.acquisition_code,
      acquisition.acquired_at,
      store.store_code,
      store.store_name,
      acquisition.acquired_by as staff_name,
      acquisition.shift_id,
      acquisition.seller_name,
      acquisition.seller_phone,
      acquisition.seller_email,
      acquisition.seller_address,
      acquisition.seller_id_type,
      acquisition.seller_id_reference,
      acquisition.seller_is_owner,
      acquisition.owner_name,
      acquisition.owner_address,
      acquisition.acquisition_statement,
      acquisition.declaration_text,
      acquisition.payout_method,
      acquisition.payout_amount,
      device.device_code,
      device.category,
      device.brand,
      device.model,
      device.storage,
      device.color,
      device.condition_grade,
      device.imei,
      device.serial_number,
      device.clean_check_status,
      device.clean_check_reference,
      device.status,
      device.sale_price,
      device.sold_at,
      sales_order.invoice_number,
      sale_ledger.counterparty_name as buyer_name,
      sale_ledger.counterparty_phone as buyer_phone,
      sale_ledger.amount as sold_amount,
      (
        select count(*) from public.pos_used_device_updates entry
        where entry.device_id = device.id and entry.kind = 'photo' and entry.stage = 'intake'
      )::integer as intake_photo_count,
      (
        select count(*) from public.pos_used_device_updates entry
        where entry.device_id = device.id and entry.kind = 'photo' and entry.stage = 'seller_id'
      )::integer as id_photo_count
    from public.pos_used_device_acquisitions acquisition
    join public.pos_used_devices device on device.acquisition_id = acquisition.id
    join public.store_locations store on store.id = acquisition.store_id
    left join public.pos_sales_orders sales_order on sales_order.id = device.sold_order_id
    left join lateral (
      select ledger.counterparty_name, ledger.counterparty_phone, ledger.amount
      from public.pos_used_device_transactions ledger
      where ledger.device_id = device.id and ledger.transaction_type = 'sale'
      order by ledger.id desc limit 1
    ) sale_ledger on true
    where (acquisition.acquired_at at time zone 'Australia/Brisbane')::date between from_value and to_value
      and (store_value = '' or store.store_code = store_value)
      and (
        query_value = ''
        or acquisition.seller_name ilike '%' || query_value || '%'
        or acquisition.seller_phone ilike '%' || query_value || '%'
        or acquisition.seller_id_reference ilike '%' || query_value || '%'
        or acquisition.acquisition_code ilike '%' || query_value || '%'
        or device.device_code ilike '%' || query_value || '%'
        or device.imei ilike '%' || query_value || '%'
        or device.serial_number ilike '%' || query_value || '%'
        or device.brand ilike '%' || query_value || '%'
        or device.model ilike '%' || query_value || '%'
      )
    order by acquisition.acquired_at desc
    limit safe_limit
  ) row_data;

  return jsonb_build_object(
    'ok', true,
    'date_from', from_value,
    'date_to', to_value,
    'store_code', store_value,
    'rows', rows_payload
  );
end;
$$;

-- Patterns worth a person looking at. Each row names the device or purchase so
-- it can be opened directly, and says plainly what is odd about it.
create or replace function public.get_admin_used_device_alerts(
  session_token text,
  lookback_days integer default 90
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  window_days integer := least(greatest(coalesce(lookback_days, 90), 1), 730);
  since_value timestamptz := now() - make_interval(days => window_days);
  alerts_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;

  with recent as materialized (
    select
      acquisition.id as acquisition_id,
      acquisition.acquisition_code,
      acquisition.acquired_at,
      acquisition.acquired_by,
      acquisition.seller_name,
      acquisition.seller_phone,
      acquisition.seller_id_reference,
      acquisition.payout_amount,
      acquisition.payout_method,
      device.id as device_id,
      device.device_code,
      device.brand,
      device.model,
      device.status,
      device.purchase_cost,
      device.sale_price,
      device.clean_check_status,
      device.evidence_required,
      device.sold_at,
      store.store_code,
      store.store_name,
      regexp_replace(coalesce(acquisition.seller_phone, ''), '[^0-9]', '', 'g') as phone_digits
    from public.pos_used_device_acquisitions acquisition
    join public.pos_used_devices device on device.acquisition_id = acquisition.id
    join public.store_locations store on store.id = acquisition.store_id
    where acquisition.acquired_at >= since_value
  ),
  -- A seller who keeps coming back is the single strongest signal of stolen
  -- goods being fed through a counter.
  repeat_sellers as (
    select
      recent.*,
      count(*) over (partition by recent.phone_digits) as phone_visits,
      count(*) over (partition by lower(recent.seller_id_reference)) as id_visits
    from recent
    where recent.phone_digits <> ''
  ),
  model_history as (
    select
      lower(device.brand) as brand_key,
      lower(device.model) as model_key,
      avg(device.purchase_cost) as average_cost,
      count(*) as sample_size
    from public.pos_used_devices device
    group by 1, 2
  ),
  sale_amounts as (
    select ledger.device_id, ledger.amount, ledger.created_at
    from public.pos_used_device_transactions ledger
    where ledger.transaction_type = 'sale'
  ),
  flagged as (
    select 'repeat_seller' as kind, 'high' as severity,
      format('%s sold %s devices here in the last %s days', repeat_sellers.seller_name,
        greatest(repeat_sellers.phone_visits, repeat_sellers.id_visits), window_days) as message,
      repeat_sellers.store_code, repeat_sellers.device_code, repeat_sellers.acquisition_code,
      repeat_sellers.acquired_at as at,
      jsonb_build_object('seller_name', repeat_sellers.seller_name, 'seller_phone', repeat_sellers.seller_phone,
        'visits', greatest(repeat_sellers.phone_visits, repeat_sellers.id_visits)) as detail
    from repeat_sellers
    where greatest(repeat_sellers.phone_visits, repeat_sellers.id_visits) >= 3

    union all
    select 'staff_seller', 'high',
      format('The seller name matches active staff member %s', recent.seller_name),
      recent.store_code, recent.device_code, recent.acquisition_code, recent.acquired_at,
      jsonb_build_object('seller_name', recent.seller_name, 'bought_by', recent.acquired_by)
    from recent
    where exists (
      select 1 from public.staff_directory staff
      where staff.active and lower(staff.display_name) = lower(recent.seller_name)
    )

    union all
    select 'blocked_in_stock', 'high',
      'This device failed the lost or stolen check and is still in stock',
      recent.store_code, recent.device_code, recent.acquisition_code, recent.acquired_at,
      jsonb_build_object('clean_check_status', recent.clean_check_status)
    from recent
    where recent.clean_check_status = 'Blocked' and recent.status in ('inspection', 'ready_for_sale')

    union all
    select 'price_outlier', 'medium',
      format('Paid %s for a %s %s against a %s average', to_char(recent.purchase_cost, 'FM999999.00'),
        recent.brand, recent.model, to_char(round(model_history.average_cost, 2), 'FM999999.00')),
      recent.store_code, recent.device_code, recent.acquisition_code, recent.acquired_at,
      jsonb_build_object('purchase_cost', recent.purchase_cost, 'average_cost', round(model_history.average_cost, 2),
        'sample_size', model_history.sample_size)
    from recent
    join model_history on model_history.brand_key = lower(recent.brand) and model_history.model_key = lower(recent.model)
    where model_history.sample_size >= 4
      and recent.purchase_cost > model_history.average_cost * 1.5

    union all
    select 'sold_below_cost', 'medium',
      format('Sold for %s against a %s purchase price', to_char(sale_amounts.amount, 'FM999999.00'),
        to_char(recent.purchase_cost, 'FM999999.00')),
      recent.store_code, recent.device_code, recent.acquisition_code, sale_amounts.created_at,
      jsonb_build_object('sold_amount', sale_amounts.amount, 'purchase_cost', recent.purchase_cost)
    from recent
    join sale_amounts on sale_amounts.device_id = recent.device_id
    where sale_amounts.amount < recent.purchase_cost

    union all
    select 'same_day_flip', 'medium',
      'Bought and sold on the same day',
      recent.store_code, recent.device_code, recent.acquisition_code, recent.sold_at,
      jsonb_build_object('acquired_at', recent.acquired_at, 'sold_at', recent.sold_at)
    from recent
    where recent.sold_at is not null
      and (recent.sold_at at time zone 'Australia/Brisbane')::date
        = (recent.acquired_at at time zone 'Australia/Brisbane')::date

    union all
    select 'missing_intake_evidence', 'medium',
      'No intake photos are attached to this device',
      recent.store_code, recent.device_code, recent.acquisition_code, recent.acquired_at,
      '{}'::jsonb
    from recent
    where recent.evidence_required
      and not exists (
        select 1 from public.pos_used_device_updates entry
        where entry.device_id = recent.device_id and entry.kind = 'photo' and entry.stage = 'intake'
      )

    union all
    select 'stale_imei_check', 'low',
      'The lost or stolen check is still pending a week after the purchase',
      recent.store_code, recent.device_code, recent.acquisition_code, recent.acquired_at,
      '{}'::jsonb
    from recent
    where recent.clean_check_status = 'Pending'
      and recent.status in ('inspection', 'ready_for_sale')
      and recent.acquired_at < now() - interval '7 days'

    union all
    select 'aged_stock', 'low',
      format('Still in stock %s days after purchase',
        extract(day from now() - recent.acquired_at)::integer),
      recent.store_code, recent.device_code, recent.acquisition_code, recent.acquired_at,
      jsonb_build_object('purchase_cost', recent.purchase_cost, 'sale_price', recent.sale_price)
    from recent
    where recent.status in ('inspection', 'ready_for_sale')
      and recent.acquired_at < now() - interval '90 days'
  )
  select coalesce(jsonb_agg(to_jsonb(flagged) order by
    case flagged.severity when 'high' then 1 when 'medium' then 2 else 3 end,
    flagged.at desc
  ), '[]'::jsonb) into alerts_payload
  from flagged;

  return jsonb_build_object('ok', true, 'lookback_days', window_days, 'alerts', alerts_payload);
end;
$$;

-- The POS register against the figures staff key into the daily report by hand.
-- Two records of the same cash movement should agree.
create or replace function public.get_admin_used_device_reconciliation(
  session_token text,
  date_from date default null,
  date_to date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  from_value date := coalesce(date_from, (now() at time zone 'Australia/Brisbane')::date - 30);
  to_value date := coalesce(date_to, (now() at time zone 'Australia/Brisbane')::date);
  rows_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  if from_value > to_value then raise exception 'Start date must not be after end date'; end if;
  if to_value - from_value > 366 then raise exception 'Report range cannot exceed 367 days'; end if;

  with pos_totals as (
    select
      acquisition.store_id,
      (acquisition.acquired_at at time zone 'Australia/Brisbane')::date as business_date,
      count(*)::integer as pos_count,
      round(sum(acquisition.payout_amount), 2) as pos_amount
    from public.pos_used_device_acquisitions acquisition
    where (acquisition.acquired_at at time zone 'Australia/Brisbane')::date between from_value and to_value
    group by 1, 2
  ),
  report_totals as (
    select
      submission.store_id,
      submission.report_date as business_date,
      count(*)::integer as report_count,
      round(sum(coalesce(nullif(regexp_replace(coalesce(line->>'amount', ''), '[^0-9.]', '', 'g'), '')::numeric, 0)), 2) as report_amount
    from public.daily_report_submissions submission
    cross join lateral jsonb_array_elements(coalesce(submission.device_buyback_lines_json, '[]'::jsonb)) line
    where submission.report_date between from_value and to_value
    group by 1, 2
  ),
  combined as (
    select
      coalesce(pos_totals.store_id, report_totals.store_id) as store_id,
      coalesce(pos_totals.business_date, report_totals.business_date) as business_date,
      coalesce(pos_totals.pos_count, 0) as pos_count,
      coalesce(pos_totals.pos_amount, 0) as pos_amount,
      coalesce(report_totals.report_count, 0) as report_count,
      coalesce(report_totals.report_amount, 0) as report_amount
    from pos_totals
    full join report_totals
      on report_totals.store_id = pos_totals.store_id
      and report_totals.business_date = pos_totals.business_date
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'store_code', store.store_code,
    'store_name', store.store_name,
    'business_date', combined.business_date,
    'pos_count', combined.pos_count,
    'pos_amount', combined.pos_amount,
    'report_count', combined.report_count,
    'report_amount', combined.report_amount,
    'count_difference', combined.pos_count - combined.report_count,
    'amount_difference', round(combined.pos_amount - combined.report_amount, 2)
  ) order by combined.business_date desc, store.store_name), '[]'::jsonb) into rows_payload
  from combined
  join public.store_locations store on store.id = combined.store_id
  where combined.pos_count <> combined.report_count
     or round(combined.pos_amount - combined.report_amount, 2) <> 0;

  return jsonb_build_object('ok', true, 'date_from', from_value, 'date_to', to_value, 'rows', rows_payload);
end;
$$;

-- The admin portal calls these straight from the browser, exactly as it calls
-- get_admin_sales_overview. The admin session token inside each function is the
-- gate; the anon role by itself opens nothing.
revoke all on function public.get_admin_used_device_overview(text, date, date) from public;
revoke all on function public.get_admin_used_device_register(text, jsonb) from public;
revoke all on function public.get_admin_used_device_alerts(text, integer) from public;
revoke all on function public.get_admin_used_device_reconciliation(text, date, date) from public;

grant execute on function public.get_admin_used_device_overview(text, date, date) to anon, authenticated;
grant execute on function public.get_admin_used_device_register(text, jsonb) to anon, authenticated;
grant execute on function public.get_admin_used_device_alerts(text, integer) to anon, authenticated;
grant execute on function public.get_admin_used_device_reconciliation(text, date, date) to anon, authenticated;

comment on function public.get_admin_used_device_register(text, jsonb) is
  'Admin-session-only second-hand dealer register. Carries seller identity details and is never exposed to a staff session.';
