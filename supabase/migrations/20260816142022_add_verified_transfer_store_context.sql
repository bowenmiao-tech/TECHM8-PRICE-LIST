create or replace function public.get_staff_transfer_context(
  session_token text,
  target_staff_name text,
  target_store_code text,
  target_shift_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_staff public.staff_directory%rowtype;
  selected_store public.store_locations%rowtype;
  selected_shift public.pos_store_shifts%rowtype;
  current_store_slug text;
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

  select shift_record.*
  into selected_shift
  from public.pos_store_shifts shift_record
  join public.store_locations store_location on store_location.id = shift_record.store_id
  where shift_record.status = 'open'
    and shift_record.shift_code = btrim(coalesce(target_shift_code, ''))
    and lower(btrim(shift_record.current_staff_name)) = lower(btrim(selected_staff.display_name))
    and store_location.active = true
    and store_location.store_code = btrim(coalesce(target_store_code, ''))
    and store_location.store_code <> 'warehouse'
  limit 1;

  if selected_shift.id is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'The selected staff member does not have the current open shift for this store.'
    );
  end if;

  select store_location.*
  into selected_store
  from public.store_locations store_location
  where store_location.id = selected_shift.store_id;

  current_store_slug := case selected_store.store_code
    when 'parkridge' then 'park-ridge'
    when 'northlakes' then 'north-lakes'
    when 'fairfield' then 'fairfield'
    when 'toowong' then 'toowong'
    else null
  end;

  if current_store_slug is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'The current shift is not assigned to a POS transfer store.'
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'staff_id', selected_staff.id,
    'display_name', selected_staff.display_name,
    'job_role', selected_staff.job_role,
    'current_store_code', selected_store.store_code,
    'current_store_name', selected_store.store_name,
    'current_store_slug', current_store_slug,
    'current_shift_code', selected_shift.shift_code,
    'can_transfer_all_stores', true
  );
end;
$$;

revoke all on function public.get_staff_transfer_context(text, text, text, text) from public;
revoke all on function public.get_staff_transfer_context(text, text, text, text) from anon, authenticated;
grant execute on function public.get_staff_transfer_context(text, text, text, text) to anon, authenticated, service_role;
