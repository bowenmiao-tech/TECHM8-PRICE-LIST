begin;
do $$
declare
  token text := extensions.gen_random_uuid()::text;
  staff_id_value bigint; store_code_value text;
  code text := 'TEST-REOPEN-' || extensions.gen_random_uuid()::text;
  request jsonb; result jsonb; denied boolean; message text;
  repair_code text; repair_store text; invoice_value text; order_value text; repair_staff bigint;
  repair_token text := extensions.gen_random_uuid()::text;
begin
  select staff.id, store.store_code into staff_id_value, store_code_value
    from public.staff_directory staff join public.store_locations store on store.id = staff.default_store_id
    where staff.active and store.active and store.store_code <> 'warehouse' limit 1;
  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
    values(staff_id_value, extensions.crypt(token, extensions.gen_salt('bf')), encode(extensions.digest(token, 'sha256'), 'hex'), now() + interval '5 minutes');

  -- Memo card: finish, then reopen with a reason.
  request := jsonb_build_object('action', 'create-memo', 'store_code', store_code_value, 'ticket_code', code, 'status', 'need_to_order');
  perform public.manage_pos_repair_memo(token, request);
  result := public.manage_pos_repair_memo(token, request || jsonb_build_object('action', 'finish-memo'));
  assert result#>>'{ticket,closedAt}' is not null, 'Memo did not close';

  -- Moving a Done card (status list or drag) sends no note.
  result := public.reopen_pos_repair_ticket(token, jsonb_build_object('store_code', store_code_value, 'ticket_code', code, 'reason', '   ', 'status', 'over_3_months_uncollected'));
  assert result#>>'{ticket,status}' = 'over_3_months_uncollected' and result#>>'{ticket,closedAt}' is null, 'Move without a note did not reopen';
  assert result#>>'{ticket,readyForPickupAt}' is not null, 'Uncollected column needs a pickup date';
  assert jsonb_array_length(public.get_repair_ticket_updates(token, store_code_value, code)->'updates') = 0, 'Blank note saved as a comment';
  result := public.manage_pos_repair_memo(token, request || jsonb_build_object('action', 'finish-memo'));
  assert result#>>'{ticket,closedAt}' is not null, 'Memo did not close again';

  denied := false;
  begin perform public.reopen_pos_repair_ticket(token, jsonb_build_object('store_code', store_code_value, 'ticket_code', code, 'reason', 'x', 'status', 'closed'));
  exception when others then denied := true; end;
  assert denied, 'Reopen into the closed column accepted';

  denied := false;
  begin perform public.reopen_pos_repair_ticket('bad-session', jsonb_build_object('store_code', store_code_value, 'ticket_code', code, 'reason', 'x'));
  exception when others then denied := true; end;
  assert denied, 'Invalid session accepted';

  result := public.reopen_pos_repair_ticket(token, jsonb_build_object(
    'store_code', store_code_value, 'ticket_code', code, 'status', 'waiting_customer_confirmation',
    'reason', 'Screen flickers again', 'device_in_store', false));
  assert result#>>'{ticket,closedAt}' is null, 'Card still closed';
  assert result#>>'{ticket,status}' = 'waiting_customer_confirmation';
  assert (result#>>'{ticket,deviceInStore}')::boolean = false;
  assert result#>>'{ticket,boardPosition}' = '0';
  assert (result#>'{ticket,activity}') @> '[{"reopened": true}]'::jsonb, 'Reopen not in activity';
  assert (public.get_repair_ticket_updates(token, store_code_value, code)->'updates') @> '[{"kind": "comment", "body": "Follow-up check: Screen flickers again"}]'::jsonb,
    'Reason was not saved as a note';

  denied := false;
  begin perform public.reopen_pos_repair_ticket(token, jsonb_build_object('store_code', store_code_value, 'ticket_code', code, 'reason', 'again'));
  exception when others then denied := true; message := sqlerrm; end;
  assert denied and message = 'This card is already open on the Repair Board', 'Open card reopened twice';

  -- A reopened card finishes again the normal way.
  result := public.manage_pos_repair_memo(token, request || jsonb_build_object('action', 'finish-memo'));
  assert result#>>'{ticket,closedAt}' is not null, 'Reopened memo could not finish again';

  update public.pos_repair_tickets set active = false where ticket_code = code;
  denied := false;
  begin perform public.reopen_pos_repair_ticket(token, jsonb_build_object('store_code', store_code_value, 'ticket_code', code, 'reason', 'x'));
  exception when others then denied := true; message := sqlerrm; end;
  assert denied and message = 'Deleted repair tickets cannot be reopened', 'Deleted card reopened';

  -- Real repair card closed after a paid invoice: find it by invoice number,
  -- reopen it, then close it again against the same invoice.
  select ticket.ticket_code, store.store_code, sales_order.invoice_number::text, sales_order.order_code, staff.id
    into repair_code, repair_store, invoice_value, order_value, repair_staff
    from public.pos_repair_tickets ticket
    join public.store_locations store on store.id = ticket.store_id
    join public.pos_sales_order_lines line on line.repair_ticket_id = ticket.id and line.repair_job_id is null
    join public.pos_sales_orders sales_order on sales_order.id = line.sales_order_id
    join public.staff_directory staff on staff.default_store_id = store.id and staff.active
    where ticket.active and ticket.closed_at is not null and ticket.card_kind = 'repair'
      and sales_order.payment_status = 'paid' and sales_order.invoice_number is not null
      and not exists (select 1 from public.pos_repair_ticket_jobs job where job.repair_ticket_id = ticket.id)
    order by ticket.closed_at desc limit 1;
  assert repair_code is not null, 'No closed repair with a paid invoice to test against';
  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
    values(repair_staff, extensions.crypt(repair_token, extensions.gen_salt('bf')), encode(extensions.digest(repair_token, 'sha256'), 'hex'), now() + interval '5 minutes');

  assert (public.search_pos_repair_tickets(repair_token, repair_store, invoice_value, 500)->'tickets') @> jsonb_build_array(jsonb_build_object('id', repair_code)),
    'Invoice number search missed the card';
  assert (public.search_pos_repair_tickets(repair_token, repair_store, '#' || invoice_value, 500)->'tickets') @> jsonb_build_array(jsonb_build_object('id', repair_code)),
    'Invoice number with # missed the card';
  assert (public.search_pos_repair_tickets(repair_token, repair_store, order_value, 500)->'tickets') @> jsonb_build_array(jsonb_build_object('id', repair_code)),
    'Order code search missed the card';
  assert not ((public.search_pos_repair_tickets(repair_token, repair_store, '', 500)->'tickets') @> jsonb_build_array(jsonb_build_object('id', repair_code))),
    'Closed card shown on the unfiltered board';

  result := public.reopen_pos_repair_ticket(repair_token, jsonb_build_object('store_code', repair_store, 'ticket_code', repair_code, 'reason', 'Battery drains fast again'));
  assert result#>>'{ticket,status}' = 'repairing' and result#>>'{ticket,closedAt}' is null and result#>>'{ticket,resolution}' is null;
  assert (result#>>'{ticket,deviceInStore}')::boolean, 'Device should default to in store';
  assert (result#>>'{ticket,canClose}')::boolean, 'Paid card with no new work should be closable again';
  assert (public.search_pos_repair_tickets(repair_token, repair_store, '', 500)->'tickets') @> jsonb_build_array(jsonb_build_object('id', repair_code)),
    'Reopened card missing from the board';

  perform public.move_pos_repair_ticket(repair_token, jsonb_build_object('store_code', repair_store, 'status', 'repairing', 'ordered_codes', jsonb_build_array(repair_code)));
  assert (select board_position from public.pos_repair_tickets where ticket_code = repair_code) = 10, 'Reopened card could not be reordered after a drag';

  result := public.finalize_pos_repair_ticket_after_checkout(repair_token, jsonb_build_object(
    'store_code', repair_store, 'ticket_code', repair_code, 'order_code', order_value, 'decision', 'finish', 'resolution', 'no_fault_found'));
  assert result#>>'{ticket,closedAt}' is not null and result#>>'{ticket,resolution}' = 'no_fault_found', 'Reopened repair could not close again';

  assert not has_function_privilege('anon', 'public.reopen_pos_repair_ticket(text,jsonb)', 'execute');
  assert not has_function_privilege('authenticated', 'public.reopen_pos_repair_ticket(text,jsonb)', 'execute');
  raise notice 'PASS: reopen validation, note, activity, finish again, deleted guard, invoice/order search, grants';
end;
$$;
rollback;
