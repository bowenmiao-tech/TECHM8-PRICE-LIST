begin;
do $$
declare
 token text := extensions.gen_random_uuid()::text;
 staff_id_value bigint; staff_name_value text; store_id_value bigint; store_code_value text;
 code text := 'TEST-MEMO-' || extensions.gen_random_uuid()::text;
 result jsonb; request jsonb; denied boolean; job_result jsonb;
begin
  select staff.id, staff.display_name, store.id, store.store_code
    into staff_id_value, staff_name_value, store_id_value, store_code_value
    from public.staff_directory staff join public.store_locations store on store.id = staff.default_store_id
    where staff.active and store.active and store.store_code <> 'warehouse' limit 1;
  insert into public.staff_sessions(staff_id,session_hash,token_digest,expires_at)
    values(staff_id_value,extensions.crypt(token,extensions.gen_salt('bf')),encode(extensions.digest(token,'sha256'),'hex'),now()+interval '5 minutes');

 request := jsonb_build_object('action','create-memo','store_code',store_code_value,'ticket_code',code,'status','need_to_order');
 result := public.manage_pos_repair_memo(token,request);
 assert result#>>'{ticket,cardKind}'='memo';
 assert result#>>'{ticket,customerName}'='';
 assert (result#>>'{ticket,canClose}')::boolean;
 assert result#>>'{ticket,price}'='$0.00';
 perform public.manage_pos_repair_memo(token,request);
 assert (select count(*) from public.pos_repair_tickets where ticket_code=code)=1;
 denied := false;
 begin perform public.manage_pos_repair_memo('bad-session',request); exception when others then denied:=true; end;
 assert denied, 'Invalid session accepted';
 result:=public.manage_pos_repair_memo(token,request||jsonb_build_object('action','save-memo','notes','Order PS5 power supply','customer_phone','email preferred'));
 assert result#>>'{ticket,intake,memoNotes}'='Order PS5 power supply';
 result:=public.manage_pos_repair_memo(token,request||jsonb_build_object('action','move-memo','status','repairing'));
 assert result#>>'{ticket,status}'='repairing';
 perform public.add_repair_ticket_update(token,store_code_value,code,jsonb_build_object('id',extensions.gen_random_uuid(),'kind','comment','body','Follow up tomorrow'));
 assert jsonb_array_length(public.get_repair_ticket_updates(token,store_code_value,code)->'updates')=1;
 job_result:=public.add_pos_repair_ticket_job(token,jsonb_build_object('store_code',store_code_value,'ticket_code',code,'name','Warranty assessment','price','10','status','proposed'));
 denied:=false;
 begin perform public.manage_pos_repair_memo(token,request||jsonb_build_object('action','finish-memo')); exception when others then denied:=true; end;
 assert denied, 'Unbilled work must block finishing';
 perform public.delete_pos_repair_ticket_job(token,jsonb_build_object('store_code',store_code_value,'job_code',job_result#>>'{ticket,jobs,0,id}'));
 result:=public.manage_pos_repair_memo(token,request||jsonb_build_object('action','finish-memo'));
 assert result#>>'{ticket,closedAt}' is not null;
 denied:=false;
 begin perform public.manage_pos_repair_memo(token,request||jsonb_build_object('action','move-memo','status','waiting_shipping')); exception when others then denied:=true; end;
 assert denied, 'Finished cards cannot move';
 denied:=false;
 begin
 insert into public.pos_repair_tickets(ticket_code,store_id,title,issue,price,status) values(code||'-REPAIR',store_id_value,'Repair','Test','$0.00','repairing');
 exception when others then denied:=true; end;
 assert denied, 'Normal repair validation was bypassed';
 assert not has_function_privilege('anon','public.manage_pos_repair_memo(text,jsonb)','execute');
end;
$$;
rollback;
