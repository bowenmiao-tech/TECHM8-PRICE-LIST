-- Login throttling.
--
-- create_staff_session, create_admin_session and verify_staff_pin could all be
-- retried without limit. The anon key is public, so a 4-digit POS PIN (10,000
-- combinations) and the documented starter password were both reachable by
-- simple repetition.
--
-- Failures are counted per identifier in a rolling 15 minute window:
--   8 failures  -> locked for 15 minutes
--   16 failures -> locked for 60 minutes
-- A success clears the counter. The window resets once no new failure has been
-- recorded for 15 minutes.
--
-- Trade-off: the key is the submitted identifier, so someone who knows a staff
-- email can deliberately lock that account for 15 minutes. Postgres has no view
-- of the client IP here; the short lock keeps that nuisance bounded.

create table if not exists public.pos_login_attempts (
  identifier text primary key,
  failed_count integer not null default 0 check (failed_count >= 0),
  first_failed_at timestamptz,
  last_failed_at timestamptz,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.pos_login_attempts enable row level security;
revoke all on public.pos_login_attempts from public, anon, authenticated;
grant select, insert, update, delete on public.pos_login_attempts to service_role;

create index if not exists pos_login_attempts_locked_until_idx
on public.pos_login_attempts (locked_until)
where locked_until is not null;

-- Seconds still remaining on a lock; 0 when the identifier is free to try.
create or replace function public.pos_login_lock_seconds(target_identifier text)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(0, ceil(extract(epoch from (attempt.locked_until - now())))::integer)
  from public.pos_login_attempts attempt
  where attempt.identifier = lower(trim(coalesce(target_identifier, '')))
    and attempt.locked_until is not null
    and attempt.locked_until > now();
$$;

create or replace function public.register_pos_login_failure(target_identifier text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  key_value text := lower(trim(coalesce(target_identifier, '')));
  attempt_row public.pos_login_attempts%rowtype;
  next_count integer;
begin
  if key_value = '' then return; end if;

  select * into attempt_row
  from public.pos_login_attempts
  where identifier = key_value
  for update;

  -- Start a fresh window when the previous one has gone quiet.
  if not found or attempt_row.last_failed_at is null
     or attempt_row.last_failed_at < now() - interval '15 minutes' then
    next_count := 1;
  else
    next_count := attempt_row.failed_count + 1;
  end if;

  insert into public.pos_login_attempts (
    identifier, failed_count, first_failed_at, last_failed_at, locked_until, updated_at
  ) values (
    key_value,
    next_count,
    case when next_count = 1 then now() else coalesce(attempt_row.first_failed_at, now()) end,
    now(),
    case
      when next_count >= 16 then now() + interval '60 minutes'
      when next_count >= 8 then now() + interval '15 minutes'
      else null
    end,
    now()
  )
  on conflict (identifier) do update set
    failed_count = excluded.failed_count,
    first_failed_at = excluded.first_failed_at,
    last_failed_at = excluded.last_failed_at,
    locked_until = excluded.locked_until,
    updated_at = now();
end;
$$;

create or replace function public.clear_pos_login_failures(target_identifier text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.pos_login_attempts
  where identifier = lower(trim(coalesce(target_identifier, '')));
$$;

revoke all on function public.pos_login_lock_seconds(text) from public, anon, authenticated;
revoke all on function public.register_pos_login_failure(text) from public, anon, authenticated;
revoke all on function public.clear_pos_login_failures(text) from public, anon, authenticated;
grant execute on function public.pos_login_lock_seconds(text) to service_role;
grant execute on function public.register_pos_login_failure(text) to service_role;
grant execute on function public.clear_pos_login_failures(text) to service_role;

comment on table public.pos_login_attempts is
  'Rolling failed-login counters. Keyed by submitted email, admin:<email>, or pin:<staff name>.';
