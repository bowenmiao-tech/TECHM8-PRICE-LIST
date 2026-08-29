-- Daily-report access rules:
-- * Staff can only work in their assigned store.
-- * Staff can edit only drafts/reports attributed to their own account.
-- * Drafts from another staff member in the same store remain visible but are
--   marked read-only. Bowen remains able to manage every store/staff draft.

create or replace function public.save_daily_report_draft(
  session_token text,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_profile jsonb;
  session_staff public.staff_directory%rowtype;
  selected_store public.store_locations%rowtype;
  selected_staff public.staff_directory%rowtype;
  report_date_value date;
  is_admin boolean := false;
begin
  session_profile := public.verify_staff_session(session_token);
  if not coalesce((session_profile->>'ok')::boolean, false) then
    raise exception 'Invalid session';
  end if;

  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Payload must be a JSON object';
  end if;

  select *
  into session_staff
  from public.staff_directory staff
  where staff.id = nullif(session_profile->>'staff_id', '')::bigint
    and staff.active = true
  limit 1;

  if session_staff.id is null then
    raise exception 'Active staff account not found';
  end if;

  is_admin := lower(trim(coalesce(session_staff.email, ''))) = 'techm8contact@gmail.com';

  select *
  into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse'
    and store_location.store_code = lower(trim(coalesce(payload->>'store_code', '')))
  limit 1;

  if selected_store.id is null then
    raise exception 'Store not found';
  end if;

  if not is_admin and session_staff.default_store_id is distinct from selected_store.id then
    raise exception 'This staff account is not assigned to the selected store';
  end if;

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and staff.display_name = trim(coalesce(payload->>'staff_name', ''))
  limit 1;

  if selected_staff.id is null then
    raise exception 'Staff member not found';
  end if;

  if not is_admin and selected_staff.id <> session_staff.id then
    raise exception 'Another staff member''s daily report is read-only';
  end if;

  report_date_value := coalesce(nullif(payload->>'report_date', '')::date, current_date);

  if exists (
    select 1
    from public.daily_report_submissions report
    where report.store_id = selected_store.id
      and report.report_date = report_date_value
  ) then
    delete from public.daily_report_drafts draft
    where draft.store_id = selected_store.id
      and draft.report_date = report_date_value;
    raise exception 'A report for this store and date has already been submitted';
  end if;

  insert into public.daily_report_drafts (
    store_id,
    staff_id,
    report_date,
    store_name,
    staff_name,
    payload
  )
  values (
    selected_store.id,
    selected_staff.id,
    report_date_value,
    selected_store.store_name,
    selected_staff.display_name,
    payload
  )
  on conflict (store_id, staff_id, report_date) do update
  set
    payload = excluded.payload,
    store_name = excluded.store_name,
    staff_name = excluded.staff_name,
    updated_at = now();

  return jsonb_build_object('ok', true, 'read_only', false);
end;
$$;

create or replace function public.get_daily_report_draft(
  session_token text,
  target_store_code text,
  target_staff_name text,
  target_date text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_profile jsonb;
  session_staff public.staff_directory%rowtype;
  selected_store public.store_locations%rowtype;
  selected_staff public.staff_directory%rowtype;
  draft_record public.daily_report_drafts%rowtype;
  is_admin boolean := false;
  is_read_only boolean := false;
begin
  session_profile := public.verify_staff_session(session_token);
  if not coalesce((session_profile->>'ok')::boolean, false) then
    raise exception 'Invalid session';
  end if;

  select *
  into session_staff
  from public.staff_directory staff
  where staff.id = nullif(session_profile->>'staff_id', '')::bigint
    and staff.active = true
  limit 1;

  if session_staff.id is null then
    raise exception 'Active staff account not found';
  end if;

  is_admin := lower(trim(coalesce(session_staff.email, ''))) = 'techm8contact@gmail.com';

  select *
  into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse'
    and store_location.store_code = lower(trim(coalesce(target_store_code, '')))
  limit 1;

  if selected_store.id is null then
    return jsonb_build_object('ok', true, 'has_draft', false, 'draft', '{}'::jsonb, 'read_only', false);
  end if;

  if not is_admin and session_staff.default_store_id is distinct from selected_store.id then
    raise exception 'This staff account is not assigned to the selected store';
  end if;

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and staff.display_name = trim(coalesce(target_staff_name, ''))
  limit 1;

  if selected_staff.id is null then
    return jsonb_build_object('ok', true, 'has_draft', false, 'draft', '{}'::jsonb, 'read_only', false);
  end if;

  select draft.*
  into draft_record
  from public.daily_report_drafts draft
  where draft.store_id = selected_store.id
    and draft.staff_id = selected_staff.id
    and draft.report_date = coalesce(nullif(target_date, '')::date, current_date)
  order by draft.updated_at desc
  limit 1;

  if draft_record.id is null then
    return jsonb_build_object('ok', true, 'has_draft', false, 'draft', '{}'::jsonb, 'read_only', false);
  end if;

  is_read_only := not is_admin and draft_record.staff_id <> session_staff.id;

  return jsonb_build_object(
    'ok', true,
    'has_draft', true,
    'draft', draft_record.payload,
    'draft_id', draft_record.id,
    'staff_name', draft_record.staff_name,
    'store_name', draft_record.store_name,
    'updated_at', draft_record.updated_at,
    'read_only', is_read_only,
    'can_edit', not is_read_only
  );
end;
$$;

create or replace function public.list_daily_report_drafts(
  session_token text,
  target_store_code text,
  target_date text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_profile jsonb;
  session_staff public.staff_directory%rowtype;
  selected_store public.store_locations%rowtype;
  target_date_value date;
  drafts_payload jsonb;
  is_admin boolean := false;
begin
  session_profile := public.verify_staff_session(session_token);
  if not coalesce((session_profile->>'ok')::boolean, false) then
    raise exception 'Invalid session';
  end if;

  select *
  into session_staff
  from public.staff_directory staff
  where staff.id = nullif(session_profile->>'staff_id', '')::bigint
    and staff.active = true
  limit 1;

  if session_staff.id is null then
    raise exception 'Active staff account not found';
  end if;

  is_admin := lower(trim(coalesce(session_staff.email, ''))) = 'techm8contact@gmail.com';
  target_date_value := coalesce(nullif(target_date, '')::date, current_date);

  select *
  into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse'
    and store_location.store_code = lower(trim(coalesce(target_store_code, '')))
  limit 1;

  if selected_store.id is null then
    return jsonb_build_object('ok', true, 'drafts', '[]'::jsonb, 'submitted_today', false);
  end if;

  if not is_admin and session_staff.default_store_id is distinct from selected_store.id then
    raise exception 'This staff account is not assigned to the selected store';
  end if;

  delete from public.daily_report_drafts draft
  where draft.store_id = selected_store.id
    and draft.report_date = target_date_value
    and exists (
      select 1
      from public.daily_report_submissions report
      where report.store_id = draft.store_id
        and report.report_date = draft.report_date
    );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', draft.id,
        'staff_name', draft.staff_name,
        'store_name', draft.store_name,
        'report_date', draft.report_date,
        'updated_at', draft.updated_at,
        'payload', draft.payload,
        'read_only', (not is_admin and draft.staff_id <> session_staff.id),
        'can_edit', (is_admin or draft.staff_id = session_staff.id)
      )
      order by draft.updated_at desc, draft.id desc
    ),
    '[]'::jsonb
  )
  into drafts_payload
  from public.daily_report_drafts draft
  where draft.store_id = selected_store.id
    and draft.report_date = target_date_value;

  return jsonb_build_object(
    'ok', true,
    'submitted_today', exists (
      select 1
      from public.daily_report_submissions report
      where report.store_id = selected_store.id
        and report.report_date = target_date_value
    ),
    'drafts', drafts_payload
  );
end;
$$;

create or replace function public.submit_daily_report(
  session_token text,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_profile jsonb;
  session_staff public.staff_directory%rowtype;
  selected_store public.store_locations%rowtype;
  selected_staff public.staff_directory%rowtype;
  is_admin boolean := false;
begin
  session_profile := public.verify_staff_session(session_token);
  if not coalesce((session_profile->>'ok')::boolean, false) then
    raise exception 'Invalid session';
  end if;

  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Payload must be a JSON object';
  end if;

  select *
  into session_staff
  from public.staff_directory staff
  where staff.id = nullif(session_profile->>'staff_id', '')::bigint
    and staff.active = true
  limit 1;

  if session_staff.id is null then
    raise exception 'Active staff account not found';
  end if;

  is_admin := lower(trim(coalesce(session_staff.email, ''))) = 'techm8contact@gmail.com';

  select *
  into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse'
    and store_location.store_code = lower(trim(coalesce(payload->>'store_code', '')))
  limit 1;

  if selected_store.id is null then
    raise exception 'Store not found';
  end if;

  if not is_admin and session_staff.default_store_id is distinct from selected_store.id then
    raise exception 'This staff account is not assigned to the selected store';
  end if;

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and staff.display_name = trim(coalesce(payload->>'staff_name', ''))
  limit 1;

  if selected_staff.id is null then
    raise exception 'Staff member not found';
  end if;

  if not is_admin and selected_staff.id <> session_staff.id then
    raise exception 'Another staff member''s daily report is read-only';
  end if;

  return public.submit_daily_report_internal(payload, 'staff', false);
end;
$$;

-- These are scheduler/service helpers, not browser RPCs. The function owner
-- can still run scheduled jobs; Edge/service callers retain explicit access.
revoke all on function public.submit_daily_report_internal(jsonb, text, boolean)
  from public, anon, authenticated;
revoke all on function public.rollover_daily_report_drafts(date)
  from public, anon, authenticated;
revoke all on function public.reset_current_week_lcd_count_submissions(date)
  from public, anon, authenticated;

grant execute on function public.submit_daily_report_internal(jsonb, text, boolean)
  to service_role;
grant execute on function public.rollover_daily_report_drafts(date)
  to service_role;
grant execute on function public.reset_current_week_lcd_count_submissions(date)
  to service_role;

comment on function public.save_daily_report_draft(text, jsonb) is
  'Staff can save only their own report in their assigned store. Bowen may manage every store/staff report.';
comment on function public.get_daily_report_draft(text, text, text, text) is
  'Returns same-store drafts with read_only metadata when the signed-in staff member is not the owner.';
comment on function public.list_daily_report_drafts(text, text, text) is
  'Lists drafts only for the signed-in staff member assigned store, with other staff drafts marked read-only. Bowen may view and edit all.';
comment on function public.submit_daily_report(text, jsonb) is
  'Staff can submit only their own report in their assigned store. Bowen may submit for any active store/staff.';
comment on function public.submit_daily_report_internal(jsonb, text, boolean) is
  'Internal scheduler/service helper. Direct anon/authenticated execution is revoked.';
comment on function public.rollover_daily_report_drafts(date) is
  'Internal scheduled draft rollover. Direct anon/authenticated execution is revoked.';
comment on function public.reset_current_week_lcd_count_submissions(date) is
  'Internal scheduled weekly reset. Direct anon/authenticated execution is revoked.';

-- Preserve the intentionally public, session-authenticated report RPCs.
revoke all on function public.save_daily_report_draft(text, jsonb)
  from public, anon, authenticated;
revoke all on function public.get_daily_report_draft(text, text, text, text)
  from public, anon, authenticated;
revoke all on function public.list_daily_report_drafts(text, text, text)
  from public, anon, authenticated;
revoke all on function public.submit_daily_report(text, jsonb)
  from public, anon, authenticated;

grant execute on function public.save_daily_report_draft(text, jsonb)
  to anon, authenticated, service_role;
grant execute on function public.get_daily_report_draft(text, text, text, text)
  to anon, authenticated, service_role;
grant execute on function public.list_daily_report_drafts(text, text, text)
  to anon, authenticated, service_role;
grant execute on function public.submit_daily_report(text, jsonb)
  to anon, authenticated, service_role;
