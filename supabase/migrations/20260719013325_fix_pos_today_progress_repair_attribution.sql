-- Preserve the staff member who completed a repair when another employee later checks it out.

create or replace function public.pos_repair_completion_staff(ticket_row public.pos_repair_tickets)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (
      select nullif(trim(activity_item.value->>'staffName'), '')
      from jsonb_array_elements(coalesce(ticket_row.activity, '[]'::jsonb)) activity_item(value)
      where lower(coalesce(activity_item.value->>'type', '')) = 'status'
        and lower(coalesce(activity_item.value->>'text', '')) like '% to waiting pickup'
      order by nullif(activity_item.value->>'at', '') desc nulls last
      limit 1
    ),
    nullif(trim(ticket_row.updated_by), ''),
    nullif(trim(ticket_row.created_by), ''),
    'Unknown staff'
  );
$$;

create or replace function public.pos_today_progress_payload(
  target_store_id bigint,
  target_business_date date,
  target_staff_name text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  selected_target public.pos_daily_targets%rowtype;
  staff_value text := trim(coalesce(target_staff_name, ''));
  date_value date := coalesce(target_business_date, (now() at time zone 'Australia/Brisbane')::date);
  revenue_target_value numeric(12,2) := 1000;
  repair_target_value integer := 10;
  glass_target_value integer := 10;
  revenue_points_value integer := 30;
  repair_points_value integer := 20;
  glass_points_value integer := 20;
  bonus_rate_value numeric(12,2) := 1;
  target_scope_value text := 'system_default';
  progress_payload jsonb;
begin
  if target_store_id is null then raise exception 'Store is required'; end if;
  if staff_value = '' then raise exception 'Staff member is required'; end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.id = target_store_id
    and store_location.active = true
    and store_location.store_code <> 'warehouse';
  if not found then raise exception 'Store not found'; end if;

  select * into selected_target
  from public.pos_daily_targets target
  where target.store_id = selected_store.id
    and target.active = true
    and (target.business_date is null or target.business_date = date_value)
    and (target.normalized_staff_name = '' or target.normalized_staff_name = lower(staff_value))
  order by
    (target.business_date is not null) desc,
    (target.normalized_staff_name <> '') desc,
    target.updated_at desc
  limit 1;

  if found then
    revenue_target_value := selected_target.revenue_target;
    repair_target_value := selected_target.repair_target;
    glass_target_value := selected_target.glass_target;
    revenue_points_value := selected_target.revenue_points;
    repair_points_value := selected_target.repair_points;
    glass_points_value := selected_target.glass_points;
    bonus_rate_value := selected_target.bonus_dollars_per_point;
    target_scope_value := case
      when selected_target.business_date is not null and selected_target.normalized_staff_name <> '' then 'staff_date'
      when selected_target.business_date is not null then 'store_date'
      when selected_target.normalized_staff_name <> '' then 'staff_default'
      else 'store_default'
    end;
  end if;

  with sale_orders as (
    select sales_order.*
    from public.pos_sales_orders sales_order
    where sales_order.store_id = selected_store.id
      and sales_order.business_date = date_value
      and lower(trim(sales_order.staff_name)) = lower(staff_value)
  ),
  sale_summary as (
    select
      coalesce(sum(sales_order.total), 0)::numeric(12,2) as gross_sales,
      count(*)::integer as invoice_count
    from sale_orders sales_order
  ),
  attributed_refunds as (
    select refund.*
    from public.pos_sales_refunds refund
    join public.pos_sales_orders original_order on original_order.id = refund.sales_order_id
    where refund.store_id = selected_store.id
      and (refund.created_at at time zone 'Australia/Brisbane')::date = date_value
      and lower(trim(original_order.staff_name)) = lower(staff_value)
  ),
  refund_summary as (
    select
      coalesce(sum(refund.amount), 0)::numeric(12,2) as refund_amount,
      count(*)::integer as refund_count
    from attributed_refunds refund
  ),
  glass_sale_lines as (
    select sales_line.*
    from public.pos_sales_order_lines sales_line
    join sale_orders sales_order on sales_order.id = sales_line.sales_order_id
    where regexp_replace(lower(trim(sales_line.category)), '[^a-z0-9]+', '', 'g') in (
      'screenprotector',
      'screenprotectors',
      'temperedglass',
      'temperedglassprotector',
      'temperedglassprotectors'
    )
  ),
  glass_sales as (
    select coalesce(sum(sales_line.quantity), 0)::integer as units
    from glass_sale_lines sales_line
  ),
  glass_refund_lines as (
    select
      sales_line.id,
      sales_line.quantity,
      sales_line.unit_price,
      sales_line.line_total,
      sum(refund_line.amount)::numeric(12,2) as refunded_amount
    from public.pos_sales_refund_lines refund_line
    join attributed_refunds refund on refund.id = refund_line.refund_id
    join public.pos_sales_order_lines sales_line on sales_line.id = refund_line.sales_order_line_id
    where regexp_replace(lower(trim(sales_line.category)), '[^a-z0-9]+', '', 'g') in (
      'screenprotector',
      'screenprotectors',
      'temperedglass',
      'temperedglassprotector',
      'temperedglassprotectors'
    )
    group by sales_line.id, sales_line.quantity, sales_line.unit_price, sales_line.line_total
  ),
  glass_refunds as (
    select coalesce(sum(
      case
        when glass_line.refunded_amount >= glass_line.line_total then glass_line.quantity
        when glass_line.unit_price > 0 then least(
          glass_line.quantity,
          greatest(1, round(glass_line.refunded_amount / glass_line.unit_price)::integer)
        )
        else 0
      end
    ), 0)::integer as units
    from glass_refund_lines glass_line
  ),
  repair_summary as (
    select count(*)::integer as completed_count
    from public.pos_repair_tickets repair_ticket
    where repair_ticket.store_id = selected_store.id
      and repair_ticket.ready_for_pickup_at is not null
      and (repair_ticket.ready_for_pickup_at at time zone 'Australia/Brisbane')::date = date_value
      and lower(public.pos_repair_completion_staff(repair_ticket)) = lower(staff_value)
      and coalesce(repair_ticket.resolution, 'repaired') = 'repaired'
  ),
  metrics as (
    select
      sale_summary.gross_sales,
      refund_summary.refund_amount,
      sale_summary.gross_sales - refund_summary.refund_amount as net_sales,
      sale_summary.invoice_count,
      refund_summary.refund_count,
      case
        when sale_summary.invoice_count > 0 then round(sale_summary.gross_sales / sale_summary.invoice_count, 2)
        else 0
      end as average_sale,
      greatest(0, glass_sales.units - glass_refunds.units)::integer as glass_count,
      repair_summary.completed_count as repair_count
    from sale_summary, refund_summary, glass_sales, glass_refunds, repair_summary
  ),
  scored as (
    select
      metrics.*,
      (case when revenue_target_value > 0 and metrics.net_sales >= revenue_target_value then revenue_points_value else 0 end)
        + (case when repair_target_value > 0 and metrics.repair_count >= repair_target_value then repair_points_value else 0 end)
        + (case when glass_target_value > 0 and metrics.glass_count >= glass_target_value then glass_points_value else 0 end) as earned_points
    from metrics
  )
  select jsonb_build_object(
    'ok', true,
    'status', 'projected',
    'store_code', selected_store.store_code,
    'store_name', selected_store.store_name,
    'business_date', date_value,
    'staff_name', staff_value,
    'target_scope', target_scope_value,
    'target', jsonb_build_object(
      'revenue', revenue_target_value,
      'repairs', repair_target_value,
      'glass', glass_target_value,
      'revenue_points', revenue_points_value,
      'repair_points', repair_points_value,
      'glass_points', glass_points_value,
      'bonus_dollars_per_point', bonus_rate_value
    ),
    'metrics', jsonb_build_object(
      'gross_sales', scored.gross_sales,
      'refunds', scored.refund_amount,
      'net_sales', scored.net_sales,
      'invoice_count', scored.invoice_count,
      'refund_count', scored.refund_count,
      'average_sale', scored.average_sale,
      'repair_count', scored.repair_count,
      'glass_count', scored.glass_count
    ),
    'score', jsonb_build_object(
      'earned_points', scored.earned_points,
      'max_points',
        (case when revenue_target_value > 0 then revenue_points_value else 0 end)
        + (case when repair_target_value > 0 then repair_points_value else 0 end)
        + (case when glass_target_value > 0 then glass_points_value else 0 end),
      'projected_bonus', round(scored.earned_points * bonus_rate_value, 2)
    ),
    'last_updated_at', now()
  ) into progress_payload
  from scored;

  return progress_payload;
end;
$$;

create or replace function public.finalize_pos_daily_target_results()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  staff_record record;
  progress_payload jsonb;
begin
  if new.status <> 'closed' or old.status = 'closed' then return new; end if;

  for staff_record in
    select distinct staff_name
    from (
      select trim(sales_order.staff_name) as staff_name
      from public.pos_sales_orders sales_order
      where sales_order.store_id = new.store_id
        and sales_order.business_date = new.business_date
      union all
      select public.pos_repair_completion_staff(repair_ticket) as staff_name
      from public.pos_repair_tickets repair_ticket
      where repair_ticket.store_id = new.store_id
        and repair_ticket.ready_for_pickup_at is not null
        and (repair_ticket.ready_for_pickup_at at time zone 'Australia/Brisbane')::date = new.business_date
        and coalesce(repair_ticket.resolution, 'repaired') = 'repaired'
      union all select trim(new.opened_by)
      union all select trim(new.current_staff_name)
      union all select trim(new.last_staff_name)
      union all select trim(coalesce(new.closed_by, ''))
    ) staff_names
    where staff_name <> ''
  loop
    progress_payload := public.pos_today_progress_payload(new.store_id, new.business_date, staff_record.staff_name);
    progress_payload := progress_payload || jsonb_build_object(
      'status', 'finalized',
      'finalized_at', coalesce(new.closed_at, now()),
      'finalized_by', coalesce(new.closed_by, new.last_staff_name),
      'shift_code', new.shift_code
    );

    insert into public.pos_daily_target_results (
      store_id,
      business_date,
      staff_name,
      shift_code,
      progress_payload,
      finalized_by,
      finalized_at
    ) values (
      new.store_id,
      new.business_date,
      staff_record.staff_name,
      new.shift_code,
      progress_payload,
      coalesce(new.closed_by, new.last_staff_name),
      coalesce(new.closed_at, now())
    )
    on conflict (store_id, business_date, normalized_staff_name)
    do update set
      staff_name = excluded.staff_name,
      shift_code = excluded.shift_code,
      progress_payload = excluded.progress_payload,
      finalized_by = excluded.finalized_by,
      finalized_at = excluded.finalized_at,
      updated_at = now();
  end loop;

  return new;
end;
$$;

revoke execute on function public.pos_repair_completion_staff(public.pos_repair_tickets) from public, anon, authenticated;
revoke execute on function public.pos_today_progress_payload(bigint, date, text) from public, anon, authenticated;
revoke execute on function public.finalize_pos_daily_target_results() from public, anon, authenticated;
