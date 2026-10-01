-- Admin-only item sales report. Sales use invoice dates; refunds use processed dates.
-- Revenue is ex GST, matching RepairDesk's Total / Net Profit columns.
create or replace function public.get_admin_sales_by_item(
  session_token text,
  date_from date default null,
  date_to date default null,
  target_store_code text default null,
  target_type text default null,
  criteria_field text default null,
  criteria_query text default null,
  page_limit integer default 50,
  page_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  from_value date := coalesce(date_from, (now() at time zone 'Australia/Brisbane')::date);
  to_value date := coalesce(date_to, date_from, (now() at time zone 'Australia/Brisbane')::date);
  store_value text := lower(coalesce(trim(target_store_code), ''));
  type_value text := lower(coalesce(trim(target_type), ''));
  field_value text := lower(coalesce(trim(criteria_field), ''));
  query_value text := lower(coalesce(trim(criteria_query), ''));
  limit_value integer := least(greatest(coalesce(page_limit, 50), 1), 1000);
  offset_value integer := greatest(coalesce(page_offset, 0), 0);
  result_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  if from_value > to_value then raise exception 'Start date must not be after end date'; end if;
  if to_value - from_value > 3653 then raise exception 'Report range cannot exceed ten years'; end if;
  if store_value <> '' and store_value <> all (array['parkridge','fairfield','northlakes','toowong']::text[]) then
    raise exception 'Store is not available';
  end if;
  if type_value <> '' and type_value <> all (array['repairs','products','trade-in','unlocking','miscellaneous','membership']::text[]) then
    raise exception 'Invalid item type';
  end if;
  if field_value <> '' and field_value <> all (array['product_name','repair_category','category','brand','model']::text[]) then
    raise exception 'Invalid criterion';
  end if;

  with source_lines as materialized (
    select
      line.id, line.sales_order_id, line.product_id, line.sku, line.name,
      line.quantity::numeric quantity, line.line_total,
      sales_order.business_date, store.store_code, store.store_name,
      case
        when line.line_type = 'repair' then 'Repairs'
        when line.line_type = 'used_device' then 'Trade-in'
        when line.line_type in ('product','retail') then 'Products'
        else 'Miscellaneous'
      end item_type,
      case when line.line_type = 'repair' then nullif(nullif(line.category, 'Repair'), '') else null end repair_category,
      case when line.line_type in ('product','retail','used_device') then nullif(line.category, '') else null end category,
      coalesce(nullif(nullif(line.line_payload->>'source_manufacturer', '-'), ''), nullif(device.brand, '')) brand,
      coalesce(nullif(nullif(line.line_payload->>'source_device', '-'), ''), nullif(device.model, '')) model,
      case
        when coalesce(line.line_payload->>'source_total_sales_ex_gst','') ~ '^[0-9]+([.][0-9]+)?$'
          then (line.line_payload->>'source_total_sales_ex_gst')::numeric
        else round(line.line_total / 1.1, 2)
      end revenue_ex_gst,
      case
        when coalesce(line.line_payload->>'source_cogs','') ~ '^[0-9]+([.][0-9]+)?$'
          then (line.line_payload->>'source_cogs')::numeric
        when coalesce(line.line_payload->>'unit_cost_ex_gst','') ~ '^[0-9]+([.][0-9]+)?$'
          then (line.line_payload->>'unit_cost_ex_gst')::numeric * line.quantity
        when device.id is not null then device.purchase_cost
        else null
      end cost_ex_gst
    from public.pos_sales_order_lines line
    join public.pos_sales_orders sales_order on sales_order.id = line.sales_order_id
    join public.store_locations store on store.id = sales_order.store_id
    left join public.pos_used_devices device on device.id = line.used_device_id
    where store.active
      and store.store_code = any (array['parkridge','fairfield','northlakes','toowong']::text[])
      and (store_value = '' or store.store_code = store_value)
  ),
  movements as materialized (
    select source.*, source.quantity movement_quantity,
      source.revenue_ex_gst movement_revenue, source.cost_ex_gst movement_cost
    from source_lines source
    where source.business_date between from_value and to_value
    union all
    select source.*, -coalesce(nullif(refund_line.returned_quantity, 0)::numeric,
        source.quantity * refund_line.amount / nullif(source.line_total, 0), 0) movement_quantity,
      -round(refund_line.amount / 1.1, 2) movement_revenue,
      -source.cost_ex_gst * coalesce(nullif(refund_line.returned_quantity, 0)::numeric / nullif(source.quantity, 0),
        refund_line.amount / nullif(source.line_total, 0), 0) movement_cost
    from source_lines source
    join public.pos_sales_refund_lines refund_line on refund_line.sales_order_line_id = source.id
    join public.pos_sales_refunds refund on refund.id = refund_line.refund_id
    where coalesce(refund.business_date, (refund.created_at at time zone 'Australia/Brisbane')::date)
      between from_value and to_value
  ),
  filtered as materialized (
    select *, case when item_type = 'Repairs' then name else coalesce(nullif(product_id,''),nullif(sku,''),name) end item_key
    from movements
    where (type_value = '' or lower(item_type) = type_value)
      and (query_value = '' or field_value = '' or
        lower(case field_value
          when 'product_name' then name
          when 'repair_category' then repair_category
          when 'category' then category
          when 'brand' then brand
          when 'model' then model
          else '' end) like '%' || query_value || '%')
  ),
  grouped as materialized (
    select store_code, store_name, item_type, item_key, repair_category, category, brand, model, name product_name,
      round(sum(movement_quantity), 2) qty,
      round(sum(movement_revenue), 2) total,
      case when count(*) filter (where movement_cost is null) = 0 then round(sum(movement_cost), 2) else null end cogs,
      count(*) filter (where movement_cost is null) unknown_cost_lines
    from filtered
    group by store_code,store_name,item_type,item_key,repair_category,category,brand,model,name
  ),
  totals as (
    select count(*)::integer row_count, coalesce(round(sum(qty),2),0) qty,
      coalesce(round(sum(total),2),0) total,
      case when coalesce(sum(unknown_cost_lines),0)=0 then coalesce(round(sum(cogs),2),0) else null end cogs,
      coalesce(sum(unknown_cost_lines),0)::integer unknown_cost_lines
    from grouped
  )
  select jsonb_build_object(
    'ok',true,'date_from',from_value,'date_to',to_value,'generated_at',now(),
    'row_count',totals.row_count,
    'totals',jsonb_build_object('qty',totals.qty,'total',totals.total,'cogs',totals.cogs,
      'net_profit',case when totals.cogs is null then null else round(totals.total-totals.cogs,2) end,
      'margin',case when totals.cogs is null or totals.total=0 then null else round((totals.total-totals.cogs)*100/totals.total,2) end,
      'unknown_cost_lines',totals.unknown_cost_lines),
    'rows',coalesce((select jsonb_agg(jsonb_build_object(
      'store_code',page.store_code,'store_name',page.store_name,'type',page.item_type,
      'repair_category',page.repair_category,'category',page.category,'brand',page.brand,'model',page.model,
      'product_name',page.product_name,'qty',page.qty,'total',page.total,'cogs',page.cogs,
      'net_profit',case when page.cogs is null then null else round(page.total-page.cogs,2) end,
      'margin',case when page.cogs is null or page.total=0 then null else round((page.total-page.cogs)*100/page.total,2) end,
      'unknown_cost_lines',page.unknown_cost_lines
    ) order by page.qty desc,page.total desc,page.product_name)
      from (select * from grouped order by qty desc,total desc,product_name limit limit_value offset offset_value) page),'[]'::jsonb)
  ) into result_payload
  from totals;
  return result_payload;
end;
$$;

revoke execute on function public.get_admin_sales_by_item(text,date,date,text,text,text,text,integer,integer)
  from public,anon,authenticated;
grant execute on function public.get_admin_sales_by_item(text,date,date,text,text,text,text,integer,integer)
  to anon,authenticated,service_role;

comment on function public.get_admin_sales_by_item(text,date,date,text,text,text,text,integer,integer) is
  'Admin-session item sales report, ex GST, with processed refunds and explicit unknown cost values.';
