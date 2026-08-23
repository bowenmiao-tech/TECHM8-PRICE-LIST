-- A POS store shift belongs to one Brisbane business date. An unclosed shift
-- must never roll into the next day and silently bypass the morning Start Shift.
create or replace function public.expire_stale_pos_store_shifts(
  target_store_id bigint,
  current_business_date date default ((now() at time zone 'Australia/Brisbane')::date)
)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  expired_count integer := 0;
begin
  update public.pos_store_shifts shift_record
  set status = 'closed',
      closed_by = 'System daily reset',
      closed_at = greatest(
        shift_record.opened_at,
        ((shift_record.business_date + 1)::timestamp at time zone 'Australia/Brisbane') - interval '1 microsecond'
      ),
      last_seen_at = greatest(
        shift_record.last_seen_at,
        ((shift_record.business_date + 1)::timestamp at time zone 'Australia/Brisbane') - interval '1 microsecond'
      )
  where shift_record.store_id = target_store_id
    and shift_record.status = 'open'
    and shift_record.business_date < current_business_date;

  get diagnostics expired_count = row_count;
  return expired_count;
end;
$$;

create or replace function public.get_pos_store_shift(session_token text, target_store_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  shift_row public.pos_store_shifts%rowtype;
  business_date_value date := (now() at time zone 'Australia/Brisbane')::date;
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = coalesce(trim(target_store_code), '')
    and store_location.store_code <> 'warehouse';
  if not found then raise exception 'Store not found'; end if;

  perform pg_catalog.pg_advisory_xact_lock(selected_store.id);
  perform public.expire_stale_pos_store_shifts(selected_store.id, business_date_value);

  select * into shift_row
  from public.pos_store_shifts shift_record
  where shift_record.store_id = selected_store.id
    and shift_record.business_date = business_date_value
    and shift_record.status = 'open'
  order by shift_record.opened_at desc
  limit 1;

  return jsonb_build_object(
    'ok', true,
    'business_date', business_date_value,
    'shift', case when found then public.pos_store_shift_payload(shift_row) else null end
  );
end;
$$;

create or replace function public.open_pos_store_shift(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  selected_staff public.staff_directory%rowtype;
  shift_row public.pos_store_shifts%rowtype;
  shift_code_value text;
  business_date_value date := (now() at time zone 'Australia/Brisbane')::date;
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;
  if jsonb_typeof(payload) <> 'object' then raise exception 'Shift payload must be an object'; end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = coalesce(trim(payload->>'store_code'), '')
    and store_location.store_code <> 'warehouse';
  if not found then raise exception 'Store not found'; end if;

  select * into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and lower(staff.display_name) = lower(coalesce(trim(payload->>'staff_name'), ''))
  limit 1;
  if not found then raise exception 'Staff member not found'; end if;

  perform pg_catalog.pg_advisory_xact_lock(selected_store.id);
  perform public.expire_stale_pos_store_shifts(selected_store.id, business_date_value);

  select * into shift_row
  from public.pos_store_shifts shift_record
  where shift_record.store_id = selected_store.id
    and shift_record.business_date = business_date_value
    and shift_record.status = 'open'
  for update;

  if found then
    update public.pos_store_shifts
    set current_staff_name = selected_staff.display_name,
        last_staff_name = selected_staff.display_name,
        last_seen_at = now()
    where id = shift_row.id
    returning * into shift_row;
  else
    shift_code_value := coalesce(
      nullif(trim(payload->>'id'), ''),
      'SHIFT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint
    );

    insert into public.pos_store_shifts (
      shift_code,
      store_id,
      business_date,
      opened_by,
      current_staff_name,
      last_staff_name,
      opened_at,
      last_seen_at
    ) values (
      shift_code_value,
      selected_store.id,
      business_date_value,
      selected_staff.display_name,
      selected_staff.display_name,
      selected_staff.display_name,
      now(),
      now()
    )
    returning * into shift_row;
  end if;

  return jsonb_build_object(
    'ok', true,
    'business_date', business_date_value,
    'shift', public.pos_store_shift_payload(shift_row)
  );
end;
$$;

create or replace function public.save_pos_shift_opening(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_staff public.staff_directory%rowtype;
  shift_row public.pos_store_shifts%rowtype;
  business_date_value date := (now() at time zone 'Australia/Brisbane')::date;
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;

  select * into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and lower(staff.display_name) = lower(coalesce(trim(payload->>'staff_name'), ''))
  limit 1;
  if not found then raise exception 'Staff member not found'; end if;

  select * into shift_row
  from public.pos_store_shifts shift_record
  where shift_record.shift_code = coalesce(trim(payload->>'shift_id'), '')
    and shift_record.business_date = business_date_value
    and shift_record.status = 'open'
  for update;
  if not found then raise exception 'Today''s open shift was not found'; end if;

  if shift_row.opening_confirmed_at is null then
    update public.pos_store_shifts
    set opening_cash_total = round(greatest(coalesce(nullif(payload->>'total', '')::numeric, 0), 0), 2),
        opening_counts = coalesce(payload->'counts', '{}'::jsonb),
        opening_confirmed_at = now(),
        current_staff_name = selected_staff.display_name,
        last_staff_name = selected_staff.display_name,
        last_seen_at = now()
    where id = shift_row.id
    returning * into shift_row;
  end if;

  return jsonb_build_object('ok', true, 'shift', public.pos_store_shift_payload(shift_row));
end;
$$;

create or replace function public.close_pos_store_shift(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_staff public.staff_directory%rowtype;
  shift_row public.pos_store_shifts%rowtype;
  business_date_value date := (now() at time zone 'Australia/Brisbane')::date;
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;

  select * into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and lower(staff.display_name) = lower(coalesce(trim(payload->>'staff_name'), ''))
  limit 1;
  if not found then raise exception 'Staff member not found'; end if;

  update public.pos_store_shifts
  set status = 'closed',
      current_staff_name = selected_staff.display_name,
      last_staff_name = selected_staff.display_name,
      system_totals = coalesce(payload->'system', '{}'::jsonb),
      actual_totals = coalesce(payload->'actual', '{}'::jsonb),
      differences = coalesce(payload->'differences', '{}'::jsonb),
      closing_cash_total = round(greatest(coalesce(nullif(payload->>'closing_cash_total', '')::numeric, 0), 0), 2),
      closing_counts = coalesce(payload->'cash_counts', '{}'::jsonb),
      closed_by = selected_staff.display_name,
      closed_at = now(),
      last_seen_at = now()
  where shift_code = coalesce(trim(payload->>'shift_id'), '')
    and business_date = business_date_value
    and status = 'open'
  returning * into shift_row;

  if not found then raise exception 'Today''s open shift was not found'; end if;
  return jsonb_build_object('ok', true, 'shift', public.pos_store_shift_payload(shift_row));
end;
$$;

-- Apply the daily reset immediately to any shifts already left open from prior
-- dates. The existing status trigger finalizes their daily target snapshots.
do $$
declare
  store_record record;
  business_date_value date := (now() at time zone 'Australia/Brisbane')::date;
begin
  for store_record in
    select distinct shift_record.store_id
    from public.pos_store_shifts shift_record
    where shift_record.status = 'open'
      and shift_record.business_date < business_date_value
  loop
    perform pg_catalog.pg_advisory_xact_lock(store_record.store_id);
    perform public.expire_stale_pos_store_shifts(store_record.store_id, business_date_value);
  end loop;
end;
$$;

revoke all on function public.expire_stale_pos_store_shifts(bigint, date) from public, anon, authenticated;
revoke all on function public.get_pos_store_shift(text, text) from public, anon, authenticated;
revoke all on function public.open_pos_store_shift(text, jsonb) from public, anon, authenticated;
revoke all on function public.save_pos_shift_opening(text, jsonb) from public, anon, authenticated;
revoke all on function public.close_pos_store_shift(text, jsonb) from public, anon, authenticated;

grant execute on function public.get_pos_store_shift(text, text) to anon, authenticated, service_role;
grant execute on function public.open_pos_store_shift(text, jsonb) to anon, authenticated, service_role;
grant execute on function public.save_pos_shift_opening(text, jsonb) to anon, authenticated, service_role;
grant execute on function public.close_pos_store_shift(text, jsonb) to anon, authenticated, service_role;
