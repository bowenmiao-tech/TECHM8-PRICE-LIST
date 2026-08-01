create or replace function public.is_nl_report_session_date_allowed(
  session_token text,
  target_date date
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  session_row public.nl_report_sessions%rowtype;
begin
  if not public.is_valid_nl_report_session(session_token) then
    return false;
  end if;

  select * into session_row
  from public.nl_report_sessions
  where session_hash = encode(extensions.digest(session_token, 'sha256'), 'hex')
    and expires_at > now();

  return public.is_nl_report_entry_date_allowed(target_date)
    or exists (
      select 1
      from public.nl_sales_reports report
      where report.store_id = session_row.store_id
        and report.report_date = target_date
        and report.status = 'draft'
    );
end;
$$;

create or replace function public.get_nl_report_entry_config(session_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  config_row public.nl_report_config%rowtype;
  session_row public.nl_report_sessions%rowtype;
  draft_dates_json jsonb;
begin
  if not public.is_valid_nl_report_session(session_token) then
    raise exception 'Invalid NL report session';
  end if;

  select * into session_row
  from public.nl_report_sessions
  where session_hash = encode(extensions.digest(session_token, 'sha256'), 'hex')
    and expires_at > now();

  select * into config_row
  from public.nl_report_config
  where id = 1;

  select coalesce(jsonb_agg(report.report_date order by report.report_date desc), '[]'::jsonb)
  into draft_dates_json
  from public.nl_sales_reports report
  where report.store_id = session_row.store_id
    and report.status = 'draft';

  return jsonb_build_object(
    'ok', true,
    'today', (now() at time zone 'Australia/Brisbane')::date,
    'backfill_date_from', config_row.backfill_date_from,
    'backfill_date_to', config_row.backfill_date_to,
    'draft_dates', draft_dates_json
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

  if not public.is_nl_report_session_date_allowed(session_token, target_date_value) then
    raise exception 'This report date is not open for entry';
  end if;

  return public.save_nl_sales_report_unrestricted_internal(session_token, payload);
end;
$$;

create or replace function public.submit_nl_sales_report_entry(
  session_token text,
  target_date text default null
)
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

  if not public.is_nl_report_session_date_allowed(session_token, target_date_value) then
    raise exception 'This report date is not open for entry';
  end if;

  return public.submit_nl_sales_report_unrestricted_internal(
    session_token,
    target_date_value::text
  );
end;
$$;

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

  if not public.is_nl_report_session_date_allowed(session_token, target_date_value) then
    raise exception 'This report date is not open for entry';
  end if;

  return public.save_nl_sales_report_unrestricted_internal(session_token, payload);
end;
$$;

create or replace function public.submit_nl_sales_report(
  session_token text,
  target_date text default null
)
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

  if not public.is_nl_report_session_date_allowed(session_token, target_date_value) then
    raise exception 'This report date is not open for entry';
  end if;

  return public.submit_nl_sales_report_unrestricted_internal(
    session_token,
    target_date_value::text
  );
end;
$$;

revoke all on function public.is_nl_report_session_date_allowed(text, date)
  from public, anon, authenticated;

revoke all on function public.get_nl_report_entry_config(text) from public;
revoke all on function public.save_nl_sales_report_entry(text, jsonb) from public;
revoke all on function public.submit_nl_sales_report_entry(text, text) from public;
revoke all on function public.save_nl_sales_report(text, jsonb) from public;
revoke all on function public.submit_nl_sales_report(text, text) from public;

grant execute on function public.get_nl_report_entry_config(text) to anon, authenticated;
grant execute on function public.save_nl_sales_report_entry(text, jsonb) to anon, authenticated;
grant execute on function public.submit_nl_sales_report_entry(text, text) to anon, authenticated;
grant execute on function public.save_nl_sales_report(text, jsonb) to anon, authenticated;
grant execute on function public.submit_nl_sales_report(text, text) to anon, authenticated;
