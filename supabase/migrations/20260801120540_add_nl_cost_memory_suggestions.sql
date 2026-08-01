create extension if not exists pg_trgm with schema extensions;

create or replace function public.normalize_nl_product_name(input_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select trim(regexp_replace(lower(coalesce(input_name, '')), '[^a-z0-9]+', ' ', 'g'));
$$;

create or replace function public.get_nl_cost_suggestion(target_item_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_item public.nl_sales_items%rowtype;
  target_name text;
  suggestion jsonb;
begin
  select * into target_item
  from public.nl_sales_items
  where id = target_item_id;

  if not found
    or (target_item.category = 'repair' and target_item.stock_action <> 'sold')
    or target_item.cost_unit_price_ex_gst is not null then
    return null;
  end if;

  target_name := public.normalize_nl_product_name(target_item.product_name);
  if target_name = '' then return null; end if;

  with candidates as (
    select
      source_item.id as source_item_id,
      source_item.product_name as source_product_name,
      source_item.cost_unit_price_ex_gst,
      source_report.report_date as source_report_date,
      source_item.cost_updated_at,
      case
        when target_item.category = 'repair'
          and target_item.lcd_inventory_item_id is not null
          and source_item.category = 'repair'
          and source_item.lcd_inventory_item_id = target_item.lcd_inventory_item_id
          then 0
        when source_item.category = target_item.category
          and public.normalize_nl_product_name(source_item.product_name) = target_name
          then 1
        when source_item.category = target_item.category then 2
        else 99
      end as match_rank,
      case
        when target_item.category = 'repair'
          and target_item.lcd_inventory_item_id is not null
          and source_item.category = 'repair'
          and source_item.lcd_inventory_item_id = target_item.lcd_inventory_item_id
          then 1::real
        when source_item.category = target_item.category
          and public.normalize_nl_product_name(source_item.product_name) = target_name
          then 1::real
        else extensions.similarity(
          public.normalize_nl_product_name(source_item.product_name),
          target_name
        )
      end as confidence
    from public.nl_sales_items source_item
    join public.nl_sales_reports source_report on source_report.id = source_item.report_id
    where source_item.id <> target_item.id
      and source_item.cost_unit_price_ex_gst is not null
      and source_report.status in ('confirmed', 'settled')
      and (source_item.category = 'accessory' or source_item.stock_action = 'sold')
      and source_item.category = target_item.category
  ), best_match as (
    select *
    from candidates
    where match_rank < 2 or (match_rank = 2 and confidence >= 0.62)
    order by match_rank, confidence desc, source_report_date desc,
      cost_updated_at desc nulls last, source_item_id desc
    limit 1
  )
  select jsonb_build_object(
    'cost_unit_price_ex_gst', cost_unit_price_ex_gst,
    'match_type', case match_rank
      when 0 then 'lcd_item'
      when 1 then 'exact_name'
      else 'similar_name'
    end,
    'confidence', round(confidence::numeric, 2),
    'source_product_name', source_product_name,
    'source_report_date', source_report_date
  )
  into suggestion
  from best_match;

  return suggestion;
end;
$$;

create or replace function public.get_nl_sales_report_admin_json(target_report_id bigint)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  with base as (
    select public.get_nl_sales_report_json(target_report_id) as payload
  )
  select base.payload || jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(
        item.value || jsonb_build_object(
          'cost_suggestion', case
            when item.value->>'cost_unit_price_ex_gst' is null
              and coalesce((item.value->>'is_billable')::boolean, false)
              then public.get_nl_cost_suggestion((item.value->>'id')::bigint)
            else null
          end
        )
        order by (item.value->>'line_order')::integer, (item.value->>'id')::bigint
      )
      from jsonb_array_elements(coalesce(base.payload->'items', '[]'::jsonb)) item
    ), '[]'::jsonb)
  )
  from base;
$$;

create or replace function public.get_nl_sales_reports_admin(
  session_token text,
  date_from text default null,
  date_to text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  from_date_value date;
  to_date_value date;
  reports_json jsonb;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;

  to_date_value := coalesce(
    nullif(date_to, '')::date,
    (now() at time zone 'Australia/Brisbane')::date
  );
  from_date_value := coalesce(
    nullif(date_from, '')::date,
    date_trunc('month', to_date_value)::date
  );

  if from_date_value > to_date_value then
    raise exception 'From date cannot be after to date';
  end if;
  if to_date_value - from_date_value > 366 then
    raise exception 'Date range cannot exceed 366 days';
  end if;

  select coalesce(jsonb_agg(
    public.get_nl_sales_report_admin_json(report.id)
    order by report.report_date desc, report.id desc
  ), '[]'::jsonb)
  into reports_json
  from public.nl_sales_reports report
  join public.store_locations store on store.id = report.store_id
  where store.store_code = 'northlakes'
    and report.report_date between from_date_value and to_date_value;

  return jsonb_build_object('ok', true, 'reports', reports_json);
end;
$$;

revoke all on function public.normalize_nl_product_name(text) from public, anon, authenticated;
revoke all on function public.get_nl_cost_suggestion(bigint) from public, anon, authenticated;
revoke all on function public.get_nl_sales_report_admin_json(bigint) from public, anon, authenticated;
revoke all on function public.get_nl_sales_reports_admin(text, text, text) from public;
grant execute on function public.get_nl_sales_reports_admin(text, text, text) to anon, authenticated;
