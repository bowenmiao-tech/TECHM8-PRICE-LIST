-- The function argument and the table column are both named event_code.
-- Referencing the named unique constraint makes the idempotency target explicit
-- and avoids PL/pgSQL resolving ON CONFLICT (event_code) ambiguously.
create or replace function public.record_pos_google_review(
  session_token text,
  target_store_code text,
  target_staff_name text,
  event_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  selected_staff public.staff_directory%rowtype;
  date_value date := (now() at time zone 'Australia/Brisbane')::date;
  event_code_value text := trim(coalesce(event_code, ''));
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;
  if event_code_value = '' then raise exception 'Review event id is required'; end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = coalesce(trim(target_store_code), '')
    and store_location.store_code <> 'warehouse';
  if not found then raise exception 'Store not found'; end if;

  select * into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and lower(trim(staff.display_name)) = lower(trim(coalesce(target_staff_name, '')))
  limit 1;
  if not found then raise exception 'Staff member not found'; end if;

  if not exists (
    select 1
    from public.pos_store_shifts shift_record
    where shift_record.store_id = selected_store.id
      and shift_record.business_date = date_value
      and shift_record.status = 'open'
  ) then
    raise exception 'Google reviews can only be recorded during an open shift';
  end if;

  if exists (
    select 1
    from public.pos_daily_target_results result
    where result.store_id = selected_store.id
      and result.business_date = date_value
      and result.normalized_staff_name = lower(trim(selected_staff.display_name))
  ) then
    raise exception 'Today score has already been finalized';
  end if;

  insert into public.pos_google_review_events (
    event_code,
    store_id,
    business_date,
    staff_name,
    points
  ) values (
    event_code_value,
    selected_store.id,
    date_value,
    selected_staff.display_name,
    5
  )
  on conflict on constraint pos_google_review_events_event_code_key do nothing;

  return public.pos_today_progress_payload(selected_store.id, date_value, selected_staff.display_name);
end;
$$;

revoke execute on function public.record_pos_google_review(text, text, text, text) from public, anon, authenticated;
grant execute on function public.record_pos_google_review(text, text, text, text) to anon, authenticated, service_role;
