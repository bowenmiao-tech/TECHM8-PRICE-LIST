-- Admin drill-down must reconcile with the overview for the same date/store/category.
-- The temporary admin session is rolled back.
begin;
do $test$
declare
  token text := extensions.gen_random_uuid()::text;
  admin_id bigint;
  overview jsonb;
  detail jsonb;
  all_detail jsonb;
  overview_store_net numeric;
  overview_all_net numeric;
  store_code_value text;
  category_value text;
  selected_store_row jsonb;
  expected_net numeric;
  rejected boolean := false;
begin
  select id into admin_id from public.admin_users where active order by id limit 1;
  assert admin_id is not null, 'An active admin account is required for the drill-down test';

  insert into public.admin_sessions(admin_user_id, session_hash, expires_at)
  values (admin_id, extensions.crypt(token, extensions.gen_salt('bf')), now() + interval '5 minutes');

  overview := public.get_admin_sales_overview(token, current_date, current_date);
  detail := public.get_admin_sales_drilldown(
    token, current_date, current_date, 'toowong', 'product', '', 50, 0
  );
  all_detail := public.get_admin_sales_drilldown(
    token, current_date, current_date, null, 'product', '', 50, 0
  );

  select coalesce((store_row->>'products')::numeric, 0)
  into overview_store_net
  from jsonb_array_elements(overview->'stores') store_row
  where store_row->>'store_code' = 'toowong';
  overview_all_net := coalesce((overview#>>'{totals,products}')::numeric, 0);

  assert overview_store_net = coalesce((detail#>>'{summary,net}')::numeric, 0),
    format('Toowong product drill-down %s did not equal overview %s', detail#>>'{summary,net}', overview_store_net);
  assert overview_all_net = coalesce((all_detail#>>'{summary,net}')::numeric, 0),
    format('All-store product drill-down %s did not equal overview %s', all_detail#>>'{summary,net}', overview_all_net);
  assert detail->>'store_name' = 'Toowong Village Shopping Centre', 'The selected store name was not returned';
  assert all_detail->>'store_name' = 'All Stores', 'The all-store heading was not returned';
  assert jsonb_array_length(detail->'rows') <= 50, 'Page limit was ignored';

  foreach store_code_value in array array['parkridge','fairfield','northlakes','toowong']::text[] loop
    select row_value into selected_store_row
    from jsonb_array_elements(overview->'stores') row_value
    where row_value->>'store_code' = store_code_value;
    foreach category_value in array array['repair','mis','product','other','all']::text[] loop
      expected_net := coalesce((selected_store_row->>case category_value
        when 'repair' then 'repairs' when 'mis' then 'mis' when 'product' then 'products'
        when 'other' then 'other' else 'net_sales' end)::numeric, 0);
      detail := public.get_admin_sales_drilldown(
        token, current_date, current_date, store_code_value, category_value, '', 1, 0
      );
      assert expected_net = coalesce((detail#>>'{summary,net}')::numeric, 0),
        format('%s %s drill-down %s did not equal overview %s', store_code_value, category_value,
          detail#>>'{summary,net}', expected_net);
      assert jsonb_array_length(detail->'rows') <= 1, 'One-row pagination limit was ignored';
    end loop;
  end loop;

  begin
    perform public.get_admin_sales_drilldown('invalid-token', current_date, current_date, null, 'all', '', 50, 0);
  exception when others then rejected := true;
  end;
  assert rejected, 'An invalid admin session read sales drill-down data';
end;
$test$;
rollback;
