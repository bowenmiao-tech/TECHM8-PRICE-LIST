-- Keep concurrent device sessions during the required first-login setup, but
-- preserve the security behavior of revoking other devices for a later
-- password change.
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

  if selected_staff.credentials_initialized_at is not null then
    delete from public.staff_sessions session_row
    where session_row.staff_id = selected_staff.id
      and session_row.id <> selected_session_id;
  end if;

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

comment on function public.change_staff_credentials(text, text, text) is
  'Completes first-login credentials without revoking other devices; later password changes revoke other sessions.';
