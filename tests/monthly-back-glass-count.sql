begin;
do $test$
declare
 store_id_value bigint;
 staff_id_value bigint;
 token_value text := extensions.gen_random_uuid()::text;
 screen_id bigint;
 glass_id bigint;
 form jsonb;
 result jsonb;
 today_value date := (now() at time zone 'Australia/Brisbane')::date;
begin
 insert into public.store_locations(store_code,store_name) values ('monthly-glass-regression','Monthly glass regression') returning id into store_id_value;
 select id into staff_id_value from public.staff_directory where active and credentials_initialized_at is not null limit 1;
 insert into public.staff_sessions(session_hash,expires_at,staff_id,token_digest)
 values(extensions.crypt(token_value,extensions.gen_salt('bf')),now()+interval '5 minutes',staff_id_value,encode(extensions.digest(token_value,'sha256'),'hex'));
 insert into public.lcd_inventory_items(store_id,model_name,variant_name,category_key,current_qty)
 values(store_id_value,'Regression Phone','Screen','iphone',2) returning id into screen_id;
 insert into public.lcd_inventory_items(store_id,model_name,variant_name,category_key,current_qty)
 values(store_id_value,'Regression Phone','Back Glass Black','iphone',1) returning id into glass_id;
 form := public.get_lcd_inventory_count_form(token_value,'monthly-glass-regression');
 assert jsonb_array_length(form->'items')=2, 'Glass must appear before monthly completion';
 result := public.submit_lcd_inventory_count(token_value,jsonb_build_object('store_code','monthly-glass-regression','staff_name',(select display_name from public.staff_directory where id=staff_id_value),'confirmed',true,'lines',jsonb_build_array(jsonb_build_object('inventory_item_id',screen_id,'counted_qty',2),jsonb_build_object('inventory_item_id',glass_id,'counted_qty',1))));
 assert (result->>'ok')::boolean, 'Submit failed';
 form := public.get_lcd_inventory_count_form(token_value,'monthly-glass-regression');
 assert jsonb_array_length(form->'items')=1, 'Glass must hide immediately after submitting';
 update public.lcd_inventory_count_submissions set week_start=today_value-14 where id=(result->>'submission_id')::bigint;
 form := public.get_lcd_inventory_count_form(token_value,'monthly-glass-regression');
 assert jsonb_array_length(form->'items')=1, 'Glass must remain hidden next week';
 assert form->'current_week_submission'='null'::jsonb, 'Weekly screen count must remain available';
 result := public.submit_lcd_inventory_count(token_value,jsonb_build_object('store_code','monthly-glass-regression','staff_name',(select display_name from public.staff_directory where id=staff_id_value),'confirmed',true,'lines',jsonb_build_array(jsonb_build_object('inventory_item_id',screen_id,'counted_qty',2))));
 assert (result->>'ok')::boolean, 'Weekly screen count must accept omitted glass';
 update public.lcd_inventory_count_submissions set count_date=(date_trunc('month',today_value)-interval '1 day')::date,week_start=(form->>'week_start')::date where store_id=store_id_value;
 form := public.get_lcd_inventory_count_form(token_value,'monthly-glass-regression');
 assert jsonb_array_length(form->'items')=2, 'Glass must reappear next month';
 assert form->'current_week_submission'='null'::jsonb, 'Previous month must not block the first across-month week';
 update public.lcd_inventory_count_submissions set count_date=today_value,status='rejected' where store_id=store_id_value;
 form := public.get_lcd_inventory_count_form(token_value,'monthly-glass-regression');
 assert jsonb_array_length(form->'items')=2, 'Rejected count must allow retry';
end $test$;
rollback;
