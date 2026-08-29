-- Staff may belong to multiple stores. The legacy default_store_id is retained
-- as the primary store for older clients, while authorization uses this join
-- table as the source of truth.
create table if not exists public.staff_store_assignments (
  staff_id bigint not null references public.staff_directory(id) on delete cascade,
  store_id bigint not null references public.store_locations(id) on delete cascade,
  is_primary boolean not null default false,
  assigned_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (staff_id, store_id)
);

create unique index if not exists staff_store_assignments_one_primary_idx
  on public.staff_store_assignments (staff_id)
  where is_primary;

create index if not exists staff_store_assignments_store_id_idx
  on public.staff_store_assignments (store_id, staff_id);

alter table public.staff_store_assignments enable row level security;

revoke all on table public.staff_store_assignments from public, anon, authenticated;
grant select, insert, update, delete on table public.staff_store_assignments to service_role;

insert into public.staff_store_assignments (staff_id, store_id, is_primary)
select staff.id, staff.default_store_id, true
from public.staff_directory staff
join public.store_locations store_location
  on store_location.id = staff.default_store_id
where store_location.active = true
  and store_location.store_code <> 'warehouse'
on conflict (staff_id, store_id) do update
set is_primary = true,
    updated_at = now();

create or replace function public.sync_staff_primary_store_assignment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.default_store_id is distinct from old.default_store_id
    and new.default_store_id is not null
    and exists (
      select 1
      from public.store_locations store_location
      where store_location.id = new.default_store_id
        and store_location.active = true
        and store_location.store_code <> 'warehouse'
    ) then
    update public.staff_store_assignments assignment
    set is_primary = false,
        updated_at = now()
    where assignment.staff_id = new.id
      and assignment.is_primary = true;

    insert into public.staff_store_assignments (staff_id, store_id, is_primary)
    values (new.id, new.default_store_id, true)
    on conflict (staff_id, store_id) do update
    set is_primary = true,
        updated_at = now();
  end if;
  return new;
end;
$$;

drop trigger if exists sync_staff_primary_store_assignment_trigger
  on public.staff_directory;
create trigger sync_staff_primary_store_assignment_trigger
after update of default_store_id on public.staff_directory
for each row
execute function public.sync_staff_primary_store_assignment();

revoke all on function public.sync_staff_primary_store_assignment()
  from public, anon, authenticated;

create or replace function public.staff_has_store_access(
  target_staff_id bigint,
  target_store_id bigint
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.staff_store_assignments assignment
    join public.store_locations store_location
      on store_location.id = assignment.store_id
    where assignment.staff_id = target_staff_id
      and assignment.store_id = target_store_id
      and store_location.active = true
      and store_location.store_code <> 'warehouse'
  );
$$;

revoke all on function public.staff_has_store_access(bigint, bigint)
  from public, anon, authenticated;
grant execute on function public.staff_has_store_access(bigint, bigint)
  to service_role;

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
        'default_store_id', primary_store.id,
        'default_store_code', primary_store.store_code,
        'default_store_name', primary_store.store_name,
        'assigned_stores', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'store_id', assigned_store.id,
              'store_code', assigned_store.store_code,
              'store_name', assigned_store.store_name,
              'is_primary', assignment.is_primary
            ) order by assignment.is_primary desc, assigned_store.sort_order, assigned_store.store_name
          )
          from public.staff_store_assignments assignment
          join public.store_locations assigned_store
            on assigned_store.id = assignment.store_id
          where assignment.staff_id = staff.id
            and assigned_store.active = true
            and assigned_store.store_code <> 'warehouse'
        ), '[]'::jsonb),
        'stocktake_enabled', coalesce((
          select permission.enabled
          from public.pos_stocktake_permissions permission
          where permission.staff_id = staff.id
        ), false),
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
  left join public.store_locations primary_store
    on primary_store.id = staff.default_store_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'store_id', store_location.id,
        'store_code', store_location.store_code,
        'store_name', store_location.store_name
      ) order by store_location.sort_order, store_location.store_name
    ),
    '[]'::jsonb
  )
  into store_payload
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse';

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
  target_store_codes jsonb,
  target_active boolean,
  target_stocktake_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_staff public.staff_directory%rowtype;
  primary_store public.store_locations%rowtype;
  selected_admin_id bigint;
  selected_codes text[];
  requested_store_count integer := 0;
  valid_store_count integer := 0;
  is_bowen boolean := false;
  assigned_store_payload jsonb := '[]'::jsonb;
  stocktake_enabled_value boolean := coalesce(target_stocktake_enabled, false);
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;

  if jsonb_typeof(coalesce(target_store_codes, '[]'::jsonb)) <> 'array' then
    raise exception 'Store assignments must be an array';
  end if;

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.id = target_staff_id
  for update;

  if selected_staff.id is null then
    raise exception 'Staff member not found';
  end if;

  is_bowen := lower(trim(coalesce(selected_staff.email, ''))) = 'techm8contact@gmail.com';

  select coalesce(array_agg(code order by code), array[]::text[]), count(*)
  into selected_codes, requested_store_count
  from (
    select distinct lower(trim(value)) as code
    from jsonb_array_elements_text(coalesce(target_store_codes, '[]'::jsonb)) value
    where trim(value) <> ''
  ) requested_codes;

  select count(*)
  into valid_store_count
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse'
    and store_location.store_code = any(selected_codes);

  if not is_bowen and requested_store_count <> valid_store_count then
    raise exception 'One or more selected stores are unavailable';
  end if;

  if not is_bowen and coalesce(target_active, false) and valid_store_count = 0 then
    raise exception 'Select at least one active store for this staff member';
  end if;

  if not is_bowen then
    select store_location.*
    into primary_store
    from public.store_locations store_location
    where store_location.active = true
      and store_location.store_code <> 'warehouse'
      and store_location.store_code = any(selected_codes)
    order by
      case when store_location.id = selected_staff.default_store_id then 0 else 1 end,
      store_location.sort_order,
      store_location.store_name
    limit 1;

    delete from public.staff_store_assignments assignment
    where assignment.staff_id = selected_staff.id;

    insert into public.staff_store_assignments (staff_id, store_id, is_primary)
    select selected_staff.id,
           store_location.id,
           store_location.id = primary_store.id
    from public.store_locations store_location
    where store_location.active = true
      and store_location.store_code <> 'warehouse'
      and store_location.store_code = any(selected_codes)
    order by store_location.sort_order, store_location.store_name;

    update public.staff_directory staff
    set default_store_id = primary_store.id,
        active = coalesce(target_active, false),
        job_role = 'staff',
        updated_at = now()
    where staff.id = selected_staff.id
    returning * into selected_staff;
  else
    update public.staff_directory staff
    set active = true,
        job_role = 'admin',
        updated_at = now()
    where staff.id = selected_staff.id
    returning * into selected_staff;
  end if;

  select session_row.admin_user_id
  into selected_admin_id
  from public.admin_sessions session_row
  where session_row.expires_at > now()
    and extensions.crypt(session_token, session_row.session_hash) = session_row.session_hash
  order by session_row.created_at desc
  limit 1;

  insert into public.pos_stocktake_permissions (
    staff_id,
    enabled,
    changed_by_admin_id,
    enabled_at,
    disabled_at,
    updated_at
  ) values (
    selected_staff.id,
    stocktake_enabled_value,
    selected_admin_id,
    case when stocktake_enabled_value then now() else null end,
    case when stocktake_enabled_value then null else now() end,
    now()
  )
  on conflict (staff_id) do update
  set enabled = excluded.enabled,
      changed_by_admin_id = excluded.changed_by_admin_id,
      enabled_at = case
        when excluded.enabled and not public.pos_stocktake_permissions.enabled then now()
        when excluded.enabled then public.pos_stocktake_permissions.enabled_at
        else public.pos_stocktake_permissions.enabled_at
      end,
      disabled_at = case when not excluded.enabled then now() else null end,
      updated_at = now();

  if not selected_staff.active then
    delete from public.staff_sessions session_row
    where session_row.staff_id = selected_staff.id;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'store_id', store_location.id,
        'store_code', store_location.store_code,
        'store_name', store_location.store_name,
        'is_primary', assignment.is_primary
      ) order by assignment.is_primary desc, store_location.sort_order, store_location.store_name
    ),
    '[]'::jsonb
  )
  into assigned_store_payload
  from public.staff_store_assignments assignment
  join public.store_locations store_location on store_location.id = assignment.store_id
  where assignment.staff_id = selected_staff.id
    and store_location.active = true
    and store_location.store_code <> 'warehouse';

  select store_location.*
  into primary_store
  from public.store_locations store_location
  where store_location.id = selected_staff.default_store_id;

  return jsonb_build_object(
    'ok', true,
    'staff', jsonb_build_object(
      'staff_id', selected_staff.id,
      'display_name', selected_staff.display_name,
      'email', selected_staff.email,
      'job_role', selected_staff.job_role,
      'active', selected_staff.active,
      'default_store_id', primary_store.id,
      'default_store_code', primary_store.store_code,
      'default_store_name', primary_store.store_name,
      'assigned_stores', assigned_store_payload,
      'stocktake_enabled', stocktake_enabled_value,
      'credentials_ready', selected_staff.credentials_initialized_at is not null,
      'last_login_at', selected_staff.last_login_at,
      'updated_at', selected_staff.updated_at
    )
  );
end;
$$;

-- Keep the former single-store signature available for any cached client. It
-- preserves the current inventory flag and delegates to the multi-store RPC.
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
  current_stocktake_enabled boolean := false;
begin
  select coalesce(permission.enabled, false)
  into current_stocktake_enabled
  from public.pos_stocktake_permissions permission
  where permission.staff_id = target_staff_id;

  return public.update_staff_management(
    session_token,
    target_staff_id,
    case
      when nullif(trim(coalesce(target_store_code, '')), '') is null then '[]'::jsonb
      else jsonb_build_array(lower(trim(target_store_code)))
    end,
    target_active,
    current_stocktake_enabled
  );
end;
$$;

revoke all on function public.get_staff_management(text)
  from public, anon, authenticated;
revoke all on function public.update_staff_management(text, bigint, jsonb, boolean, boolean)
  from public, anon, authenticated;
revoke all on function public.update_staff_management(text, bigint, text, boolean)
  from public, anon, authenticated;
grant execute on function public.get_staff_management(text) to service_role;
grant execute on function public.update_staff_management(text, bigint, jsonb, boolean, boolean) to service_role;
grant execute on function public.update_staff_management(text, bigint, text, boolean) to service_role;

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
  is_allowed := is_admin or public.staff_has_store_access(selected_staff.id, selected_store.id);

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

revoke all on function public.verify_staff_store_access(text, text)
  from public, anon, authenticated;
grant execute on function public.verify_staff_store_access(text, text)
  to anon, authenticated, service_role;

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
    and (is_admin or public.staff_has_store_access(selected_staff.id, store_location.id));

  if store_code_value is not null and not is_admin and not exists (
    select 1
    from public.store_locations store_location
    where store_location.active = true
      and store_location.store_code <> 'warehouse'
      and store_location.store_code = store_code_value
      and public.staff_has_store_access(selected_staff.id, store_location.id)
  ) then
    raise exception 'This staff account is not assigned to the selected store';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', staff.id,
        'display_name', staff.display_name,
        'email', staff.email,
        'repairdesk_user_id', staff.repairdesk_user_id,
        'job_role', staff.job_role,
        'default_store_code', primary_store.store_code,
        'default_store_name', primary_store.store_name,
        'assigned_stores', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'store_code', assigned_store.store_code,
              'store_name', assigned_store.store_name,
              'is_primary', assignment.is_primary
            ) order by assignment.is_primary desc, assigned_store.sort_order, assigned_store.store_name
          )
          from public.staff_store_assignments assignment
          join public.store_locations assigned_store on assigned_store.id = assignment.store_id
          where assignment.staff_id = staff.id
            and assigned_store.active = true
            and assigned_store.store_code <> 'warehouse'
        ), '[]'::jsonb)
      ) order by staff.display_name
    ),
    '[]'::jsonb
  )
  into staff_payload
  from public.staff_directory staff
  left join public.store_locations primary_store on primary_store.id = staff.default_store_id
  where staff.active = true
    and (is_admin or staff.id = selected_staff.id)
    and (
      store_code_value is null
      or lower(trim(coalesce(staff.email, ''))) = 'techm8contact@gmail.com'
      or exists (
        select 1
        from public.store_locations requested_store
        where requested_store.active = true
          and requested_store.store_code = store_code_value
          and public.staff_has_store_access(staff.id, requested_store.id)
      )
    );

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

create or replace function public.pos_authorized_actor(
  session_token text,
  target_store_code text,
  requested_staff_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  access_result jsonb;
  selected_store public.store_locations%rowtype;
  selected_actor public.staff_directory%rowtype;
  signed_staff_id bigint;
  signed_email text;
  is_admin boolean;
  requested_name text := nullif(trim(coalesce(requested_staff_name, '')), '');
begin
  access_result := public.verify_staff_store_access(session_token, target_store_code);
  if not coalesce((access_result->>'ok')::boolean, false)
    or not coalesce((access_result->>'allowed')::boolean, false) then
    raise exception '%', coalesce(access_result->>'message', 'Store access denied');
  end if;

  signed_staff_id := nullif(access_result->>'staff_id', '')::bigint;
  signed_email := lower(trim(coalesce(access_result->>'staff_email', '')));
  is_admin := signed_email = 'techm8contact@gmail.com';

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code <> 'warehouse'
    and store_location.store_code = lower(trim(coalesce(target_store_code, '')))
  limit 1;
  if not found then raise exception 'Store not found'; end if;

  if is_admin and requested_name is not null then
    select * into selected_actor
    from public.staff_directory staff
    where staff.active = true
      and lower(staff.display_name) = lower(requested_name)
      and (
        public.staff_has_store_access(staff.id, selected_store.id)
        or lower(trim(staff.email)) = 'techm8contact@gmail.com'
      )
    limit 1;
    if not found then
      raise exception 'The selected staff member is not assigned to this store';
    end if;
  else
    select * into selected_actor
    from public.staff_directory staff
    where staff.id = signed_staff_id and staff.active = true
    limit 1;
    if not found then raise exception 'Staff member not found'; end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'is_admin', is_admin,
    'signed_staff_id', signed_staff_id,
    'staff_id', selected_actor.id,
    'staff_name', selected_actor.display_name,
    'staff_email', lower(trim(selected_actor.email)),
    'store_id', selected_store.id,
    'store_code', selected_store.store_code,
    'store_name', selected_store.store_name
  );
end;
$$;

revoke all on function public.pos_authorized_actor(text, text, text)
  from public, anon, authenticated;
grant execute on function public.pos_authorized_actor(text, text, text)
  to anon, authenticated, service_role;

-- The hardened daily-report functions already contain the ownership/read-only
-- rules. Replace only their single-store predicate so those same rules apply to
-- every assigned store without duplicating the full report implementation.
do $$
declare
  function_signature text;
  function_definition text;
  old_predicate text := 'if not is_admin and session_staff.default_store_id is distinct from selected_store.id then';
  new_predicate text := 'if not is_admin and not public.staff_has_store_access(session_staff.id, selected_store.id) then';
begin
  foreach function_signature in array array[
    'public.save_daily_report_draft(text,jsonb)',
    'public.get_daily_report_draft(text,text,text,text)',
    'public.list_daily_report_drafts(text,text,text)',
    'public.submit_daily_report(text,jsonb)'
  ] loop
    select pg_get_functiondef(to_regprocedure(function_signature))
    into function_definition;

    if function_definition is null or position(old_predicate in function_definition) = 0 then
      raise exception 'Expected store predicate was not found in %', function_signature;
    end if;

    execute replace(function_definition, old_predicate, new_predicate);
  end loop;
end;
$$;

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

comment on table public.staff_store_assignments is
  'The active POS stores assigned to each staff account. default_store_id remains the primary store for legacy clients.';
comment on function public.verify_staff_store_access(text, text) is
  'Authorizes any active POS store assigned to the signed-in staff account. Bowen may access every active POS store.';
comment on function public.get_staff_management(text) is
  'Admin-only staff management payload with multi-store assignments and inventory-management access.';
comment on function public.update_staff_management(text, bigint, jsonb, boolean, boolean) is
  'Admin-only update for staff store assignments, account status, and inventory-management access.';
