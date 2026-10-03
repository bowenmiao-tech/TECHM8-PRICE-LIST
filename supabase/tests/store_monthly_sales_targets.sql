-- Store monthly sales targets: admin set/clear, POS Today card month figures.
-- Month takings must equal the admin overview for the same store and dates;
-- staff month points must equal the admin staff points report. Every
-- session and target written here is rolled back.
begin;
do $test$
declare
  admin_token text := extensions.gen_random_uuid()::text;
  staff_token text := extensions.gen_random_uuid()::text;
  admin_id bigint;
  store_row public.store_locations%rowtype;
  staff_row public.staff_directory%rowtype;
  today_value date := (now() at time zone 'Australia/Brisbane')::date;
  month_value date := date_trunc('month', (now() at time zone 'Australia/Brisbane')::date)::date;
  targets jsonb;
  overview jsonb;
  progress jsonb;
  points_report jsonb;
  target_store jsonb;
  overview_store jsonb;
  report_staff jsonb;
  rejected boolean;
begin
  select id into admin_id from public.admin_users where active order by id limit 1;
  assert admin_id is not null, 'An active admin account is required';
  insert into public.admin_sessions(admin_user_id, session_hash, expires_at)
  values (admin_id, extensions.crypt(admin_token, extensions.gen_salt('bf')), now() + interval '10 minutes');

  select * into store_row from public.store_locations where store_code = 'toowong' and active;
  select * into staff_row from public.staff_directory staff
  where staff.active and public.staff_has_store_access(staff.id, store_row.id)
  order by staff.id limit 1;
  assert staff_row.id is not null, 'A Toowong staff account is required';
  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
  values (staff_row.id, extensions.crypt(staff_token, extensions.gen_salt('bf')),
    encode(extensions.digest(staff_token, 'sha256'), 'hex'), now() + interval '10 minutes');

  -- Month takings match the admin overview's This Month.
  targets := public.get_admin_store_sales_targets(admin_token, today_value);
  overview := public.get_admin_sales_overview(admin_token, month_value, today_value);
  assert targets->>'month' = to_char(month_value, 'YYYY-MM'), 'Wrong target month';
  assert not exists (select 1 from jsonb_array_elements(targets->'stores') s where s->>'store_code' = 'warehouse'),
    'Warehouse must not take a sales target';
  select s into target_store from jsonb_array_elements(targets->'stores') s where s->>'store_code' = 'toowong';
  select s into overview_store from jsonb_array_elements(overview->'stores') s where s->>'store_code' = 'toowong';
  assert (target_store->>'net_sales')::numeric = (overview_store->>'net_sales')::numeric,
    format('Target month sales %s did not equal overview %s', target_store->>'net_sales', overview_store->>'net_sales');

  -- Set, then read it back on the POS card.
  targets := public.set_admin_store_sales_target(admin_token, 'toowong', today_value, 45000.555);
  select s into target_store from jsonb_array_elements(targets->'stores') s where s->>'store_code' = 'toowong';
  assert (target_store->>'sales_target')::numeric = 45000.56, 'Target was not saved to the cent';
  assert coalesce(target_store->>'updated_by', '') <> '', 'Target author was not recorded';
  targets := public.set_admin_store_sales_target(admin_token, 'toowong', month_value + 5, 50000);
  assert (select count(*) from public.pos_store_sales_targets t
    where t.store_id = store_row.id and t.target_month = month_value) = 1, 'A second save must update, not duplicate';

  progress := public.get_pos_today_progress(staff_token, 'toowong', staff_row.display_name, today_value);
  assert (progress#>>'{store_month_sales,target}')::numeric = 50000, 'POS did not receive the monthly target';
  assert (progress#>>'{store_month_sales,net_sales}')::numeric = (overview_store->>'net_sales')::numeric,
    'POS month takings did not equal the admin overview';
  assert (progress#>>'{store_month_sales,remaining}')::numeric
    = greatest(0, 50000 - (overview_store->>'net_sales')::numeric), 'Remaining amount is wrong';
  assert progress ? 'monthly_hourly_sales', 'Hourly sales were dropped from the payload';

  -- Staff month points equal the admin staff points report.
  points_report := public.get_staff_points_report(admin_token, 10);
  select s into report_staff from jsonb_array_elements(points_report->'staff') s
  where s->>'normalized_staff_name' = lower(trim(staff_row.display_name));
  assert (progress#>>'{staff_month_points,total_points}')::integer = coalesce((report_staff->>'total_points')::integer, 0),
    format('POS month points %s did not equal the admin report %s', progress#>>'{staff_month_points,total_points}', report_staff->>'total_points');
  assert (progress#>>'{staff_month_points,total_points}')::integer
    = (progress#>>'{staff_month_points,google_review_points}')::integer + (progress#>>'{staff_month_points,bundle_points}')::integer,
    'Month total is not reviews plus bundles';
  assert not exists (
    select 1 from jsonb_array_elements(points_report->'staff') s
    where (public.pos_staff_month_points(s->>'staff_name', today_value)->>'total_points')::integer
      <> coalesce((s->>'total_points')::integer, 0)
  ), 'A staff member''s POS month points differ from the admin report';

  -- Zero clears it.
  perform public.set_admin_store_sales_target(admin_token, 'toowong', today_value, 0);
  progress := public.get_pos_today_progress(staff_token, 'toowong', staff_row.display_name, today_value);
  assert progress#>'{store_month_sales,target}' = 'null'::jsonb, 'Cleared target is still shown';

  -- Rejections.
  rejected := false;
  begin perform public.set_admin_store_sales_target('not-a-session', 'toowong', today_value, 1000);
  exception when others then rejected := true; end;
  assert rejected, 'An invalid admin session set a target';
  rejected := false;
  begin perform public.get_admin_store_sales_targets(staff_token, today_value);
  exception when others then rejected := true; end;
  assert rejected, 'A staff session read admin targets';
  rejected := false;
  begin perform public.set_admin_store_sales_target(admin_token, 'toowong', today_value, -1);
  exception when others then rejected := true; end;
  assert rejected, 'A negative target was accepted';
  rejected := false;
  begin perform public.set_admin_store_sales_target(admin_token, 'warehouse', today_value, 1000);
  exception when others then rejected := true; end;
  assert rejected, 'Warehouse accepted a target';

  raise notice 'PASS: store monthly targets, POS month takings and staff month points.';
end;
$test$;
rollback;
