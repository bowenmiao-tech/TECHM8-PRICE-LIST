begin;
do $$
declare
  token text := extensions.gen_random_uuid()::text;
  staff_id_value bigint; store_code_value text; store_id_value bigint;
  code text; other_code text;
  memo_code text := 'TEST-MAINBOARD-' || extensions.gen_random_uuid()::text;
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
  update public.pos_repair_tickets set motherboard_repair = false where ticket_code = code;

  -- Turn it on: one activity line, and it says what happened.
  select jsonb_array_length(activity) into before_count from public.pos_repair_tickets where ticket_code = code;
  result := public.set_pos_repair_ticket_mainboard(token, jsonb_build_object('store_code', store_code_value, 'ticket_code', code, 'motherboard_repair', true));
  assert (result#>>'{ticket,motherboardRepair}')::boolean, 'Flag not set';
  assert (select motherboard_repair from public.pos_repair_tickets where ticket_code = code), 'Flag not stored';
  assert (select jsonb_array_length(activity) from public.pos_repair_tickets where ticket_code = code) = before_count + 1,
    'Expected exactly one new activity line';
  assert (select activity->0->>'text' from public.pos_repair_tickets where ticket_code = code) = 'marked this card as a mainboard repair';
  assert (select activity->0->>'type' from public.pos_repair_tickets where ticket_code = code) = 'mainboard';

  -- Same value again is a no-op.
  result := public.set_pos_repair_ticket_mainboard(token, jsonb_build_object('store_code', store_code_value, 'ticket_code', code, 'motherboard_repair', 'true'));
  assert (select jsonb_array_length(activity) from public.pos_repair_tickets where ticket_code = code) = before_count + 1, 'No-op wrote activity';

  -- Turn it off.
  result := public.set_pos_repair_ticket_mainboard(token, jsonb_build_object('store_code', store_code_value, 'ticket_code', code, 'motherboard_repair', false));
  assert not (result#>>'{ticket,motherboardRepair}')::boolean, 'Flag not cleared';
  assert (select activity->0->>'text' from public.pos_repair_tickets where ticket_code = code) = 'removed the mainboard repair mark';
  assert (select jsonb_array_length(activity) from public.pos_repair_tickets where ticket_code = code) = before_count + 2;

  -- Other column changes still get the generic line.
  update public.pos_repair_tickets set motherboard_repair = true, updated_by = 'Test' where ticket_code = code;
  assert (select activity->0->>'text' from public.pos_repair_tickets where ticket_code = code) = 'updated motherboard repair',
    'Generic activity line lost for a plain save';

  denied := false;
  begin perform public.set_pos_repair_ticket_mainboard(token, jsonb_build_object('store_code', store_code_value, 'ticket_code', code, 'motherboard_repair', 'yes'));
  exception when others then denied := true; message := sqlerrm; end;
  assert denied and message = 'motherboard_repair must be true or false', 'Non-boolean accepted';

  denied := false;
  begin perform public.set_pos_repair_ticket_mainboard('bad-session', jsonb_build_object('store_code', store_code_value, 'ticket_code', code, 'motherboard_repair', true));
  exception when others then denied := true; end;
  assert denied, 'Invalid session accepted';

  if other_code is not null then
    denied := false;
    begin perform public.set_pos_repair_ticket_mainboard(token, jsonb_build_object('store_code', store_code_value, 'ticket_code', other_code, 'motherboard_repair', true));
    exception when others then denied := true; message := sqlerrm; end;
    assert denied and message = 'Repair ticket belongs to another store', 'Other store card changed';
  end if;

  perform public.manage_pos_repair_memo(token, jsonb_build_object('action', 'create-memo', 'store_code', store_code_value, 'ticket_code', memo_code, 'status', 'need_to_order'));
  denied := false;
  begin perform public.set_pos_repair_ticket_mainboard(token, jsonb_build_object('store_code', store_code_value, 'ticket_code', memo_code, 'motherboard_repair', true));
  exception when others then denied := true; message := sqlerrm; end;
  assert denied and message = 'Memo cards cannot be marked as a mainboard repair', 'Memo card marked';

  update public.pos_repair_tickets set active = false where ticket_code = code;
  denied := false;
  begin perform public.set_pos_repair_ticket_mainboard(token, jsonb_build_object('store_code', store_code_value, 'ticket_code', code, 'motherboard_repair', false));
  exception when others then denied := true; message := sqlerrm; end;
  assert denied and message = 'Repair ticket is not active', 'Deleted card changed';

  assert not has_function_privilege('anon', 'public.set_pos_repair_ticket_mainboard(text,jsonb)', 'execute');
  assert not has_function_privilege('authenticated', 'public.set_pos_repair_ticket_mainboard(text,jsonb)', 'execute');
  raise notice 'PASS: on/off, one activity line each, no-op, generic line kept for plain saves, validation, session, store, memo and deleted guards, grants';
end;
$$;
rollback;
