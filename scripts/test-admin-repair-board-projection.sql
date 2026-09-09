begin;
do $test$
declare
  token text := gen_random_uuid()::text;
  result jsonb;
begin
  insert into public.admin_sessions(admin_user_id,session_hash,expires_at)
  select id,extensions.crypt(token,extensions.gen_salt('bf')),now()+interval '1 minute'
  from public.admin_users order by id limit 1;
  result := public.get_admin_repair_follow_up(token);
  assert (result->>'ok')::boolean, 'Repair board did not succeed';
  assert jsonb_array_length(result->'stores') > 0, 'Stores missing';
  assert jsonb_array_length(result->'tickets') > 0, 'Tickets missing';
  assert not exists (
    select 1 from jsonb_array_elements(result->'tickets') e
    left join public.pos_repair_tickets t on t.ticket_code=e->>'ticket_code'
    where (e->>'board_position')::numeric is distinct from coalesce(t.board_position,0)
  ), 'Board position missing or incorrect';
  raise notice 'Verified % stores and % tickets',jsonb_array_length(result->'stores'),jsonb_array_length(result->'tickets');
end;
$test$;
rollback;
select 'PASS: admin report returns stores, tickets and correct board positions; test session rolled back' as result;
