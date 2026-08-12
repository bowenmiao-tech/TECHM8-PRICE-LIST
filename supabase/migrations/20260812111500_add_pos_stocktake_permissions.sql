create table if not exists public.pos_stocktake_permissions (
  staff_id bigint primary key references public.staff_directory(id) on delete cascade,
  enabled boolean not null default false,
  changed_by_admin_id bigint references public.admin_users(id) on delete set null,
  enabled_at timestamptz,
  disabled_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.pos_stocktake_permissions enable row level security;

revoke all on table public.pos_stocktake_permissions from public, anon, authenticated;

drop policy if exists pos_stocktake_permissions_no_direct_access on public.pos_stocktake_permissions;
create policy pos_stocktake_permissions_no_direct_access
on public.pos_stocktake_permissions
for all
to anon, authenticated
using (false)
with check (false);

create index if not exists pos_stocktake_permissions_enabled_idx
  on public.pos_stocktake_permissions (enabled, staff_id);

create or replace function public.get_pos_stocktake_permissions(session_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  staff_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'staff_id', staff.id,
        'display_name', staff.display_name,
        'job_role', staff.job_role,
        'default_store_code', stores.store_code,
        'default_store_name', stores.store_name,
        'enabled', coalesce(permission.enabled, false),
        'enabled_at', permission.enabled_at,
        'disabled_at', permission.disabled_at,
        'updated_at', permission.updated_at
      )
      order by staff.display_name
    ),
    '[]'::jsonb
  )
  into staff_payload
  from public.staff_directory staff
  left join public.store_locations stores on stores.id = staff.default_store_id
  left join public.pos_stocktake_permissions permission on permission.staff_id = staff.id
  where staff.active = true;

  return jsonb_build_object('ok', true, 'staff', staff_payload);
end;
$$;

create or replace function public.set_pos_stocktake_permission(
  session_token text,
  target_staff_id bigint,
  target_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_admin_id bigint;
  selected_staff public.staff_directory%rowtype;
  result_row public.pos_stocktake_permissions%rowtype;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;

  select session_row.admin_user_id
  into selected_admin_id
  from public.admin_sessions session_row
  where session_row.expires_at > now()
    and extensions.crypt(session_token, session_row.session_hash) = session_row.session_hash
  order by session_row.created_at desc
  limit 1;

  select *
  into selected_staff
  from public.staff_directory
  where id = target_staff_id
    and active = true;

  if selected_staff.id is null then
    raise exception 'Active staff member not found';
  end if;

  insert into public.pos_stocktake_permissions (
    staff_id,
    enabled,
    changed_by_admin_id,
    enabled_at,
    disabled_at,
    updated_at
  )
  values (
    selected_staff.id,
    coalesce(target_enabled, false),
    selected_admin_id,
    case when coalesce(target_enabled, false) then now() else null end,
    case when coalesce(target_enabled, false) then null else now() end,
    now()
  )
  on conflict (staff_id) do update
  set
    enabled = excluded.enabled,
    changed_by_admin_id = excluded.changed_by_admin_id,
    enabled_at = case
      when excluded.enabled and not public.pos_stocktake_permissions.enabled then now()
      when excluded.enabled then public.pos_stocktake_permissions.enabled_at
      else public.pos_stocktake_permissions.enabled_at
    end,
    disabled_at = case
      when not excluded.enabled then now()
      else null
    end,
    updated_at = now()
  returning * into result_row;

  return jsonb_build_object(
    'ok', true,
    'staff_id', selected_staff.id,
    'display_name', selected_staff.display_name,
    'enabled', result_row.enabled,
    'updated_at', result_row.updated_at
  );
end;
$$;

create or replace function public.get_staff_stocktake_access(
  session_token text,
  target_staff_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_staff public.staff_directory%rowtype;
  permission_enabled boolean := false;
begin
  if not public.is_valid_staff_session(session_token) then
    raise exception 'Invalid staff session';
  end if;

  select *
  into selected_staff
  from public.staff_directory
  where active = true
    and lower(trim(display_name)) = lower(trim(coalesce(target_staff_name, '')))
  order by id
  limit 1;

  if selected_staff.id is null then
    return jsonb_build_object(
      'ok', false,
      'enabled', false,
      'message', 'Active staff member not found.'
    );
  end if;

  select coalesce(permission.enabled, false)
  into permission_enabled
  from public.pos_stocktake_permissions permission
  where permission.staff_id = selected_staff.id;

  return jsonb_build_object(
    'ok', true,
    'staff_id', selected_staff.id,
    'display_name', selected_staff.display_name,
    'enabled', coalesce(permission_enabled, false)
  );
end;
$$;

revoke all on function public.get_pos_stocktake_permissions(text) from public;
revoke all on function public.set_pos_stocktake_permission(text, bigint, boolean) from public;
revoke all on function public.get_staff_stocktake_access(text, text) from public;

grant execute on function public.get_pos_stocktake_permissions(text) to anon, authenticated;
grant execute on function public.set_pos_stocktake_permission(text, bigint, boolean) to anon, authenticated;
grant execute on function public.get_staff_stocktake_access(text, text) to anon, authenticated;
