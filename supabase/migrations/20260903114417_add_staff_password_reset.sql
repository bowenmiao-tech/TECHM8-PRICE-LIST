-- Self-service staff password reset backed by single-use, expiring tokens.
--
-- Only the raw token is ever emailed; the database stores its SHA-256 digest,
-- the same way staff session tokens are stored. Every function here is
-- service-role only, so the browser must go through the edge function and can
-- neither enumerate staff emails nor bypass the request throttle.

create table if not exists public.staff_password_resets (
  id bigserial primary key,
  staff_id bigint not null references public.staff_directory(id) on delete cascade,
  token_digest text not null unique,
  requested_email text not null,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists staff_password_resets_staff_created_idx
  on public.staff_password_resets (staff_id, created_at desc);

alter table public.staff_password_resets enable row level security;

revoke all on table public.staff_password_resets from public;
revoke all on table public.staff_password_resets from anon;
revoke all on table public.staff_password_resets from authenticated;

comment on table public.staff_password_resets is
  'Single-use staff password reset tokens. Stores only the SHA-256 digest of the emailed token.';

-- Issues a reset token. Returns ok for every input so a caller cannot learn
-- whether an email belongs to an active staff account.
create or replace function public.request_staff_password_reset(login_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_staff public.staff_directory%rowtype;
  normalized_email text;
  recent_requests integer;
  raw_token text;
  token_lifetime constant interval := interval '30 minutes';
begin
  normalized_email := lower(trim(coalesce(login_email, '')));
  if normalized_email = '' then
    return jsonb_build_object('ok', true, 'issued', false);
  end if;

  delete from public.staff_password_resets
  where created_at < now() - interval '7 days';

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and lower(coalesce(staff.email, '')) = normalized_email
  limit 1;

  if not found then
    return jsonb_build_object('ok', true, 'issued', false);
  end if;

  select count(*)
  into recent_requests
  from public.staff_password_resets reset_row
  where reset_row.staff_id = selected_staff.id
    and reset_row.created_at > now() - interval '15 minutes';

  if recent_requests >= 3 then
    return jsonb_build_object('ok', true, 'issued', false, 'throttled', true);
  end if;

  update public.staff_password_resets
  set used_at = now()
  where staff_id = selected_staff.id
    and used_at is null
    and expires_at > now();

  raw_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into public.staff_password_resets (staff_id, token_digest, requested_email, expires_at)
  values (
    selected_staff.id,
    encode(extensions.digest(raw_token, 'sha256'), 'hex'),
    normalized_email,
    now() + token_lifetime
  );

  return jsonb_build_object(
    'ok', true,
    'issued', true,
    'reset_token', raw_token,
    'staff_name', selected_staff.display_name,
    'staff_email', lower(selected_staff.email),
    'expires_in_minutes', 30
  );
end;
$$;

create or replace function public.verify_staff_password_reset(reset_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_staff public.staff_directory%rowtype;
begin
  if coalesce(reset_token, '') = '' then
    return jsonb_build_object('ok', true, 'valid', false);
  end if;

  select staff.*
  into selected_staff
  from public.staff_password_resets reset_row
  join public.staff_directory staff on staff.id = reset_row.staff_id
  where reset_row.token_digest = encode(extensions.digest(reset_token, 'sha256'), 'hex')
    and reset_row.used_at is null
    and reset_row.expires_at > now()
    and staff.active = true
  limit 1;

  if not found then
    return jsonb_build_object('ok', true, 'valid', false);
  end if;

  return jsonb_build_object(
    'ok', true,
    'valid', true,
    'staff_name', selected_staff.display_name,
    'staff_email', lower(selected_staff.email)
  );
end;
$$;

-- Consumes the token and rewrites the credentials. An empty new_pin keeps the
-- staff member's existing PIN, so forgetting a password does not force a PIN
-- change. Every existing session is revoked.
create or replace function public.complete_staff_password_reset(
  reset_token text,
  new_password text,
  new_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_reset public.staff_password_resets%rowtype;
  selected_staff public.staff_directory%rowtype;
  trimmed_pin text;
begin
  trimmed_pin := coalesce(trim(new_pin), '');

  if length(coalesce(new_password, '')) < 8 then
    raise exception 'Password must be at least 8 characters';
  end if;
  if new_password = '123456' then
    raise exception 'Choose a password different from the temporary password';
  end if;
  if trimmed_pin <> '' and trimmed_pin !~ '^[0-9]{4}$' then
    raise exception 'PIN must contain exactly 4 digits';
  end if;
  if trimmed_pin <> '' and new_password = trimmed_pin then
    raise exception 'Password and PIN must be different';
  end if;

  select *
  into selected_reset
  from public.staff_password_resets reset_row
  where reset_row.token_digest = encode(extensions.digest(coalesce(reset_token, ''), 'sha256'), 'hex')
    and reset_row.used_at is null
    and reset_row.expires_at > now()
  for update;

  if not found then
    raise exception 'This reset link is no longer valid. Request a new one.';
  end if;

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.id = selected_reset.staff_id
    and staff.active = true;

  if not found then
    raise exception 'This reset link is no longer valid. Request a new one.';
  end if;

  -- An account that has never completed first login has no PIN yet, so a reset
  -- must set one rather than silently marking the credentials as initialized.
  if selected_staff.pin_hash is null and trimmed_pin = '' then
    raise exception 'This account has no POS PIN yet, so a new 4-digit PIN is required';
  end if;

  update public.staff_directory
  set login_password_hash = extensions.crypt(new_password, extensions.gen_salt('bf', 12)),
      pin_hash = case
        when trimmed_pin <> '' then extensions.crypt(trimmed_pin, extensions.gen_salt('bf', 12))
        else pin_hash
      end,
      credentials_initialized_at = coalesce(credentials_initialized_at, now()),
      updated_at = now()
  where id = selected_staff.id;

  update public.staff_password_resets
  set used_at = now()
  where id = selected_reset.id;

  delete from public.staff_sessions session_row
  where session_row.staff_id = selected_staff.id;

  return jsonb_build_object(
    'ok', true,
    'staff_name', selected_staff.display_name,
    'staff_email', lower(selected_staff.email),
    'pin_changed', trimmed_pin <> ''
  );
end;
$$;

revoke all on function public.request_staff_password_reset(text) from public;
revoke all on function public.request_staff_password_reset(text) from anon;
revoke all on function public.request_staff_password_reset(text) from authenticated;
grant execute on function public.request_staff_password_reset(text) to service_role;

revoke all on function public.verify_staff_password_reset(text) from public;
revoke all on function public.verify_staff_password_reset(text) from anon;
revoke all on function public.verify_staff_password_reset(text) from authenticated;
grant execute on function public.verify_staff_password_reset(text) to service_role;

revoke all on function public.complete_staff_password_reset(text, text, text) from public;
revoke all on function public.complete_staff_password_reset(text, text, text) from anon;
revoke all on function public.complete_staff_password_reset(text, text, text) from authenticated;
grant execute on function public.complete_staff_password_reset(text, text, text) to service_role;

comment on function public.request_staff_password_reset(text) is
  'Issues a single-use staff password reset token, throttled to 3 requests per staff member every 15 minutes. Always reports success so staff emails cannot be enumerated.';
comment on function public.verify_staff_password_reset(text) is
  'Reports whether a staff password reset token is still usable, without consuming it.';
comment on function public.complete_staff_password_reset(text, text, text) is
  'Consumes a staff password reset token, rewrites the password (and optionally the PIN), and revokes every existing session.';
