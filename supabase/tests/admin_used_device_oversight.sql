-- Admin buyback oversight. Run against the staff/POS project.
-- Every fixture write is rolled back.
begin;
do $test$
declare
  admin_token text := extensions.gen_random_uuid()::text;
  admin_id bigint;
  overview jsonb;
  register jsonb;
  alerts jsonb;
  reconciliation jsonb;
  denied boolean;
begin
  select id into admin_id from public.admin_users where active limit 1;
  if admin_id is null then raise exception 'No active admin user'; end if;
  insert into public.admin_sessions(admin_user_id, session_hash, expires_at)
    values (admin_id, extensions.crypt(admin_token, extensions.gen_salt('bf')), now() + interval '5 minutes');

  overview := public.get_admin_used_device_overview(admin_token, current_date - 365, current_date);
  assert (overview->>'ok')::boolean and jsonb_typeof(overview->'stores') = 'array', 'Overview did not return store rows';
  assert overview->'totals' ? 'paid_out', 'Overview totals are missing the payout figure';

  register := public.get_admin_used_device_register(admin_token, jsonb_build_object(
    'date_from', (current_date - 700)::text, 'date_to', current_date::text));
  assert (register->>'ok')::boolean and jsonb_typeof(register->'rows') = 'array', 'Register did not return rows';

  alerts := public.get_admin_used_device_alerts(admin_token, 365);
  assert (alerts->>'ok')::boolean and jsonb_typeof(alerts->'alerts') = 'array', 'Alerts did not return a list';

  reconciliation := public.get_admin_used_device_reconciliation(admin_token, current_date - 365, current_date);
  assert (reconciliation->>'ok')::boolean and jsonb_typeof(reconciliation->'rows') = 'array', 'Reconciliation did not return rows';

  -- The register carries seller identity, so a staff session must never reach it.
  denied := false;
  begin perform public.get_admin_used_device_register('not-a-session', '{}'::jsonb);
  exception when others then denied := true;
  end;
  assert denied, 'The register answered without an admin session';

  denied := false;
  begin perform public.get_admin_used_device_overview(admin_token, current_date, current_date - 1);
  exception when others then denied := true;
  end;
  assert denied, 'A reversed date range was accepted';

  raise notice 'admin_used_device_oversight: all checks passed';
end;
$test$;
rollback;
