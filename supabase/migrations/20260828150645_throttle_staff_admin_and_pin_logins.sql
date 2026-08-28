-- Wire the throttle into the three credential checks.
-- Failure paths keep their original generic messages so nothing new is leaked
-- about whether an account exists; only the lock message is new.

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
  attempt_key text := lower(trim(coalesce(login_email, '')));
  lock_seconds integer;
begin
  lock_seconds := coalesce(public.pos_login_lock_seconds(attempt_key), 0);
  if lock_seconds > 0 then
    return jsonb_build_object(
      'ok', false,
      'locked', true,
      'retry_after_seconds', lock_seconds,
      'message', 'Too many failed attempts. Try again in '
        || greatest(1, ceil(lock_seconds / 60.0))::integer || ' minute(s).'
    );
  end if;

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and lower(trim(coalesce(staff.email, ''))) = attempt_key
  limit 1;

  if selected_staff.id is null
    or selected_staff.login_password_hash is null
    or extensions.crypt(coalesce(input_password, ''), selected_staff.login_password_hash) <> selected_staff.login_password_hash then
    perform public.register_pos_login_failure(attempt_key);
    return jsonb_build_object('ok', false, 'message', 'Incorrect email or password');
  end if;

  perform public.clear_pos_login_failures(attempt_key);
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

create or replace function public.create_admin_session(login_email text, input_password text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  admin_record public.admin_users%rowtype;
  issued_token text;
  session_expires_at timestamptz;
  attempt_key text := 'admin:' || lower(trim(coalesce(create_admin_session.login_email, '')));
  lock_seconds integer;
begin
  lock_seconds := coalesce(public.pos_login_lock_seconds(attempt_key), 0);
  if lock_seconds > 0 then
    return jsonb_build_object(
      'ok', false,
      'locked', true,
      'retry_after_seconds', lock_seconds,
      'message', 'Too many failed attempts. Try again in '
        || greatest(1, ceil(lock_seconds / 60.0))::integer || ' minute(s).'
    );
  end if;

  select *
  into admin_record
  from public.admin_users
  where active = true
    and admin_users.login_email = lower(coalesce(trim(create_admin_session.login_email), ''));

  if not found
    or extensions.crypt(input_password, admin_record.password_hash) <> admin_record.password_hash then
    perform public.register_pos_login_failure(attempt_key);
    return jsonb_build_object('ok', false, 'message', 'Incorrect email or password');
  end if;

  perform public.clear_pos_login_failures(attempt_key);
  delete from public.admin_sessions where expires_at <= now();

  issued_token := encode(extensions.gen_random_bytes(24), 'hex');
  session_expires_at := now() + interval '12 hours';

  insert into public.admin_sessions (admin_user_id, session_hash, expires_at)
  values (
    admin_record.id,
    extensions.crypt(issued_token, extensions.gen_salt('bf')),
    session_expires_at
  );

  return jsonb_build_object(
    'ok', true,
    'session_token', issued_token,
    'expires_at', session_expires_at,
    'login_email', admin_record.login_email
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
  attempt_key text := 'pin:' || lower(trim(coalesce(target_staff_name, '')));
  lock_seconds integer;
begin
  if not public.is_valid_staff_session(session_token) then
    raise exception 'Invalid staff session';
  end if;

  lock_seconds := coalesce(public.pos_login_lock_seconds(attempt_key), 0);
  if lock_seconds > 0 then
    return jsonb_build_object(
      'ok', false,
      'locked', true,
      'retry_after_seconds', lock_seconds,
      'message', 'Too many incorrect PINs. Try again in '
        || greatest(1, ceil(lock_seconds / 60.0))::integer || ' minute(s).'
    );
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
    perform public.register_pos_login_failure(attempt_key);
    return jsonb_build_object('ok', false, 'message', 'Incorrect staff PIN');
  end if;

  perform public.clear_pos_login_failures(attempt_key);
  return jsonb_build_object(
    'ok', true,
    'staff_id', selected_staff.id,
    'staff_name', selected_staff.display_name
  );
end;
$$;
