-- Configure Bowen without storing the temporary plaintext password in source control.
update public.staff_directory
set email = 'techm8contact@gmail.com',
    login_password_hash = '$2a$10$7Ulu7jfyiXtlSwzEcg8aXOkamQ2AimWCAMLl.A6iWmCXEwrAg/7VC',
    pin_hash = null,
    credentials_initialized_at = null,
    last_login_at = null,
    active = true,
    updated_at = now()
where lower(trim(display_name)) = 'bowen';

delete from public.staff_sessions
where staff_id in (
  select id from public.staff_directory where lower(trim(display_name)) = 'bowen'
);

-- A first-login password must genuinely differ from the temporary password,
-- including accounts that were assigned a non-default temporary password.
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
  if selected_staff.login_password_hash is not null
     and extensions.crypt(new_password, selected_staff.login_password_hash) = selected_staff.login_password_hash then
    raise exception 'Choose a new password different from the temporary password';
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

revoke all on function public.change_staff_credentials(text, text, text) from public, anon, authenticated;
grant execute on function public.change_staff_credentials(text, text, text) to anon, authenticated, service_role;
