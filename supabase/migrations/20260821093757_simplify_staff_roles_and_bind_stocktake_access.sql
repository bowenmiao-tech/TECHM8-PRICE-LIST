-- The staff login email is the authorization identity. Bowen's account is the
-- only admin; every other directory entry is a staff account.
update public.staff_directory
set job_role = case
      when lower(trim(coalesce(email, ''))) = 'techm8contact@gmail.com' then 'admin'
      else 'staff'
    end,
    updated_at = now()
where job_role is distinct from case
        when lower(trim(coalesce(email, ''))) = 'techm8contact@gmail.com' then 'admin'
        else 'staff'
      end;

alter table public.staff_directory
  alter column job_role set default 'staff',
  alter column job_role set not null;

alter table public.staff_directory
  drop constraint if exists staff_directory_job_role_check;

alter table public.staff_directory
  add constraint staff_directory_job_role_check
  check (job_role in ('admin', 'staff'));

create or replace function public.enforce_staff_directory_role()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.job_role := case
    when lower(trim(coalesce(new.email, ''))) = 'techm8contact@gmail.com' then 'admin'
    else 'staff'
  end;
  return new;
end;
$$;

drop trigger if exists enforce_staff_directory_role_trigger on public.staff_directory;
create trigger enforce_staff_directory_role_trigger
before insert or update of email, job_role on public.staff_directory
for each row
execute function public.enforce_staff_directory_role();

revoke all on function public.enforce_staff_directory_role() from public, anon, authenticated;

-- Keep the existing two-argument RPC for deployed clients, but deliberately
-- ignore target_staff_name. Stocktake access now belongs to the account that
-- owns session_token, so one staff member cannot inherit another person's flag.
create or replace function public.get_staff_stocktake_access(
  session_token text,
  target_staff_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_profile jsonb;
  selected_staff public.staff_directory%rowtype;
  permission_enabled boolean := false;
begin
  session_profile := public.verify_staff_session(session_token);

  if not coalesce((session_profile->>'ok')::boolean, false) then
    raise exception 'Invalid staff session';
  end if;

  select staff.*
  into selected_staff
  from public.staff_directory staff
  where staff.id = nullif(session_profile->>'staff_id', '')::bigint
    and staff.active = true
  limit 1;

  if selected_staff.id is null then
    return jsonb_build_object(
      'ok', false,
      'enabled', false,
      'message', 'Active staff account not found.'
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
    'staff_email', lower(trim(selected_staff.email)),
    'job_role', selected_staff.job_role,
    'enabled', coalesce(permission_enabled, false)
  );
end;
$$;

create or replace function public.get_pos_stocktake_permissions(session_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
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
        'email', lower(trim(staff.email)),
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

revoke all on function public.get_staff_stocktake_access(text, text) from public, anon, authenticated;
revoke all on function public.get_pos_stocktake_permissions(text) from public, anon, authenticated;
grant execute on function public.get_staff_stocktake_access(text, text) to anon, authenticated, service_role;
grant execute on function public.get_pos_stocktake_permissions(text) to anon, authenticated, service_role;

comment on column public.staff_directory.job_role is
  'Authorization role: techm8contact@gmail.com is admin; all other staff accounts are staff.';

comment on function public.get_staff_stocktake_access(text, text) is
  'Returns stocktake access for the staff account bound to session_token. target_staff_name is retained only for client compatibility.';
