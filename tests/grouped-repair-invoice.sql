begin;
do $test$
declare token_value text := extensions.gen_random_uuid()::text; staff_id_value bigint; result jsonb; receipt jsonb;
begin
 select id into staff_id_value from public.staff_directory where active and lower(trim(email))='techm8contact@gmail.com' and credentials_initialized_at is not null limit 1;
 assert staff_id_value is not null, 'An authorized test actor is required';
 insert into public.staff_sessions(session_hash,expires_at,staff_id,token_digest)
 values(extensions.crypt(token_value,extensions.gen_salt('bf')),now()+interval '5 minutes',staff_id_value,encode(extensions.digest(token_value,'sha256'),'hex'));
 result := public.search_pos_sales_orders(token_value,'northlakes','5246',200,0,null,null);
 select jsonb_build_object('orders',jsonb_agg(row)) into result from jsonb_array_elements(result->'orders') row where row->>'invoice_number'='5246';
 assert jsonb_array_length(result->'orders')=1, 'Invoice search must return one row for #5246';
 receipt := result #> '{orders,0,invoice}';
 assert jsonb_array_length(receipt->'checkouts')=2, 'Invoice must retain both checkouts';
 assert (receipt->>'total')::numeric=119 and (receipt->>'amount_paid')::numeric=119, 'Cumulative invoice must total $119';
 assert (receipt#>>'{checkouts,0,total}')::numeric=99 and (receipt#>>'{checkouts,1,total}')::numeric=20, 'Checkout amounts must remain $99 and $20';
 result := public.search_pos_sales_orders(token_value,'northlakes','POS-1794189971903',20,0,'2026-11-09','2026-11-09');
 assert jsonb_array_length(result->'orders')=1 and jsonb_array_length(result#>'{orders,0,invoice,checkouts}')=2, 'Date search must include the full invoice history';
 result := public.search_pos_sales_orders(token_value,'northlakes','POS-1794189971903',1,1,null,null);
 assert jsonb_array_length(result->'orders')=0, 'Pagination must not repeat a checkout as a second invoice';
end $test$;
rollback;
