-- A shift belongs to a store. Its last operator is not an exclusive owner.
-- Reuse checkout's authenticated actor + today's open store shift validation.
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
  context jsonb;
  selected_staff public.staff_directory%rowtype;
  store_slug text;
begin
  context := public.pos_open_shift_context(
    session_token, target_store_code, target_shift_code, target_staff_name, false
  );
  if lower(trim(coalesce(target_staff_name, ''))) <> lower(trim(context->>'staff_name')) then
    raise exception 'The selected staff member does not match the signed-in account. Please sign in again.';
  end if;

  select * into strict selected_staff from public.staff_directory
    where id = (context->>'staff_id')::bigint;
  store_slug := case context->>'store_code'
    when 'parkridge' then 'park-ridge'
    when 'northlakes' then 'north-lakes'
    when 'fairfield' then 'fairfield'
    when 'toowong' then 'toowong'
    when 'brassall' then 'brassall'
  end;
  if store_slug is null then
    raise exception 'The current shift is not assigned to a POS transfer store.';
  end if;
  return jsonb_build_object(
    'ok', true,
    'staff_id', selected_staff.id,
    'display_name', selected_staff.display_name,
    'job_role', selected_staff.job_role,
    'current_store_code', context->>'store_code',
    'current_store_name', context->>'store_name',
    'current_store_slug', store_slug,
    'current_shift_code', context->>'shift_id',
    'can_transfer_all_stores', true
  );
end;
$$;

revoke all on function public.get_staff_transfer_context(text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.get_staff_transfer_context(text, text, text, text)
  to anon, authenticated, service_role;
