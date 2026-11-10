begin;
do $$
declare
  token text := extensions.gen_random_uuid()::text;
  staff_id_value bigint; store_code_value text; store_id_value bigint;
  code text; other_code text;
  memo_code text := 'TEST-DEVICE-ID-' || extensions.gen_random_uuid()::text;
  result jsonb; before_count int; denied boolean; message text;
begin
  -- An open repair card, and a staff member whose home store it is.
  select ticket.ticket_code, staff.id, store.store_code, store.id
    into code, staff_id_value, store_code_value, store_id_value
    from public.pos_repair_tickets ticket
    join public.store_locations store on store.id = ticket.store_id and store.active
    join public.staff_directory staff on staff.default_store_id = store.id and staff.active
    where ticket.active and ticket.closed_at is null and ticket.card_kind = 'repair'
    order by ticket.updated_at desc limit 1;
  assert code is not null, 'No open repair card to test against';
  select ticket_code into other_code from public.pos_repair_tickets
    where active and store_id <> store_id_value limit 1;
  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
    values(staff_id_value, extensions.crypt(token, extensions.gen_salt('bf')), encode(extensions.digest(token, 'sha256'), 'hex'), now() + interval '5 minutes');
  update public.pos_repair_tickets set intake = (intake - 'deviceImei' - 'deviceSerial') || jsonb_build_object('deviceIdType','none','deviceIdUnavailable','No power','password','keep-me'), closed_at = now() where ticket_code = code;
  result := public.set_pos_repair_ticket_device_id(token, jsonb_build_object('store_code',store_code_value,'ticket_code',code,'device_imei','123456789012345'));
  assert result#>>'{ticket,intake,deviceImei}' = '123456789012345';
  assert result#>>'{ticket,intake,password}' = 'keep-me';
  assert result#>>'{ticket,intake,deviceIdType}' = 'imei';
  select jsonb_array_length(activity) into before_count from public.pos_repair_tickets where ticket_code = code;
  result := public.set_pos_repair_ticket_device_id(token, jsonb_build_object('store_code',store_code_value,'ticket_code',code,'device_imei','123456789012345'));
  assert (select jsonb_array_length(activity) from public.pos_repair_tickets where ticket_code = code) = before_count;
  result := public.set_pos_repair_ticket_device_id(token, jsonb_build_object('store_code',store_code_value,'ticket_code',code,'device_serial','SN-123'));
  assert result#>>'{ticket,intake,deviceSerial}' = 'SN-123';
  begin
    perform public.set_pos_repair_ticket_device_id(token,jsonb_build_object('store_code',store_code_value,'ticket_code',code,'device_imei','999999999999999'));
    raise exception 'Overwrite accepted';
  exception when others then assert sqlerrm = 'IMEI is already recorded'; end;
  begin
    perform public.set_pos_repair_ticket_device_id(token,jsonb_build_object('store_code',store_code_value,'ticket_code',code,'device_imei','123'));
    raise exception 'Invalid IMEI accepted';
  exception when others then assert sqlerrm = 'IMEI must contain exactly 15 digits'; end;
  denied := false;
  begin perform public.set_pos_repair_ticket_device_id('bad-session',jsonb_build_object('store_code',store_code_value,'ticket_code',code,'device_serial','NEW'));
  exception when others then denied := true; end;
  assert denied, 'Invalid session accepted';
  if other_code is not null then
    begin
      perform public.set_pos_repair_ticket_device_id(token,jsonb_build_object('store_code',store_code_value,'ticket_code',other_code,'device_serial','NEW'));
      raise exception 'Other store accepted';
    exception when others then assert sqlerrm = 'Repair ticket belongs to another store'; end;
  end if;
  assert not has_function_privilege('anon','public.set_pos_repair_ticket_device_id(text,jsonb)','execute');
  assert not has_function_privilege('authenticated','public.set_pos_repair_ticket_device_id(text,jsonb)','execute');
  raise notice 'PASS: completed repair backfill, intake preserved, no-op, serial addition, overwrite and validation guards, session, store, grants';
end;
$$;
rollback;
