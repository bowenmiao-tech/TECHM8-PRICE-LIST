-- Adds "sales per hour this month" for the signed-in staff member to the POS
-- Today score card. Hours come from the daily report timesheet; a day with no
-- usable timesheet row falls back to the store shift span (open shifts count
-- up to now, so today's rate is live before the daily report is submitted).

-- Staff type times as 9, 09, 9.5, 9.20, 10:30 or 1030. Two digits after a dot
-- or colon are minutes; one digit after a dot is a decimal hour.
create or replace function public.pos_timesheet_clock_hours(raw_value text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case
    when parsed.hours between 0 and 24 then parsed.hours
  end
  from (
    select case
      when input.value ~ '^\d{1,2}:\d{2}$' then
        case when split_part(input.value, ':', 2)::integer < 60
          then split_part(input.value, ':', 1)::numeric + split_part(input.value, ':', 2)::numeric / 60 end
      when input.value ~ '^\d{3,4}$' then
        case when input.value::integer % 100 < 60
          then (input.value::integer / 100)::numeric + (input.value::integer % 100)::numeric / 60 end
      when input.value ~ '^\d{1,2}\.\d{2}$' then
        case when split_part(input.value, '.', 2)::integer < 60
          then split_part(input.value, '.', 1)::numeric + split_part(input.value, '.', 2)::numeric / 60 end
      when input.value ~ '^\d{1,2}(\.\d)?$' then input.value::numeric
    end as hours
    from (select trim(coalesce(raw_value, '')) as value) input
  ) parsed;
$$;

-- An end time before the start time is read as afternoon (9 to 5 = 8 hours).
-- Breaks over 3 hours are typos and are ignored; rows outside 0-16 hours are
-- rejected rather than guessed.
create or replace function public.pos_timesheet_line_hours(start_text text, end_text text, break_text text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case
    when worked.hours > 0 and worked.hours <= 16 then round(worked.hours, 2)
  end
  from (
    select
      case
        when times.start_hours is null or times.end_hours is null then null
        when times.end_hours <= times.start_hours and times.end_hours < 12 then times.end_hours + 12 - times.start_hours
        else times.end_hours - times.start_hours
      end - coalesce(times.break_hours, 0) as hours
    from (
      select
        public.pos_timesheet_clock_hours(start_text) as start_hours,
        public.pos_timesheet_clock_hours(end_text) as end_hours,
        case
          when trim(coalesce(break_text, '')) ~ '^\d*\.?\d+$' and trim(break_text)::numeric <= 3
            then trim(break_text)::numeric
        end as break_hours
    ) times
  ) worked;
$$;

create or replace function public.pos_staff_month_hourly_sales(
  target_staff_name text,
  target_business_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  staff_key text := lower(trim(coalesce(target_staff_name, '')));
  today_value date := (now() at time zone 'Australia/Brisbane')::date;
  date_value date := coalesce(target_business_date, (now() at time zone 'Australia/Brisbane')::date);
  month_value date;
  gross_sales_value numeric(12,2) := 0;
  refunds_value numeric(12,2) := 0;
  net_sales_value numeric(12,2) := 0;
  timesheet_hours_value numeric := 0;
  shift_hours_value numeric := 0;
  hours_value numeric := 0;
  days_value integer := 0;
begin
  if staff_key = '' then raise exception 'Staff member is required'; end if;
  month_value := date_trunc('month', date_value)::date;

  -- Same definition as the admin sales overview (order totals less refunds),
  -- limited to this staff member across every store.
  select coalesce(sum(sales_order.total), 0)
  into gross_sales_value
  from public.pos_sales_orders sales_order
  where sales_order.business_date between month_value and date_value
    and lower(trim(sales_order.staff_name)) = staff_key;

  select coalesce(sum(refund.amount), 0)
  into refunds_value
  from public.pos_sales_refunds refund
  join public.pos_sales_orders original_order on original_order.id = refund.sales_order_id
  where coalesce(refund.business_date, (refund.created_at at time zone 'Australia/Brisbane')::date)
      between month_value and date_value
    and lower(trim(original_order.staff_name)) = staff_key;

  net_sales_value := gross_sales_value - refunds_value;

  with timesheet_rows as (
    select
      submission.report_date,
      submission.store_id,
      public.pos_timesheet_line_hours(line->>'start_time', line->>'end_time', line->>'break_time') as hours
    from public.daily_report_submissions submission
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(submission.end_of_day_json->'timesheet_lines') = 'array'
        then submission.end_of_day_json->'timesheet_lines' else '[]'::jsonb end
    ) line
    where submission.report_date between month_value and date_value
      and lower(trim(coalesce(nullif(trim(line->>'name'), ''), submission.staff_name))) = staff_key
  ),
  -- A colleague may list the same person on their own report; count one row
  -- per store per day.
  timesheet_days as (
    select timesheet_row.report_date, timesheet_row.store_id, max(timesheet_row.hours) as hours
    from timesheet_rows timesheet_row
    where timesheet_row.hours is not null
    group by timesheet_row.report_date, timesheet_row.store_id
  ),
  timesheet_by_date as (
    select timesheet_day.report_date, sum(timesheet_day.hours) as hours
    from timesheet_days timesheet_day
    group by timesheet_day.report_date
  ),
  -- Shifts closed by the midnight reset have no real end time, so they only
  -- count while they are still running today.
  shift_spans as (
    select
      shift_record.business_date,
      min(shift_record.opened_at) as started_at,
      max(case
        when shift_record.closed_at is not null and coalesce(shift_record.closed_by, '') <> 'System daily reset'
          then least(shift_record.closed_at, now())
        when shift_record.business_date = today_value then now()
      end) as ended_at
    from public.pos_store_shifts shift_record
    where shift_record.business_date between month_value and date_value
      and (lower(trim(coalesce(shift_record.opened_by, ''))) = staff_key
        or lower(trim(coalesce(shift_record.current_staff_name, ''))) = staff_key)
    group by shift_record.business_date
  ),
  shift_by_date as (
    select
      shift_span.business_date,
      least(16, extract(epoch from (shift_span.ended_at - shift_span.started_at)) / 3600) as hours
    from shift_spans shift_span
    where shift_span.ended_at > shift_span.started_at
      and not exists (
        select 1 from timesheet_by_date timesheet_date
        where timesheet_date.report_date = shift_span.business_date
      )
  )
  select
    coalesce((select sum(timesheet_date.hours) from timesheet_by_date timesheet_date), 0),
    coalesce((select sum(shift_date.hours) from shift_by_date shift_date), 0),
    (select count(*) from timesheet_by_date) + (select count(*) from shift_by_date)
  into timesheet_hours_value, shift_hours_value, days_value;

  hours_value := timesheet_hours_value + shift_hours_value;

  return jsonb_build_object(
    'month', to_char(month_value, 'YYYY-MM'),
    'date_from', month_value,
    'date_to', date_value,
    'gross_sales', gross_sales_value,
    'refunds', refunds_value,
    'net_sales', net_sales_value,
    'hours', round(hours_value, 2),
    'timesheet_hours', round(timesheet_hours_value, 2),
    'shift_hours', round(shift_hours_value, 2),
    'days_worked', days_value,
    'sales_per_hour', case when hours_value > 0 then round(net_sales_value / hours_value, 2) end
  );
end;
$$;

create or replace function public.get_pos_today_progress(
  session_token text,
  target_store_code text,
  target_staff_name text,
  target_business_date date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  staff_value text := trim(coalesce(target_staff_name, ''));
  date_value date := coalesce(target_business_date, (now() at time zone 'Australia/Brisbane')::date);
  finalized_result public.pos_daily_target_results%rowtype;
  has_open_shift boolean := false;
  progress_payload jsonb;
  monthly_hourly_sales jsonb;
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;
  if staff_value = '' then raise exception 'Staff member is required'; end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = coalesce(trim(target_store_code), '')
    and store_location.store_code <> 'warehouse';
  if not found then raise exception 'Store not found'; end if;

  -- Kept outside the finalized snapshot so the monthly figure stays current
  -- after the shift closes.
  monthly_hourly_sales := public.pos_staff_month_hourly_sales(staff_value, date_value);

  select exists (
    select 1
    from public.pos_store_shifts shift_record
    where shift_record.store_id = selected_store.id
      and shift_record.business_date = date_value
      and shift_record.status = 'open'
  ) into has_open_shift;

  if not has_open_shift then
    select * into finalized_result
    from public.pos_daily_target_results result
    where result.store_id = selected_store.id
      and result.business_date = date_value
      and result.normalized_staff_name = lower(staff_value)
    order by result.finalized_at desc
    limit 1;

    if found then
      return finalized_result.progress_payload || jsonb_build_object(
        'status', 'finalized',
        'finalized_at', finalized_result.finalized_at,
        'finalized_by', finalized_result.finalized_by,
        'shift_code', finalized_result.shift_code,
        'monthly_hourly_sales', monthly_hourly_sales
      );
    end if;
  end if;

  progress_payload := public.pos_today_progress_payload(selected_store.id, date_value, staff_value);
  return progress_payload || jsonb_build_object(
    'status', 'projected',
    'monthly_hourly_sales', monthly_hourly_sales
  );
end;
$$;

revoke execute on function public.pos_timesheet_clock_hours(text) from public, anon, authenticated;
revoke execute on function public.pos_timesheet_line_hours(text, text, text) from public, anon, authenticated;
revoke execute on function public.pos_staff_month_hourly_sales(text, date) from public, anon, authenticated;
