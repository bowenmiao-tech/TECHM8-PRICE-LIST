alter table public.staff_directory
  add column if not exists login_password_hash text,
  add column if not exists pin_hash text,
  add column if not exists credentials_initialized_at timestamptz,
  add column if not exists last_login_at timestamptz;

alter table public.staff_sessions
  add column if not exists staff_id bigint references public.staff_directory(id) on delete cascade;

-- Old shared-password sessions cannot be attributed to an individual staff member.
delete from public.staff_sessions;

alter table public.staff_sessions
  alter column staff_id set not null;

create unique index if not exists staff_directory_active_email_key
  on public.staff_directory (lower(email))
  where active = true and coalesce(trim(email), '') <> '';

create index if not exists staff_sessions_staff_expiry_idx
  on public.staff_sessions (staff_id, expires_at desc);

insert into public.staff_directory (display_name, email, job_role, active)
values ('Lydia', 'sulydia@outlook.com', 'staff', true)
on conflict (display_name) do update
set email = excluded.email,
    job_role = coalesce(public.staff_directory.job_role, excluded.job_role),
    active = true,
    updated_at = now();

update public.staff_directory staff
set email = account.email,
    updated_at = now()
from (
  values
    ('Andy', 'shangzelin2001@gmail.com'),
    ('Anna', 'ana04maria14@gmail.com'),
    ('Bonnie', 'bonniechiu1212aabb@gmail.com'),
    ('Fiona', 'yingmccoy@gmail.com'),
    ('Jinny', 'gksmftka@gmail.com'),
    ('Joanna Chen', '824195774@qq.com'),
    ('Lydia', 'sulydia@outlook.com')
) as account(display_name, email)
where staff.display_name = account.display_name;

update public.staff_directory
set login_password_hash = extensions.crypt('123456', extensions.gen_salt('bf', 12)),
    pin_hash = null,
    credentials_initialized_at = null,
    updated_at = now()
where active = true
  and coalesce(trim(email), '') <> ''
  and login_password_hash is null;

create or replace function public.is_valid_staff_session(session_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(trim(session_token), '') = '' then
    return false;
  end if;

  delete from public.staff_sessions where expires_at <= now();
  delete from public.admin_sessions where expires_at <= now();

  return exists (
    select 1
    from public.staff_sessions session_row
    join public.staff_directory staff on staff.id = session_row.staff_id
    where session_row.expires_at > now()
      and staff.active = true
      and staff.credentials_initialized_at is not null
      and extensions.crypt(session_token, session_row.session_hash) = session_row.session_hash
  ) or exists (
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
  session_expires_at := now() + interval '12 hours';

  insert into public.staff_sessions (staff_id, session_hash, expires_at)
  values (
    selected_staff.id,
    extensions.crypt(issued_token, extensions.gen_salt('bf', 12)),
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
  selected_staff public.staff_directory%rowtype;
begin
  if coalesce(trim(session_token), '') = '' then
    return jsonb_build_object('ok', false);
  end if;

  delete from public.staff_sessions where expires_at <= now();

  select staff.*
  into selected_staff
  from public.staff_sessions session_row
  join public.staff_directory staff on staff.id = session_row.staff_id
  where session_row.expires_at > now()
    and staff.active = true
    and extensions.crypt(session_token, session_row.session_hash) = session_row.session_hash
  order by session_row.created_at desc
  limit 1;

  if selected_staff.id is null then
    return jsonb_build_object('ok', false);
  end if;

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
  selected_staff public.staff_directory%rowtype;
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

  select staff.*
  into selected_staff
  from public.staff_sessions session_row
  join public.staff_directory staff on staff.id = session_row.staff_id
  where session_row.expires_at > now()
    and staff.active = true
    and extensions.crypt(session_token, session_row.session_hash) = session_row.session_hash
  order by session_row.created_at desc
  limit 1;

  if selected_staff.id is null then
    raise exception 'Invalid staff session';
  end if;

  update public.staff_directory
  set login_password_hash = extensions.crypt(new_password, extensions.gen_salt('bf', 12)),
      pin_hash = extensions.crypt(new_pin, extensions.gen_salt('bf', 12)),
      credentials_initialized_at = now(),
      updated_at = now()
  where id = selected_staff.id;

  delete from public.staff_sessions session_row
  where session_row.staff_id = selected_staff.id
    and extensions.crypt(session_token, session_row.session_hash) <> session_row.session_hash;

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

create or replace function public.verify_staff_pin(
  session_token text,
  target_staff_name text,
  input_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_staff public.staff_directory%rowtype;
begin
  if not public.is_valid_staff_session(session_token) then
    raise exception 'Invalid staff session';
  end if;

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and lower(trim(staff.display_name)) = lower(trim(coalesce(target_staff_name, '')))
  limit 1;

  if selected_staff.id is null
    or selected_staff.credentials_initialized_at is null
    or selected_staff.pin_hash is null
    or extensions.crypt(coalesce(input_pin, ''), selected_staff.pin_hash) <> selected_staff.pin_hash then
    return jsonb_build_object('ok', false, 'message', 'Incorrect staff PIN');
  end if;

  return jsonb_build_object(
    'ok', true,
    'staff_id', selected_staff.id,
    'staff_name', selected_staff.display_name
  );
end;
$$;

revoke all on function public.is_valid_staff_session(text) from public, anon, authenticated;
revoke all on function public.create_staff_session(text) from public, anon, authenticated;
revoke all on function public.create_staff_session(text, text) from public, anon, authenticated;
revoke all on function public.verify_staff_session(text) from public, anon, authenticated;
revoke all on function public.change_staff_credentials(text, text, text) from public, anon, authenticated;
revoke all on function public.verify_staff_pin(text, text, text) from public, anon, authenticated;

grant execute on function public.is_valid_staff_session(text) to service_role;
grant execute on function public.create_staff_session(text) to service_role;
grant execute on function public.create_staff_session(text, text) to anon, authenticated, service_role;
grant execute on function public.verify_staff_session(text) to anon, authenticated, service_role;
grant execute on function public.change_staff_credentials(text, text, text) to anon, authenticated, service_role;
grant execute on function public.verify_staff_pin(text, text, text) to anon, authenticated, service_role;

comment on column public.staff_directory.login_password_hash is
  'Per-staff portal password hash. New staff accounts begin with the temporary password and must replace it on first login.';
comment on column public.staff_directory.pin_hash is
  'Per-staff four-digit POS PIN hash, set during the first-login credential change.';
