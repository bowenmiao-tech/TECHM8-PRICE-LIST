create or replace function public.get_staff_management(session_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  staff_payload jsonb;
  store_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'staff_id', staff.id,
        'display_name', staff.display_name,
        'email', staff.email,
        'job_role', staff.job_role,
        'active', staff.active,
        'default_store_id', store_location.id,
        'default_store_code', store_location.store_code,
        'default_store_name', store_location.store_name,
        'credentials_ready', staff.credentials_initialized_at is not null,
        'last_login_at', staff.last_login_at,
        'updated_at', staff.updated_at
      )
      order by
        case when lower(coalesce(staff.email, '')) = 'techm8contact@gmail.com' then 0 else 1 end,
        staff.active desc,
        lower(staff.display_name),
        staff.id
    ),
    '[]'::jsonb
  )
  into staff_payload
  from public.staff_directory staff
  left join public.store_locations store_location
    on store_location.id = staff.default_store_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'store_id', store_location.id,
        'store_code', store_location.store_code,
        'store_name', store_location.store_name
      )
      order by store_location.sort_order, store_location.store_name
    ),
    '[]'::jsonb
  )
  into store_payload
  from public.store_locations store_location
  where store_location.active = true;

  return jsonb_build_object(
    'ok', true,
    'staff', staff_payload,
    'stores', store_payload
  );
end;
$$;

create or replace function public.update_staff_management(
  session_token text,
  target_staff_id bigint,
  target_store_code text,
  target_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_staff public.staff_directory%rowtype;
  selected_store public.store_locations%rowtype;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.id = target_staff_id
  for update;

  if selected_staff.id is null then
    raise exception 'Staff member not found';
  end if;

  if lower(coalesce(selected_staff.email, '')) = 'techm8contact@gmail.com'
    or lower(selected_staff.display_name) = 'bowen' then
    raise exception 'The Bowen administrator account cannot be reassigned or disabled';
  end if;

  select *
  into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = lower(btrim(coalesce(target_store_code, '')))
  limit 1;

  if selected_store.id is null then
    raise exception 'Select an active store for this staff member';
  end if;

  update public.staff_directory staff
  set
    default_store_id = selected_store.id,
    active = coalesce(target_active, false),
    job_role = 'staff',
    updated_at = now()
  where staff.id = selected_staff.id
  returning * into selected_staff;

  if not selected_staff.active then
    delete from public.staff_sessions session_row
    where session_row.staff_id = selected_staff.id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'staff', jsonb_build_object(
      'staff_id', selected_staff.id,
      'display_name', selected_staff.display_name,
      'email', selected_staff.email,
      'job_role', selected_staff.job_role,
      'active', selected_staff.active,
      'default_store_id', selected_store.id,
      'default_store_code', selected_store.store_code,
      'default_store_name', selected_store.store_name,
      'credentials_ready', selected_staff.credentials_initialized_at is not null,
      'last_login_at', selected_staff.last_login_at,
      'updated_at', selected_staff.updated_at
    )
  );
end;
$$;

revoke all on function public.get_staff_management(text) from public, anon, authenticated;
revoke all on function public.update_staff_management(text, bigint, text, boolean) from public, anon, authenticated;

grant execute on function public.get_staff_management(text) to anon, authenticated;
grant execute on function public.update_staff_management(text, bigint, text, boolean) to anon, authenticated;
