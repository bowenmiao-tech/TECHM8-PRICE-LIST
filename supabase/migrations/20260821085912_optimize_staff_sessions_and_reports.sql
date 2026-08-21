-- Staff session tokens are random 192-bit values. Keep the existing bcrypt hash for
-- compatibility, but add a deterministic SHA-256 digest so session checks use an index
-- instead of running bcrypt once per active session.
alter table public.staff_sessions
  add column if not exists token_digest text;

create unique index if not exists staff_sessions_token_digest_key
  on public.staff_sessions (token_digest)
  where token_digest is not null;

create or replace function public.is_valid_staff_session(session_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  token_digest_value text;
begin
  if coalesce(trim(session_token), '') = '' then
    return false;
  end if;

  token_digest_value := encode(extensions.digest(session_token, 'sha256'), 'hex');

  if exists (
    select 1
    from public.staff_sessions session_row
    join public.staff_directory staff on staff.id = session_row.staff_id
    where session_row.token_digest = token_digest_value
      and session_row.expires_at > now()
      and staff.active = true
      and staff.credentials_initialized_at is not null
  ) then
    return true;
  end if;

  -- Existing sessions are upgraded by verify_staff_session on their next page load.
  if exists (
    select 1
    from public.staff_sessions session_row
    join public.staff_directory staff on staff.id = session_row.staff_id
    where session_row.token_digest is null
      and session_row.expires_at > now()
      and staff.active = true
      and staff.credentials_initialized_at is not null
      and session_row.session_hash like '$2%'
      and extensions.crypt(session_token, session_row.session_hash) = session_row.session_hash
  ) then
    return true;
  end if;

  return exists (
    select 1
    from public.admin_sessions session_row
    where session_row.expires_at > now()
      and extensions.crypt(session_token, session_row.session_hash) = session_row.session_hash
  );
end;
$$;

create or replace function public.create_staff_session(login_email text, input_password text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_staff public.staff_directory%rowtype;
  issued_token text;
  issued_token_digest text;
  session_expires_at timestamptz;
begin
  select *
  into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and lower(trim(coalesce(staff.email, ''))) = lower(trim(coalesce(login_email, '')))
  limit 1;

  if selected_staff.id is null
    or selected_staff.login_password_hash is null
    or extensions.crypt(coalesce(input_password, ''), selected_staff.login_password_hash) <> selected_staff.login_password_hash then
    return jsonb_build_object('ok', false, 'message', 'Incorrect email or password');
  end if;

  delete from public.staff_sessions where expires_at <= now();

  issued_token := encode(extensions.gen_random_bytes(24), 'hex');
  issued_token_digest := encode(extensions.digest(issued_token, 'sha256'), 'hex');
  session_expires_at := now() + interval '12 hours';

  insert into public.staff_sessions (staff_id, session_hash, token_digest, expires_at)
  values (
    selected_staff.id,
    extensions.crypt(issued_token, extensions.gen_salt('bf', 12)),
    issued_token_digest,
    session_expires_at
  );

  update public.staff_directory
  set last_login_at = now(), updated_at = now()
  where id = selected_staff.id;

  return jsonb_build_object(
    'ok', true,
    'session_token', issued_token,
    'expires_at', session_expires_at,
    'staff_id', selected_staff.id,
    'staff_name', selected_staff.display_name,
    'staff_email', lower(selected_staff.email),
    'job_role', selected_staff.job_role,
    'must_change_credentials', selected_staff.credentials_initialized_at is null
  );
end;
$$;

create or replace function public.verify_staff_session(session_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_session_id bigint;
  selected_staff_id bigint;
  selected_staff public.staff_directory%rowtype;
  token_digest_value text;
begin
  if coalesce(trim(session_token), '') = '' then
    return jsonb_build_object('ok', false);
  end if;

  token_digest_value := encode(extensions.digest(session_token, 'sha256'), 'hex');

  select session_row.id, staff.id
  into selected_session_id, selected_staff_id
  from public.staff_sessions session_row
  join public.staff_directory staff on staff.id = session_row.staff_id
  where session_row.token_digest = token_digest_value
    and session_row.expires_at > now()
    and staff.active = true
  order by session_row.created_at desc
  limit 1;

  if selected_session_id is null then
    select session_row.id, staff.id
    into selected_session_id, selected_staff_id
    from public.staff_sessions session_row
    join public.staff_directory staff on staff.id = session_row.staff_id
    where session_row.token_digest is null
      and session_row.expires_at > now()
      and staff.active = true
      and session_row.session_hash like '$2%'
      and extensions.crypt(session_token, session_row.session_hash) = session_row.session_hash
    order by session_row.created_at desc
    limit 1;

    if selected_session_id is not null then
      update public.staff_sessions
      set token_digest = token_digest_value
      where id = selected_session_id;
    end if;
  end if;

  if selected_staff_id is null then
    return jsonb_build_object('ok', false);
  end if;

  select * into selected_staff
  from public.staff_directory staff
  where staff.id = selected_staff_id;

  return jsonb_build_object(
    'ok', true,
    'staff_id', selected_staff.id,
    'staff_name', selected_staff.display_name,
    'staff_email', lower(selected_staff.email),
    'job_role', selected_staff.job_role,
    'must_change_credentials', selected_staff.credentials_initialized_at is null
  );
end;
$$;

create or replace function public.change_staff_credentials(
  session_token text,
  new_password text,
  new_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_session_id bigint;
  selected_staff_id bigint;
  selected_staff public.staff_directory%rowtype;
  token_digest_value text;
begin
  if length(coalesce(new_password, '')) < 8 then
    raise exception 'Password must be at least 8 characters';
  end if;
  if new_password = '123456' then
    raise exception 'Choose a password different from the temporary password';
  end if;
  if coalesce(new_pin, '') !~ '^[0-9]{4}$' then
    raise exception 'PIN must contain exactly 4 digits';
  end if;
  if new_password = new_pin then
    raise exception 'Password and PIN must be different';
  end if;

  token_digest_value := encode(extensions.digest(session_token, 'sha256'), 'hex');

  select session_row.id, staff.id
  into selected_session_id, selected_staff_id
  from public.staff_sessions session_row
  join public.staff_directory staff on staff.id = session_row.staff_id
  where session_row.token_digest = token_digest_value
    and session_row.expires_at > now()
    and staff.active = true
  order by session_row.created_at desc
  limit 1;

  if selected_session_id is null then
    select session_row.id, staff.id
    into selected_session_id, selected_staff_id
    from public.staff_sessions session_row
    join public.staff_directory staff on staff.id = session_row.staff_id
    where session_row.token_digest is null
      and session_row.expires_at > now()
      and staff.active = true
      and session_row.session_hash like '$2%'
      and extensions.crypt(session_token, session_row.session_hash) = session_row.session_hash
    order by session_row.created_at desc
    limit 1;
  end if;

  if selected_staff_id is null then
    raise exception 'Invalid staff session';
  end if;

  select * into selected_staff
  from public.staff_directory staff
  where staff.id = selected_staff_id;
  if selected_staff.login_password_hash is not null
     and extensions.crypt(new_password, selected_staff.login_password_hash) = selected_staff.login_password_hash then
    raise exception 'Choose a new password different from the temporary password';
  end if;

  update public.staff_sessions
  set token_digest = token_digest_value
  where id = selected_session_id;

  update public.staff_directory
  set login_password_hash = extensions.crypt(new_password, extensions.gen_salt('bf', 12)),
      pin_hash = extensions.crypt(new_pin, extensions.gen_salt('bf', 12)),
      credentials_initialized_at = now(),
      updated_at = now()
  where id = selected_staff.id;

  delete from public.staff_sessions session_row
  where session_row.staff_id = selected_staff.id
    and session_row.id <> selected_session_id;

  return jsonb_build_object(
    'ok', true,
    'staff_id', selected_staff.id,
    'staff_name', selected_staff.display_name,
    'staff_email', lower(selected_staff.email),
    'job_role', selected_staff.job_role,
    'must_change_credentials', false
  );
end;
$$;

create or replace function public.revoke_staff_session(session_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  deleted_count integer := 0;
  token_digest_value text;
begin
  if coalesce(trim(session_token), '') = '' then
    return jsonb_build_object('ok', true);
  end if;

  token_digest_value := encode(extensions.digest(session_token, 'sha256'), 'hex');
  delete from public.staff_sessions where token_digest = token_digest_value;
  get diagnostics deleted_count = row_count;

  if deleted_count = 0 then
    delete from public.staff_sessions
    where token_digest is null
      and session_hash like '$2%'
      and extensions.crypt(session_token, session_hash) = session_hash;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- Loading the store/staff picker must not aggregate every store's inventory.
-- Inventory is loaded only after the user has selected one real store.
create or replace function public.get_daily_report_setup(session_token text, target_store_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  store_code_value text := nullif(trim(coalesce(target_store_code, '')), '');
  stores_payload jsonb;
  staff_payload jsonb;
  inventory_payload jsonb := '[]'::jsonb;
begin
  if not public.is_valid_staff_session(session_token) then
    raise exception 'Invalid session';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('store_code', store_location.store_code, 'store_name', store_location.store_name)
      order by store_location.sort_order, store_location.store_name
    ),
    '[]'::jsonb
  )
  into stores_payload
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse';

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', staff.id,
        'display_name', staff.display_name,
        'email', staff.email,
        'repairdesk_user_id', staff.repairdesk_user_id,
        'job_role', staff.job_role,
        'default_store_code', store_location.store_code,
        'default_store_name', store_location.store_name
      ) order by staff.display_name
    ),
    '[]'::jsonb
  )
  into staff_payload
  from public.staff_directory staff
  left join public.store_locations store_location on store_location.id = staff.default_store_id
  where staff.active = true;

  if store_code_value is not null then
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', lcd.id,
          'model_name', lcd.model_name,
          'variant_name', lcd.variant_name,
          'category_key', lcd.category_key,
          'current_qty', lcd.current_qty
        ) order by lcd.category_key, lcd.model_name, lcd.variant_name
      ),
      '[]'::jsonb
    )
    into inventory_payload
    from public.lcd_inventory_items lcd
    join public.store_locations store_location on store_location.id = lcd.store_id
    where lcd.active = true
      and store_location.active = true
      and store_location.store_code = store_code_value
      and store_location.store_code <> 'warehouse';
  end if;

  return jsonb_build_object(
    'ok', true,
    'stores', stores_payload,
    'staff', staff_payload,
    'lcd_items', inventory_payload
  );
end;
$$;

revoke all on function public.is_valid_staff_session(text) from public, anon, authenticated;
revoke all on function public.create_staff_session(text, text) from public, anon, authenticated;
revoke all on function public.verify_staff_session(text) from public, anon, authenticated;
revoke all on function public.change_staff_credentials(text, text, text) from public, anon, authenticated;
revoke all on function public.revoke_staff_session(text) from public, anon, authenticated;
revoke all on function public.get_daily_report_setup(text, text) from public, anon, authenticated;

grant execute on function public.is_valid_staff_session(text) to service_role;
grant execute on function public.create_staff_session(text, text) to anon, authenticated, service_role;
grant execute on function public.verify_staff_session(text) to anon, authenticated, service_role;
grant execute on function public.change_staff_credentials(text, text, text) to anon, authenticated, service_role;
grant execute on function public.revoke_staff_session(text) to anon, authenticated, service_role;
grant execute on function public.get_daily_report_setup(text, text) to anon, authenticated, service_role;

comment on column public.staff_sessions.token_digest is
  'Indexed SHA-256 digest of the random session token. session_hash remains as a bcrypt compatibility hash.';
