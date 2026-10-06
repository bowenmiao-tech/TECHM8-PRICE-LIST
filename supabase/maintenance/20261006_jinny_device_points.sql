-- Explicit owner request: add 10 device points to Jinny for October 2026.
-- Run as database operator after add_manual_device_point_adjustments.
-- Idempotent; assertions roll back the credit if any unrelated score changes.
do $credit$
declare
  target_staff public.staff_directory%rowtype;
  target_store bigint;
  admin_id bigint;
  temp_session_id bigint;
  token text := gen_random_uuid()::text;
  before_report jsonb; after_report jsonb;
  before_month jsonb; after_month jsonb;
  previous_row jsonb; updated_row jsonb;
  before_other_stores jsonb; after_other_stores jsonb;
  before_other_date jsonb;
  inserted_count integer;
  request_id constant text := 'owner-request-jinny-device-20261006-plus10';
begin
  select * into strict target_staff from public.staff_directory
    where lower(trim(display_name)) = 'jinny' and active;
  select id into strict target_store from public.store_locations where store_code = 'fairfield';
  if target_staff.default_store_id <> target_store then
    raise exception 'Jinny store assignment changed; review before crediting';
  end if;
  if exists(select 1 from public.pos_device_point_adjustments where request_key = request_id) then
    if not exists(select 1 from public.pos_device_point_adjustments where request_key = request_id
      and staff_id = target_staff.id and store_id = target_store
      and business_date = '2026-10-06' and points = 10) then
      raise exception 'Adjustment key exists with different details';
    end if;
    return;
  end if;

  select id into strict admin_id from public.admin_users where active order by id limit 1;
  insert into public.admin_sessions(admin_user_id, session_hash, expires_at)
    values(admin_id, extensions.crypt(token, extensions.gen_salt('bf')), now() + interval '5 minutes')
    returning id into temp_session_id;
  before_report := public.get_staff_points_report(token, 500);
  before_month := public.pos_staff_month_points(target_staff.display_name, '2026-10-06');
  before_other_date := public.pos_staff_month_points(target_staff.display_name, '2026-10-05');
  select jsonb_agg(to_jsonb(m) order by s.id) into before_other_stores
    from public.store_locations s cross join lateral
      public.pos_bundle_score_metrics(s.id, '2026-10-01', '2026-10-31', target_staff.display_name) m
    where s.id <> target_store;

  insert into public.pos_device_point_adjustments
    (request_key, staff_id, store_id, business_date, points, reason, requested_by)
    values(request_id, target_staff.id, target_store, '2026-10-06', 10,
      'Owner-requested device points credit', 'Owner request in Codex, 2026-10-06')
    on conflict (request_key) do nothing;
  get diagnostics inserted_count = row_count;
  if inserted_count <> 1 then raise exception 'Concurrent credit detected; retry verification'; end if;

  after_report := public.get_staff_points_report(token, 500);
  after_month := public.pos_staff_month_points(target_staff.display_name, '2026-10-06');
  if (after_month->>'bundle_points')::integer <> (before_month->>'bundle_points')::integer + 10
     or (after_month->>'total_points')::integer <> (before_month->>'total_points')::integer + 10
     or after_month - 'bundle_points' - 'total_points' <> before_month - 'bundle_points' - 'total_points' then
    raise exception 'POS monthly points or counts mismatch';
  end if;
  for previous_row in select value from jsonb_array_elements(before_report->'staff') loop
    select value into strict updated_row from jsonb_array_elements(after_report->'staff')
      where value->>'normalized_staff_name' = previous_row->>'normalized_staff_name';
    if previous_row->>'normalized_staff_name' = 'jinny' then
      if (updated_row->>'device_points')::integer <> (previous_row->>'device_points')::integer + 10
         or (updated_row->>'total_points')::integer <> (previous_row->>'total_points')::integer + 10
         or updated_row - 'device_points' - 'total_points' <> previous_row - 'device_points' - 'total_points' then
        raise exception 'Admin Jinny points mismatch';
      end if;
    elsif updated_row <> previous_row then
      raise exception 'Another staff score changed';
    end if;
  end loop;
  if (after_report->'totals'->>'device_points')::integer <> (before_report->'totals'->>'device_points')::integer + 10
     or (after_report->'totals'->>'combined_points')::integer <> (before_report->'totals'->>'combined_points')::integer + 10 then
    raise exception 'Overall points mismatch';
  end if;
  select jsonb_agg(to_jsonb(m) order by s.id) into after_other_stores
    from public.store_locations s cross join lateral
      public.pos_bundle_score_metrics(s.id, '2026-10-01', '2026-10-31', target_staff.display_name) m
    where s.id <> target_store;
  if before_other_stores <> after_other_stores
     or before_other_date <> public.pos_staff_month_points(target_staff.display_name, '2026-10-05') then
    raise exception 'Other store or date points changed';
  end if;
  delete from public.admin_sessions where id = temp_session_id;
end;
$credit$;
