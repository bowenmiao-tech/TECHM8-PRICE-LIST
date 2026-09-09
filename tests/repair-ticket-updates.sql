begin;
do $$
declare
  token text := extensions.gen_random_uuid()::text;
  admin_token text := extensions.gen_random_uuid()::text;
  staff_id_value bigint;
  staff_name_value text;
  store_id_value bigint;
  store_code_value text;
  ticket_code_value text := 'TEST-REPAIR-UPDATES-' || extensions.gen_random_uuid()::text;
  ticket_id_value bigint;
  update_id uuid := extensions.gen_random_uuid();
  result jsonb;
  denied boolean;
  photo_id uuid := extensions.gen_random_uuid();
  photo_path text;
begin
  select staff.id, staff.display_name, store.id, store.store_code
    into staff_id_value, staff_name_value, store_id_value, store_code_value
    from public.staff_directory staff join public.store_locations store on store.id = staff.default_store_id
    where staff.active and store.active and store.store_code <> 'warehouse' limit 1;
  insert into public.staff_sessions(staff_id,session_hash,token_digest,expires_at)
    values(staff_id_value,extensions.crypt(token,extensions.gen_salt('bf')),encode(extensions.digest(token,'sha256'),'hex'),now()+interval '5 minutes');
  insert into public.admin_sessions(admin_user_id,session_hash,expires_at)
    select id,extensions.crypt(admin_token,extensions.gen_salt('bf')),now()+interval '5 minutes' from public.admin_users where active limit 1;
  insert into public.pos_repair_tickets(ticket_code,store_id,title,issue,customer_name,customer_phone,price,intake)
    values(ticket_code_value,store_id_value,'Rollback-only test','Test','Test Customer','0400000000','1',
      '{"quote":{"brand":"Test","model":"Test","issue":"Test"},"deviceIdType":"none","deviceIdUnavailable":"Test","passwordType":"none","passwordNoneReason":"Test","testable":"no","cannotTestReason":"Test"}') returning id into ticket_id_value;
  result := public.add_repair_ticket_update(token,store_code_value,ticket_code_value,jsonb_build_object('id',update_id,'kind','comment','body','Staff test','author','Spoofed author'));
  if not (result->>'ok')::boolean then raise exception 'Staff comment failed'; end if;
  if (select author from public.pos_repair_ticket_updates where id=update_id) <> staff_name_value then raise exception 'Author spoofing'; end if;
  perform public.add_repair_ticket_update(token,store_code_value,ticket_code_value,jsonb_build_object('id',update_id,'kind','comment','body','Staff test'));
  if (select count(*) from public.pos_repair_ticket_updates where repair_ticket_id=ticket_id_value) <> 1 then raise exception 'Retry duplicated comment'; end if;
  perform public.add_repair_ticket_update(admin_token,store_code_value,ticket_code_value,jsonb_build_object('id',extensions.gen_random_uuid(),'kind','comment','body','Admin test'));
  result := public.get_repair_ticket_updates(token,store_code_value,ticket_code_value);
  if jsonb_array_length(result->'updates') <> 2 then raise exception 'Shared comments missing'; end if;
  denied := false;
  begin perform public.get_repair_ticket_updates('invalid',store_code_value,ticket_code_value); exception when others then denied := true; end;
  if not denied then raise exception 'Invalid session accepted'; end if;
  denied := false;
  begin perform public.get_repair_ticket_updates(token,'wrong-store',ticket_code_value); exception when others then denied := true; end;
  if not denied then raise exception 'Wrong store accepted'; end if;
  photo_path := store_id_value || '/' || ticket_id_value || '/' || photo_id || '.jpg';
  denied := false;
  begin perform public.add_repair_ticket_update(token,store_code_value,ticket_code_value,jsonb_build_object('id',photo_id,'kind','photo','storage_path',photo_path)); exception when others then denied := true; end;
  if not denied then raise exception 'Missing upload accepted'; end if;
  insert into storage.objects(bucket_id,name) values('repair-ticket-photos',photo_path);
  perform public.add_repair_ticket_update(token,store_code_value,ticket_code_value,jsonb_build_object('id',photo_id,'kind','photo','storage_path',photo_path,'file_name','Test screenshot.jpg'));
  if (select storage_path from public.pos_repair_ticket_updates where id=photo_id) <> photo_path then raise exception 'Photo not linked'; end if;
  update public.pos_repair_tickets set closed_at=now() where id=ticket_id_value;
  perform public.add_repair_ticket_update(token,store_code_value,ticket_code_value,jsonb_build_object('id',extensions.gen_random_uuid(),'kind','comment','body','Post-repair comment'));
  update public.pos_repair_tickets set active=false where id=ticket_id_value;
  denied := false;
  begin perform public.add_repair_ticket_update(token,store_code_value,ticket_code_value,jsonb_build_object('id',extensions.gen_random_uuid(),'kind','comment','body','Deleted ticket')); exception when others then denied := true; end;
  if not denied then raise exception 'Deleted ticket writable'; end if;
  if has_function_privilege('anon','public.get_repair_ticket_updates(text,text,text)','execute') then raise exception 'Anonymous RPC access'; end if;
end;
$$;
rollback;
