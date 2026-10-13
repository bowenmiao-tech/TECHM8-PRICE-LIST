-- Archived staff retain their historical ID and name for reporting.
alter table public.staff_directory add column if not exists deleted_at timestamptz;
alter table public.staff_directory drop constraint if exists staff_directory_display_name_key;
create unique index if not exists staff_directory_current_name_key
  on public.staff_directory (lower(display_name)) where deleted_at is null;

create or replace function public.protect_archived_staff()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.deleted_at is not null then
    raise exception 'Archived staff accounts cannot be changed';
  end if;
  return new;
end; $$;
drop trigger if exists protect_archived_staff_trigger on public.staff_directory;
create trigger protect_archived_staff_trigger before update on public.staff_directory
for each row execute function public.protect_archived_staff();

create or replace function public.get_staff_management(session_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare staff_payload jsonb; store_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'staff_id', staff.id, 'display_name', staff.display_name, 'email', staff.email,
    'job_role', staff.job_role, 'active', staff.active,
    'default_store_id', primary_store.id,
    'default_store_code', primary_store.store_code,
    'default_store_name', primary_store.store_name,
    'assigned_stores', coalesce((select jsonb_agg(jsonb_build_object(
      'store_id', assigned_store.id, 'store_code', assigned_store.store_code,
      'store_name', assigned_store.store_name, 'is_primary', assignment.is_primary
    ) order by assignment.is_primary desc, assigned_store.sort_order, assigned_store.store_name)
      from public.staff_store_assignments assignment
      join public.store_locations assigned_store on assigned_store.id = assignment.store_id
      where assignment.staff_id = staff.id and assigned_store.active = true
        and assigned_store.store_code <> 'warehouse'), '[]'::jsonb),
    'stocktake_enabled', coalesce((select permission.enabled
      from public.pos_stocktake_permissions permission
      where permission.staff_id = staff.id), false),
    'credentials_ready', staff.credentials_initialized_at is not null,
    'last_login_at', staff.last_login_at, 'updated_at', staff.updated_at
  ) order by case when lower(coalesce(staff.email, '')) = 'techm8contact@gmail.com'
    then 0 else 1 end, staff.active desc, lower(staff.display_name), staff.id), '[]'::jsonb)
  into staff_payload from public.staff_directory staff
  left join public.store_locations primary_store on primary_store.id = staff.default_store_id
  where staff.deleted_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('store_id', store_location.id,
    'store_code', store_location.store_code, 'store_name', store_location.store_name)
    order by store_location.sort_order, store_location.store_name), '[]'::jsonb)
  into store_payload from public.store_locations store_location
  where store_location.active = true and store_location.store_code <> 'warehouse';
  return jsonb_build_object('ok', true, 'staff', staff_payload, 'stores', store_payload);
end; $$;

create or replace function public.issue_staff_invite(session_token text, target_staff_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare selected_staff public.staff_directory%rowtype; reset_result jsonb;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  select * into selected_staff from public.staff_directory where id = target_staff_id for update;
  if not found or selected_staff.deleted_at is not null or not selected_staff.active
    or selected_staff.credentials_initialized_at is not null then
    raise exception 'Only active staff awaiting first setup can be invited';
  end if;
  reset_result := public.request_staff_password_reset(selected_staff.email);
  if not coalesce((reset_result->>'issued')::boolean, false) then
    raise exception 'Invite limit reached. Try again in 15 minutes';
  end if;
  return jsonb_build_object('ok', true, 'staff_id', selected_staff.id,
    'staff_name', selected_staff.display_name, 'staff_email', lower(selected_staff.email),
    'invite_token', reset_result->>'reset_token',
    'expires_in_minutes', reset_result->'expires_in_minutes');
end; $$;

create or replace function public.create_staff_management(session_token text,
  new_display_name text, new_email text, new_store_codes jsonb,
  new_stocktake_enabled boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  normalized_name text := btrim(coalesce(new_display_name, ''));
  normalized_email text := lower(btrim(coalesce(new_email, '')));
  requested_count integer; valid_count integer; primary_store_id bigint;
  new_staff_id bigint; staff_record jsonb; invite_result jsonb;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  if length(normalized_name) < 2 or length(normalized_name) > 100 then
    raise exception 'Staff name must be 2 to 100 characters'; end if;
  if normalized_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or length(normalized_email) > 254 then raise exception 'Enter a valid staff email'; end if;
  if normalized_email = 'techm8contact@gmail.com' or lower(normalized_name) = 'bowen' then
    raise exception 'The administrator account cannot be added as staff'; end if;
  if jsonb_typeof(coalesce(new_store_codes, 'null'::jsonb)) <> 'array' then
    raise exception 'Store assignments must be an array'; end if;
  if exists (select 1 from public.staff_directory
             where deleted_at is null and lower(display_name) = lower(normalized_name)) then
    raise exception 'A staff member with this name already exists'; end if;
  if exists (select 1 from public.staff_directory
             where deleted_at is null and lower(email) = normalized_email) then
    raise exception 'A staff member with this email already exists'; end if;
  with requested as (select distinct lower(btrim(value)) code
    from jsonb_array_elements_text(new_store_codes) value)
  select (select count(*) from requested), count(*),
    (array_agg(store_location.id order by store_location.sort_order, store_location.store_name))[1]
  into requested_count, valid_count, primary_store_id
  from public.store_locations store_location
  where store_location.active = true and store_location.store_code <> 'warehouse'
    and store_location.store_code in (select code from requested);
  if requested_count < 1 or requested_count <> valid_count or requested_count > 50 then
    raise exception 'Select at least one valid store'; end if;
  insert into public.staff_directory (display_name, email, job_role, active,
    default_store_id, login_password_hash, pin_hash, credentials_initialized_at)
  values (normalized_name, normalized_email, 'staff', true, primary_store_id, null, null, null)
  returning id into new_staff_id;
  insert into public.staff_store_assignments (staff_id, store_id, is_primary)
  select new_staff_id, store_location.id, store_location.id = primary_store_id
  from public.store_locations store_location
  where store_location.store_code in (select lower(btrim(value))
    from jsonb_array_elements_text(new_store_codes) value);
  insert into public.pos_stocktake_permissions (staff_id, enabled, enabled_at, disabled_at, updated_at)
  values (new_staff_id, coalesce(new_stocktake_enabled, false),
    case when coalesce(new_stocktake_enabled, false) then now() end,
    case when not coalesce(new_stocktake_enabled, false) then now() end, now());
  invite_result := public.issue_staff_invite(session_token, new_staff_id);
  select value into staff_record
  from jsonb_array_elements(public.get_staff_management(session_token)->'staff') value
  where (value->>'staff_id')::bigint = new_staff_id;
  return jsonb_build_object('ok', true, 'staff', staff_record,
    'staff_name', normalized_name, 'staff_email', normalized_email,
    'invite_token', invite_result->>'invite_token',
    'expires_in_minutes', invite_result->'expires_in_minutes');
end; $$;

create or replace function public.archive_staff_management(session_token text, target_staff_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare selected_staff public.staff_directory%rowtype;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  select * into selected_staff from public.staff_directory where id = target_staff_id for update;
  if not found or selected_staff.deleted_at is not null then raise exception 'Staff member not found'; end if;
  if lower(coalesce(selected_staff.email, '')) = 'techm8contact@gmail.com'
    or lower(coalesce(selected_staff.job_role, '')) = 'admin'
    or lower(selected_staff.display_name) = 'bowen' then
    raise exception 'The administrator account cannot be deleted'; end if;
  update public.staff_directory set active = false, deleted_at = now(),
    default_store_id = null, login_password_hash = null, pin_hash = null,
    updated_at = now() where id = target_staff_id;
  delete from public.staff_sessions where staff_id = target_staff_id;
  delete from public.staff_store_assignments where staff_id = target_staff_id;
  update public.staff_password_resets set used_at = now()
    where staff_id = target_staff_id and used_at is null;
  update public.pos_stocktake_permissions set enabled = false,
    disabled_at = now(), updated_at = now() where staff_id = target_staff_id;
  return jsonb_build_object('ok', true, 'staff_id', target_staff_id,
    'staff_name', selected_staff.display_name);
end; $$;

create or replace function public.verify_staff_password_reset(reset_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare selected_staff public.staff_directory%rowtype;
begin
  if coalesce(reset_token, '') = '' then return jsonb_build_object('ok', true, 'valid', false); end if;
  select staff.* into selected_staff from public.staff_password_resets reset_row
  join public.staff_directory staff on staff.id = reset_row.staff_id
  where reset_row.token_digest = encode(extensions.digest(reset_token, 'sha256'), 'hex')
    and reset_row.used_at is null and reset_row.expires_at > now()
    and staff.active = true and staff.deleted_at is null limit 1;
  if not found then return jsonb_build_object('ok', true, 'valid', false); end if;
  return jsonb_build_object('ok', true, 'valid', true,
    'staff_name', selected_staff.display_name, 'staff_email', lower(selected_staff.email),
    'first_setup', selected_staff.credentials_initialized_at is null);
end; $$;

revoke all on function public.protect_archived_staff() from public, anon, authenticated;
revoke all on function public.get_staff_management(text) from public, anon, authenticated;
revoke all on function public.issue_staff_invite(text, bigint) from public, anon, authenticated;
revoke all on function public.create_staff_management(text, text, text, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.archive_staff_management(text, bigint) from public, anon, authenticated;
revoke all on function public.verify_staff_password_reset(text) from public, anon, authenticated;
grant execute on function public.get_staff_management(text) to service_role;
grant execute on function public.issue_staff_invite(text, bigint) to service_role;
grant execute on function public.create_staff_management(text, text, text, jsonb, boolean) to service_role;
grant execute on function public.archive_staff_management(text, bigint) to service_role;
grant execute on function public.verify_staff_password_reset(text) to service_role;
