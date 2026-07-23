alter table public.nl_report_config
  add column if not exists backfill_date_from date,
  add column if not exists backfill_date_to date;

update public.nl_report_config
set backfill_date_from = date '2026-07-13',
    backfill_date_to = date '2026-07-20'
where id = 1;

create or replace function public.is_nl_report_entry_date_allowed(target_date date)
returns boolean
language sql
security definer
set search_path = public
as $$
  select target_date = (now() at time zone 'Australia/Brisbane')::date
    or exists (
      select 1
      from public.nl_report_config config
      where config.id = 1
        and config.backfill_date_from is not null
        and config.backfill_date_to is not null
        and target_date between config.backfill_date_from and config.backfill_date_to
    );
$$;

create or replace function public.get_nl_report_entry_config(session_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  config_row public.nl_report_config%rowtype;
begin
  if not public.is_valid_nl_report_session(session_token) then
    raise exception 'Invalid NL report session';
  end if;

  select * into config_row
  from public.nl_report_config
  where id = 1;

  return jsonb_build_object(
    'ok', true,
    'today', (now() at time zone 'Australia/Brisbane')::date,
    'backfill_date_from', config_row.backfill_date_from,
    'backfill_date_to', config_row.backfill_date_to
  );
end;
$$;

create or replace function public.save_nl_sales_report_entry(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_date_value date;
begin
  if not public.is_valid_nl_report_session(session_token) then
    raise exception 'Invalid NL report session';
  end if;

  target_date_value := coalesce(
    nullif(payload->>'report_date', '')::date,
    (now() at time zone 'Australia/Brisbane')::date
  );

  if not public.is_nl_report_entry_date_allowed(target_date_value) then
    raise exception 'This report date is not open for entry';
  end if;

  return public.save_nl_sales_report(session_token, payload);
end;
$$;

create or replace function public.submit_nl_sales_report_entry(session_token text, target_date text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_date_value date;
begin
  if not public.is_valid_nl_report_session(session_token) then
    raise exception 'Invalid NL report session';
  end if;

  target_date_value := coalesce(
    nullif(target_date, '')::date,
    (now() at time zone 'Australia/Brisbane')::date
  );

  if not public.is_nl_report_entry_date_allowed(target_date_value) then
    raise exception 'This report date is not open for entry';
  end if;

  return public.submit_nl_sales_report(session_token, target_date_value::text);
end;
$$;

revoke all on function public.is_nl_report_entry_date_allowed(date) from public, anon, authenticated;
revoke all on function public.save_nl_sales_report(text, jsonb) from public, anon, authenticated;
revoke all on function public.submit_nl_sales_report(text, text) from public, anon, authenticated;

revoke all on function public.get_nl_report_entry_config(text) from public;
revoke all on function public.save_nl_sales_report_entry(text, jsonb) from public;
revoke all on function public.submit_nl_sales_report_entry(text, text) from public;

grant execute on function public.get_nl_report_entry_config(text) to anon, authenticated;
grant execute on function public.save_nl_sales_report_entry(text, jsonb) to anon, authenticated;
grant execute on function public.submit_nl_sales_report_entry(text, text) to anon, authenticated;

-- Keep the original RPC names available for already-open browser tabs, but route
-- them through the same server-side date restriction.
alter function public.save_nl_sales_report(text, jsonb)
  rename to save_nl_sales_report_unrestricted_internal;
alter function public.submit_nl_sales_report(text, text)
  rename to submit_nl_sales_report_unrestricted_internal;

create or replace function public.save_nl_sales_report(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_date_value date;
begin
  if not public.is_valid_nl_report_session(session_token) then
    raise exception 'Invalid NL report session';
  end if;

  target_date_value := coalesce(
    nullif(payload->>'report_date', '')::date,
    (now() at time zone 'Australia/Brisbane')::date
  );

  if not public.is_nl_report_entry_date_allowed(target_date_value) then
    raise exception 'This report date is not open for entry';
  end if;

  return public.save_nl_sales_report_unrestricted_internal(session_token, payload);
end;
$$;

create or replace function public.submit_nl_sales_report(session_token text, target_date text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_date_value date;
begin
  if not public.is_valid_nl_report_session(session_token) then
    raise exception 'Invalid NL report session';
  end if;

  target_date_value := coalesce(
    nullif(target_date, '')::date,
    (now() at time zone 'Australia/Brisbane')::date
  );

  if not public.is_nl_report_entry_date_allowed(target_date_value) then
    raise exception 'This report date is not open for entry';
  end if;

  return public.submit_nl_sales_report_unrestricted_internal(session_token, target_date_value::text);
end;
$$;

revoke all on function public.save_nl_sales_report_unrestricted_internal(text, jsonb) from public, anon, authenticated;
revoke all on function public.submit_nl_sales_report_unrestricted_internal(text, text) from public, anon, authenticated;
revoke all on function public.save_nl_sales_report(text, jsonb) from public;
revoke all on function public.submit_nl_sales_report(text, text) from public;
grant execute on function public.save_nl_sales_report(text, jsonb) to anon, authenticated;
grant execute on function public.submit_nl_sales_report(text, text) to anon, authenticated;
