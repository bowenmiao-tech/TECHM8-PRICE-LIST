-- Brassall joins the active POS stores and follows the same first-login flow as
-- every other staff account. Existing credentials are preserved if this
-- migration is reapplied after the account has already been initialized.
insert into public.store_locations (
  store_code,
  store_name,
  sort_order,
  active
)
values ('brassall', 'Brassall', 6, true)
on conflict (store_code) do update
set store_name = excluded.store_name,
    sort_order = excluded.sort_order,
    active = true,
    updated_at = now();

insert into public.staff_directory (
  display_name,
  email,
  job_role,
  default_store_id,
  active,
  login_password_hash,
  pin_hash,
  credentials_initialized_at
)
select
  'Brassall',
  'techm8.brassall@gmail.com',
  'staff',
  store_location.id,
  true,
  extensions.crypt('123456', extensions.gen_salt('bf', 12)),
  null,
  null
from public.store_locations store_location
where store_location.store_code = 'brassall'
on conflict (display_name) do update
set email = excluded.email,
    job_role = 'staff',
    default_store_id = excluded.default_store_id,
    active = true,
    login_password_hash = coalesce(
      public.staff_directory.login_password_hash,
      excluded.login_password_hash
    ),
    updated_at = now();

-- Include the database-backed store assignment in the authenticated profile.
-- The login email remains the authorization identity: Bowen is the only admin.
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
  selected_store public.store_locations%rowtype;
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

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.id = selected_staff_id;

  if selected_staff.default_store_id is not null then
    select *
    into selected_store
    from public.store_locations store_location
    where store_location.id = selected_staff.default_store_id
      and store_location.active = true;
  end if;

  return jsonb_build_object(
    'ok', true,
    'staff_id', selected_staff.id,
    'staff_name', selected_staff.display_name,
    'staff_email', lower(selected_staff.email),
    'job_role', selected_staff.job_role,
    'default_store_code', selected_store.store_code,
    'default_store_name', selected_store.store_name,
    'must_change_credentials', selected_staff.credentials_initialized_at is null
  );
end;
$$;

-- This RPC is the server-side authorization check used by POS clients and Edge
-- Functions. Staff may access only their default store; Bowen may access every
-- active POS store.
create or replace function public.verify_staff_store_access(
  session_token text,
  target_store_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_profile jsonb;
  selected_staff public.staff_directory%rowtype;
  selected_store public.store_locations%rowtype;
  is_admin boolean := false;
  is_allowed boolean := false;
begin
  session_profile := public.verify_staff_session(session_token);
  if not coalesce((session_profile->>'ok')::boolean, false) then
    return jsonb_build_object(
      'ok', false,
      'allowed', false,
      'message', 'Invalid staff session.'
    );
  end if;

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.id = nullif(session_profile->>'staff_id', '')::bigint
    and staff.active = true
  limit 1;

  select *
  into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse'
    and store_location.store_code = lower(trim(coalesce(target_store_code, '')))
  limit 1;

  if selected_staff.id is null or selected_store.id is null then
    return jsonb_build_object(
      'ok', false,
      'allowed', false,
      'message', 'The selected POS store is unavailable.'
    );
  end if;

  is_admin := lower(trim(coalesce(selected_staff.email, ''))) = 'techm8contact@gmail.com';
  is_allowed := is_admin or selected_staff.default_store_id = selected_store.id;

  return jsonb_build_object(
    'ok', is_allowed,
    'allowed', is_allowed,
    'message', case
      when is_allowed then null
      else 'This staff account is not assigned to the selected store.'
    end,
    'staff_id', selected_staff.id,
    'staff_name', selected_staff.display_name,
    'staff_email', lower(trim(selected_staff.email)),
    'job_role', selected_staff.job_role,
    'store_code', selected_store.store_code,
    'store_name', selected_store.store_name,
    'default_store_code', session_profile->>'default_store_code',
    'default_store_name', session_profile->>'default_store_name'
  );
end;
$$;

-- Setup data is filtered by the signed-in account. This prevents a staff login
-- from discovering or selecting another store even if browser state is edited.
create or replace function public.get_daily_report_setup(
  session_token text,
  target_store_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  store_code_value text := nullif(lower(trim(coalesce(target_store_code, ''))), '');
  session_profile jsonb;
  selected_staff public.staff_directory%rowtype;
  is_admin boolean := false;
  stores_payload jsonb;
  staff_payload jsonb;
  inventory_payload jsonb := '[]'::jsonb;
begin
  session_profile := public.verify_staff_session(session_token);
  if not coalesce((session_profile->>'ok')::boolean, false) then
    raise exception 'Invalid session';
  end if;

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.id = nullif(session_profile->>'staff_id', '')::bigint
    and staff.active = true
  limit 1;

  if selected_staff.id is null then
    raise exception 'Active staff account not found';
  end if;

  is_admin := lower(trim(coalesce(selected_staff.email, ''))) = 'techm8contact@gmail.com';
  if store_code_value = '__setup_only__' then
    store_code_value := null;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'store_code', store_location.store_code,
        'store_name', store_location.store_name
      ) order by store_location.sort_order, store_location.store_name
    ),
    '[]'::jsonb
  )
  into stores_payload
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse'
    and (is_admin or store_location.id = selected_staff.default_store_id);

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
  where staff.active = true
    and (is_admin or staff.id = selected_staff.id);

  if store_code_value is not null then
    if not is_admin and not exists (
      select 1
      from public.store_locations store_location
      where store_location.id = selected_staff.default_store_id
        and store_location.active = true
        and store_location.store_code = store_code_value
        and store_location.store_code <> 'warehouse'
    ) then
      raise exception 'This staff account is not assigned to the selected store';
    end if;

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

revoke all on function public.verify_staff_store_access(text, text) from public, anon, authenticated;
grant execute on function public.verify_staff_store_access(text, text) to anon, authenticated, service_role;

comment on function public.verify_staff_store_access(text, text) is
  'Authorizes the store requested by a staff session. Bowen may access every active POS store; other accounts may access only their active default store.';
