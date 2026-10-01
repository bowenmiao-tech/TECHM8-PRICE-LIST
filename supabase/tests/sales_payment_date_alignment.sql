-- All fixtures and temporary sessions are rolled back by the P7777 subtransaction.
-- Safe to run as a deployment gate: a real assertion failure aborts deployment.
do $test$
declare
  admin_token text := gen_random_uuid()::text;
  staff_token text;
  staff_row public.staff_directory%rowtype;
  store_row public.store_locations%rowtype;
  admin_id bigint;
  order_id bigint; credit_order_id bigint; line_id bigint; refund_id bigint; customer_id bigint;
  code text := 'REPORT-TEST-'||gen_random_uuid();
  customer_code text := 'REPORT-CUSTOMER-'||gen_random_uuid();
  from_day date; to_day date;
  overview jsonb; pos_report jsonb; admin_store jsonb; detail jsonb; previous jsonb;
  item jsonb; category text; expected numeric; denied boolean;
begin
  begin
    select id into admin_id from public.admin_users where active order by id limit 1;
    assert admin_id is not null, 'Missing admin test account';
    insert into public.admin_sessions(admin_user_id,session_hash,expires_at)
      values(admin_id,extensions.crypt(admin_token,extensions.gen_salt('bf')),now()+interval '10 minutes');
    select * into store_row from public.store_locations where store_code='toowong' and active;
    select * into staff_row from public.staff_directory s where s.active
      and public.staff_has_store_access(s.id,store_row.id) order by s.id limit 1;
    assert staff_row.id is not null, 'Missing staff test account';
    staff_token := gen_random_uuid()::text;
    insert into public.staff_sessions(staff_id,session_hash,token_digest,expires_at)
      values(staff_row.id,extensions.crypt(staff_token,extensions.gen_salt('bf')),
        encode(extensions.digest(staff_token,'sha256'),'hex'),now()+interval '10 minutes');

    insert into public.pos_sales_orders(order_code,store_id,business_date,staff_name,payment_method,total,
      amount_paid,payment_status,order_payload,invoice_number)
      values(code,store_row.id,'2099-01-01',staff_row.display_name,'Cash',200,60.01,'deposit','{}',
        800000000000+floor(random()*1000000000)::bigint) returning id into order_id;
    insert into public.pos_sales_order_lines(sales_order_id,line_number,line_type,name,quantity,unit_price,line_total,line_payload)
      values(order_id,1,'repair','Report test repair',1,100,100,'{}'),
        (order_id,2,'retail','Report test product',1,60,60,'{}'),
        (order_id,3,'special','Report test special',1,40,40,'{}');
    select id into line_id from public.pos_sales_order_lines where sales_order_id=order_id and line_number=1;
    insert into public.pos_sales_order_payments(sales_order_id,payment_number,method,amount,business_date,taken_at,staff_name)
      values(order_id,1,'Cash',60.01,'2099-01-01','2099-01-01 10:00+10',staff_row.display_name);
    -- Exercise the balance-payment writer on an old invoice, not just a reporting fixture.
    perform public.add_pos_sales_order_payment(staff_token,jsonb_build_object('order_id',code,
      'store_code','toowong','staff_name',staff_row.display_name,'business_date','2099-01-02',
      'taken_at','2099-01-02 10:00+10','payments',jsonb_build_array(jsonb_build_object('method','Card','amount',139.99))));
    assert (select business_date from public.pos_sales_orders where id=order_id)='2099-01-01', 'Invoice date changed';
    insert into public.pos_sales_refunds(refund_code,sales_order_id,store_id,staff_name,method,reason,amount,business_date,created_at)
      values(code||'-REF',order_id,store_row.id,staff_row.display_name,'Card','Regression',20,'2099-01-02','2099-01-02 11:00+10') returning id into refund_id;
    insert into public.pos_sales_refund_lines(refund_id,sales_order_line_id,amount,returned_quantity)
      values(refund_id,line_id,20,0);

    -- Credit redemption and credit issuance must not become new cash in any chart/category.
    insert into public.pos_customers(customer_code,first_name,created_by,updated_by)
      values(customer_code,'Reporting fixture',staff_row.display_name,staff_row.display_name) returning id into customer_id;
    insert into public.pos_store_credit_accounts(customer_id,balance) values(customer_id,30);
    insert into public.pos_sales_orders(order_code,store_id,business_date,staff_name,payment_method,total,
      amount_paid,payment_status,order_payload,invoice_number)
      values(code||'-CREDIT',store_row.id,'2099-01-02',staff_row.display_name,'Store Credit',30,30,'paid',
        jsonb_build_object('customer_code',customer_code),800000000000+floor(random()*1000000000)::bigint) returning id into credit_order_id;
    insert into public.pos_sales_order_lines(sales_order_id,line_number,line_type,name,quantity,unit_price,line_total,line_payload)
      values(credit_order_id,1,'retail','Report credit product',1,30,30,'{}') returning id into line_id;
    insert into public.pos_sales_order_payments(sales_order_id,payment_number,method,amount,business_date,taken_at,staff_name)
      values(credit_order_id,1,'Store Credit',30,'2099-01-02','2099-01-02 12:00+10',staff_row.display_name);
    insert into public.pos_sales_refunds(refund_code,sales_order_id,store_id,staff_name,method,reason,amount,business_date,created_at,refund_payload)
      values(code||'-CREDIT-REF',credit_order_id,store_row.id,staff_row.display_name,'Store Credit','Regression',5,'2099-01-02','2099-01-02 13:00+10',jsonb_build_object('customer_code',customer_code)) returning id into refund_id;
    insert into public.pos_sales_refund_lines(refund_id,sales_order_line_id,amount,returned_quantity)
      values(refund_id,line_id,5,0);

    pos_report:=public.get_pos_performance_report(staff_token,'toowong','2099-01-02','2099-01-02',1);
    assert (pos_report#>>'{totals,received}')::numeric=139.99, 'Old balance missing or credit counted as cash';
    assert (pos_report#>>'{totals,net}')::numeric=119.99, 'Cash refund/credit exclusion wrong';
    assert (pos_report#>>'{totals,store_credit_redeemed}')::numeric=30, 'Credit tender disclosure missing';
    assert (pos_report#>>'{totals,store_credit_issued}')::numeric=5, 'Credit refund disclosure missing';
    assert (select sum((v->>'net')::numeric) from jsonb_array_elements(pos_report->'hourly_trend') v)=119.99, 'Hourly trend differs';
    assert (select (v->>'net')::numeric from jsonb_array_elements(pos_report->'daily_trend') v where v->>'date'='2099-01-02')=119.99, 'Daily trend differs';
    previous:=public.get_pos_performance_report(staff_token,'toowong','2099-01-01','2099-01-01',1);
    assert (previous#>>'{totals,received}')::numeric=60.01, 'Balance was backdated to original invoice';

    -- Check every store, category and unpaginated total against detail and POS,
    -- on fixtures AND real recent records. Temporary test sessions never persist.
    for from_day,to_day in select * from (values
      ('2099-01-02'::date,'2099-01-02'::date),
      ('2099-01-01'::date,'2099-01-02'::date),
      (((now() at time zone 'Australia/Brisbane')::date-30),(now() at time zone 'Australia/Brisbane')::date)
    ) ranges loop
      overview:=public.get_admin_sales_overview(admin_token,from_day,to_day);
      for store_row in select * from public.store_locations where active
        and store_code=any(array['parkridge','fairfield','northlakes','toowong']) loop
        select * into staff_row from public.staff_directory s where s.active
          and public.staff_has_store_access(s.id,store_row.id) order by s.id limit 1;
        assert staff_row.id is not null, 'No staff for reporting store';
        staff_token:=gen_random_uuid()::text;
        insert into public.staff_sessions(staff_id,session_hash,token_digest,expires_at)
          values(staff_row.id,extensions.crypt(staff_token,extensions.gen_salt('bf')),
            encode(extensions.digest(staff_token,'sha256'),'hex'),now()+interval '10 minutes');
        pos_report:=public.get_pos_performance_report(staff_token,store_row.store_code,from_day,to_day,1);
        select v into admin_store from jsonb_array_elements(overview->'stores') v where v->>'store_code'=store_row.store_code;
        assert (admin_store->>'net_sales')::numeric=(pos_report#>>'{totals,net}')::numeric, 'POS/admin net differs';
        assert (admin_store->>'payments_received')::numeric=(pos_report#>>'{totals,received}')::numeric, 'POS/admin received differs';
        assert (admin_store->>'refunds')::numeric=(pos_report#>>'{totals,refunded}')::numeric, 'POS/admin refunds differ';
        assert (admin_store->>'invoice_count')::int=(pos_report#>>'{totals,order_count}')::int, 'POS/admin invoice counts differ';
        assert coalesce((select sum((v->>'net')::numeric) from jsonb_array_elements(pos_report->'categories') v),0)
          =(pos_report#>>'{totals,net}')::numeric, 'Category rounding does not sum to takings';
        foreach category in array array['repair','mis','product','other','all'] loop
          expected:=(admin_store->>case category when 'repair' then 'repairs' when 'product' then 'products'
            when 'mis' then 'mis' when 'other' then 'other' else 'net_sales' end)::numeric;
          detail:=public.get_admin_sales_drilldown(admin_token,from_day,to_day,store_row.store_code,category,'',1,0);
          assert expected=(detail#>>'{summary,net}')::numeric, 'Drilldown differs from overview';
          if category<>'all' then
            select coalesce(sum((v->>'net')::numeric),0) into expected from jsonb_array_elements(pos_report->'categories') v
              where v->>'type'=case category when 'mis' then 'used_device' when 'product' then 'retail' else category end;
            assert expected=(detail#>>'{summary,net}')::numeric, 'POS category differs from admin';
          end if;
        end loop;
      end loop;
    end loop;
    denied:=false;
    begin perform public.get_admin_sales_overview('invalid-token',from_day,to_day);
      exception when raise_exception then denied:=true; end;
    assert denied, 'Invalid admin session accepted';
    assert not has_function_privilege('anon','public.pos_takings_line_movements(bigint[],date,date)','EXECUTE'), 'Ledger exposed to anon';
    assert not has_function_privilege('authenticated','public.pos_takings_line_movements(bigint[],date,date)','EXECUTE'), 'Ledger exposed to authenticated';
    raise exception using errcode='P7777',message='PASS; roll back reporting fixtures';
  exception when sqlstate 'P7777' then null;
  end;
end;
$test$;
select 'PASS: old balance collected today, deposit date, refunds, credit exclusion, charts, category cents, four-store reconciliation, pagination and auth; all fixtures rolled back' as result;
