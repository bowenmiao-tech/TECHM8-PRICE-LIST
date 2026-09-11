begin;

do $$
declare
  token text := extensions.gen_random_uuid()::text;
  staff_id_value bigint;
  staff_name_value text;
  store_code_value text;
  good_code text := 'TEST-ATOMIC-' || extensions.gen_random_uuid()::text;
  failed_code text := 'TEST-ROLLBACK-' || extensions.gen_random_uuid()::text;
  ticket jsonb;
  signature jsonb;
  result jsonb;
  denied boolean := false;
begin
  select staff.id, staff.display_name, store.store_code
  into staff_id_value, staff_name_value, store_code_value
  from public.staff_directory staff
  join public.store_locations store on store.id = staff.default_store_id
  where staff.active and store.active and store.store_code <> 'warehouse'
  limit 1;

  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
  values (
    staff_id_value,
    extensions.crypt(token, extensions.gen_salt('bf')),
    encode(extensions.digest(token, 'sha256'), 'hex'),
    now() + interval '5 minutes'
  );

  ticket := jsonb_build_object(
    'id', good_code,
    'ticket_code', good_code,
    'store_code', store_code_value,
    'staff_name', staff_name_value,
    'title', 'Atomic repair test',
    'issue', 'Inspection',
    'price', '$49.00',
    'status', 'repairing',
    'customerName', 'Atomic Test Customer',
    'customerPhone', '0400000000',
    'createdBy', staff_name_value,
    'updatedBy', staff_name_value,
    'intake', jsonb_build_object(
      'quote', jsonb_build_object('brand', 'Test', 'model', 'Device', 'issue', 'Inspection'),
      'deviceIdType', 'none',
      'deviceIdUnavailable', 'Test fixture has no physical label',
      'passwordType', 'none',
      'passwordNoneReason', 'Test fixture has no password',
      'testable', 'no',
      'cannotTestReason', 'Rollback-only database fixture'
    ),
    'activity', '[]'::jsonb,
    'comments', '[]'::jsonb
  );
  signature := jsonb_build_object(
    'store_code', store_code_value,
    'ticket_code', good_code,
    'staff_name', staff_name_value,
    'signed_customer_name', 'Atomic Test Customer',
    'signature_path', store_code_value || '/' || good_code || '/test.png',
    'card_snapshot', jsonb_build_object('ticket_code', good_code, 'price', '$49.00')
  );

  result := public.create_pos_repair_ticket_with_signature(token, ticket, signature);
  assert result->>'ok' = 'true';
  assert result#>>'{ticket,id}' = good_code;
  assert result#>>'{signature,signed_customer_name}' = 'Atomic Test Customer';
  assert (select count(*) from public.pos_repair_tickets where ticket_code = good_code) = 1;
  assert (
    select count(*)
    from public.pos_repair_card_signatures card
    join public.pos_repair_tickets repair on repair.id = card.repair_ticket_id
    where repair.ticket_code = good_code and card.superseded_at is null
  ) = 1;

  ticket := ticket || jsonb_build_object('id', failed_code, 'ticket_code', failed_code);
  signature := signature || jsonb_build_object(
    'ticket_code', failed_code,
    'signature_path', store_code_value || '/' || failed_code || '/test.png',
    'signed_customer_name', ''
  );
  begin
    perform public.create_pos_repair_ticket_with_signature(token, ticket, signature);
  exception when others then
    denied := true;
  end;
  assert denied, 'The invalid signature was accepted';
  assert not exists (
    select 1 from public.pos_repair_tickets where ticket_code = failed_code
  ), 'A failed signature left an unsigned repair ticket';

  denied := false;
  begin
    perform public.create_pos_repair_ticket_with_signature('invalid-session', ticket, signature);
  exception when others then
    denied := true;
  end;
  assert denied, 'An invalid staff session was accepted';
  assert not has_function_privilege(
    'anon',
    'public.create_pos_repair_ticket_with_signature(text,jsonb,jsonb)',
    'execute'
  );
end;
$$;

rollback;
