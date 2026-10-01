-- POS shift open/close times are minute-accurate where staff close the shift
-- themselves, while timesheets are usually rounded to the hour. Use the shift
-- span first (less that day's timesheet break) and fall back to the timesheet
-- only on days the shift was left for the midnight reset.

-- [0-9] rather than \d so a non-ASCII digit can never reach a numeric cast.
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
      when input.value ~ '^[0-9]{1,2}:[0-9]{2}$' then
        case when split_part(input.value, ':', 2)::integer < 60
          then split_part(input.value, ':', 1)::numeric + split_part(input.value, ':', 2)::numeric / 60 end
      when input.value ~ '^[0-9]{3,4}$' then
        case when input.value::integer % 100 < 60
          then (input.value::integer / 100)::numeric + (input.value::integer % 100)::numeric / 60 end
      when input.value ~ '^[0-9]{1,2}\.[0-9]{2}$' then
        case when split_part(input.value, '.', 2)::integer < 60
          then split_part(input.value, '.', 1)::numeric + split_part(input.value, '.', 2)::numeric / 60 end
      when input.value ~ '^[0-9]{1,2}(\.[0-9])?$' then input.value::numeric
    end as hours
    from (select trim(coalesce(raw_value, '')) as value) input
  ) parsed;
$$;

-- Breaks over 3 hours are typos and are ignored.
create or replace function public.pos_timesheet_break_hours(raw_value text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case
    when input.value ~ '^[0-9]{0,2}\.?[0-9]+$' then
      case when input.value::numeric <= 3 then input.value::numeric end
  end
  from (select trim(coalesce(raw_value, '')) as value) input;
$$;

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
        public.pos_timesheet_break_hours(break_text) as break_hours
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
      public.pos_timesheet_line_hours(line->>'start_time', line->>'end_time', line->>'break_time') as hours,
      public.pos_timesheet_break_hours(line->>'break_time') as break_hours
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
    select
      timesheet_row.report_date,
      timesheet_row.store_id,
      max(timesheet_row.hours) as hours,
      max(timesheet_row.break_hours) as break_hours
    from timesheet_rows timesheet_row
    group by timesheet_row.report_date, timesheet_row.store_id
  ),
  timesheet_by_date as (
    select
      timesheet_day.report_date,
      sum(timesheet_day.hours) as hours,
      sum(timesheet_day.break_hours) as break_hours
    from timesheet_days timesheet_day
    group by timesheet_day.report_date
  ),
  -- Shifts closed by the midnight reset have no real end time, so they only
  -- count while they are still running today. Only shifts the person opened
  -- count: taking over an earlier shift (often one opened after midnight)
  -- records no takeover time, so that day falls back to the timesheet.
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
      and lower(trim(coalesce(shift_record.opened_by, ''))) = staff_key
    group by shift_record.business_date
  ),
  shift_by_date as (
    select
      shift_span.business_date,
      least(16, extract(epoch from (shift_span.ended_at - shift_span.started_at)) / 3600) as hours
    from shift_spans shift_span
    where shift_span.ended_at > shift_span.started_at
  ),
  worked_days as (
    select
      case when shift_date.hours is not null
        then greatest(0, shift_date.hours - coalesce(timesheet_date.break_hours, 0))
      end as shift_hours,
      case when shift_date.hours is null then timesheet_date.hours end as timesheet_hours
    from shift_by_date shift_date
    full join timesheet_by_date timesheet_date on timesheet_date.report_date = shift_date.business_date
  )
  select
    coalesce(sum(worked_day.timesheet_hours), 0),
    coalesce(sum(worked_day.shift_hours), 0),
    count(*) filter (where coalesce(worked_day.shift_hours, worked_day.timesheet_hours, 0) > 0)
  into timesheet_hours_value, shift_hours_value, days_value
  from worked_days worked_day;

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

revoke execute on function public.pos_timesheet_break_hours(text) from public, anon, authenticated;
