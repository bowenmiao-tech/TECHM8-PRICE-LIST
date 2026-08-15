create or replace function public.get_staff_transfer_context(
  session_token text,
  target_staff_name text
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
  if not public.is_valid_staff_session(session_token) then
    raise exception 'Invalid staff session';
  end if;

  select staff.*
  into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and lower(btrim(staff.display_name)) = lower(btrim(coalesce(target_staff_name, '')))
  order by staff.id
  limit 1;

  if selected_staff.id is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'Active staff member not found.'
    );
  end if;

  if selected_staff.default_store_id is not null then
    select store_location.*
    into selected_store
    from public.store_locations store_location
    where store_location.id = selected_staff.default_store_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'staff_id', selected_staff.id,
    'display_name', selected_staff.display_name,
    'job_role', selected_staff.job_role,
    'default_store_code', selected_store.store_code,
    'default_store_name', selected_store.store_name,
    'can_transfer_all_stores', true
  );
end;
$$;

revoke all on function public.get_staff_transfer_context(text, text) from public;
revoke all on function public.get_staff_transfer_context(text, text) from anon, authenticated;
grant execute on function public.get_staff_transfer_context(text, text) to anon, authenticated, service_role;
