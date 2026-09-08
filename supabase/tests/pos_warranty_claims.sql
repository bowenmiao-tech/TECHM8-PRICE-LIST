begin;
do $test$
declare
  token text := gen_random_uuid()::text;
  actor bigint;
  request uuid := gen_random_uuid();
  result jsonb;
  line public.pos_sales_order_lines%rowtype;
  w jsonb;
  rejected boolean;
begin
  select s.id into actor from public.staff_directory s
    where s.active and public.staff_has_store_access(s.id, (select store_id from public.pos_sales_orders where order_code='RD-TW-INV-3137'))
    limit 1;
  if actor is null then raise exception 'No test staff available'; end if;
  insert into public.staff_sessions(staff_id,session_hash,token_digest,expires_at)
    values(actor,extensions.crypt(token,extensions.gen_salt('bf')),encode(extensions.digest(token,'sha256'),'hex'),now()+interval '5 minutes');
  result := public.claim_pos_warranty_for_store(token,'toowong','RD-TW-INV-3137',4153,request);
  if not (result->>'ok')::boolean then raise exception 'Claim failed'; end if;
  if not exists(select 1 from jsonb_array_elements(result->'order'->'items') i where i->>'line_id'='4153' and jsonb_array_length(i->'warranty'->'claims')=1 and not (i->'warranty'->>'can_claim')::boolean) then raise exception 'Claim missing from response'; end if;
  perform public.claim_pos_warranty_for_store(token,'toowong','RD-TW-INV-3137',4153,request);
  if (select count(*) from public.pos_warranty_claims where sales_order_line_id=4153)<>1 then raise exception 'Retry duplicated claim'; end if;
  rejected:=false;
  begin perform public.claim_pos_warranty_for_store(token,'toowong','RD-TW-INV-3137',4153,gen_random_uuid());
  exception when others then rejected:=true; end;
  if not rejected then raise exception 'One-time limit not enforced'; end if;
  rejected:=false;
  begin perform public.claim_pos_warranty_for_store('invalid','toowong','RD-TW-INV-3137',4154,gen_random_uuid());
  exception when others then rejected:=true; end;
  if not rejected then raise exception 'Invalid session accepted'; end if;
  rejected:=false;
  begin perform public.claim_pos_warranty_for_store(token,'fairfield','RD-TW-INV-3137',4154,gen_random_uuid());
  exception when others then rejected:=true; end;
  if not rejected then raise exception 'Cross-store order accepted'; end if;
  rejected:=false;
  begin perform public.claim_pos_warranty_for_store(token,'toowong','RD-TW-INV-3137',-1,gen_random_uuid());
  exception when others then rejected:=true; end;
  if not rejected then raise exception 'Wrong line accepted'; end if;
  select * into line from public.pos_sales_order_lines where id=4153;
  line.quantity:=2;
  w:=public.pos_line_warranty(line, date '2026-06-30');
  if (w->>'remaining')::int<>1 or not (w->>'can_claim')::boolean then raise exception 'Quantity limit wrong'; end if;
  line.id:=-1;
  w:=public.pos_line_warranty(line, date '2020-01-01');
  if w->>'reason'<>'Warranty expired' then raise exception 'Expiry failed'; end if;
  line.name:='Warranty Replacement';
  w:=public.pos_line_warranty(line,current_date);
  if (w->>'eligible')::boolean then raise exception 'Replacement incorrectly granted new warranty'; end if;
  line.name:='New phone case'; line.legacy_import:=false; line.line_payload:='{}'::jsonb;
  w:=public.pos_line_warranty(line,current_date);
  if not (w->>'can_claim')::boolean or w->>'duration'<>'6 Months' then raise exception 'New sale warranty missing'; end if;
  line.line_payload:='{"warranty_duration":"0 Months"}'::jsonb;
  if (public.pos_line_warranty(line,current_date)->>'eligible')::boolean then raise exception 'Zero warranty eligible'; end if;
  if has_table_privilege('anon','public.pos_warranty_claims','SELECT') or has_function_privilege('anon','public.claim_pos_warranty_for_store(text,text,text,bigint,uuid)','EXECUTE') then raise exception 'Public access leak'; end if;
end;
$test$;
rollback;
select 'PASS: claim persistence, payload refresh, idempotency, quantity cap, expiry, exclusions, future sales, session/store/line authorization, role grants. All test writes rolled back.' as result;
