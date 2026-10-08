-- Run in the PRODUCT project. All fixtures roll back.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '25s';
do $test$
declare
  stamp text := to_char(clock_timestamp(), 'HH24MISSUS');
  group_a text := '测试供货商群 ' || stamp;
  group_b text := '测试私聊 ' || stamp;
  hash text := encode(sha256(convert_to('token-' || stamp, 'UTF8')), 'hex');
  chat_id bigint;
  supplier bigint;
  target jsonb;
  result jsonb;
  order_id bigint;
  snapshot jsonb;
  rejected boolean;
begin
  perform public.purchase_admin_register_bot_token(jsonb_build_object('token_hash', upper(hash), 'label', '店里电脑'), 'Bot test');
  if not public.purchase_bot_token_valid(hash) then raise exception 'A registered fingerprint must be valid'; end if;
  if public.purchase_bot_token_valid(repeat('0', 64)) then raise exception 'An unknown token must be invalid'; end if;
  perform public.purchase_admin_revoke_bot_token(jsonb_build_object('token_hash', hash), 'Bot test');
  if public.purchase_bot_token_valid(hash) then raise exception 'A turned-off PC must be refused'; end if;
  perform public.purchase_admin_register_bot_token(jsonb_build_object('token_hash', hash), 'Bot test');
  if not public.purchase_bot_token_valid(hash) then raise exception 'Registering again must turn the PC back on'; end if;
  rejected := false;
  begin
    perform public.purchase_admin_register_bot_token(jsonb_build_object('token_hash', 'abc'), 'Bot test');
  exception when others then rejected := sqlerrm like '%must be 64%';
  end;
  if not rejected then raise exception 'A malformed fingerprint must be rejected'; end if;
  rejected := false;
  begin
    perform public.purchase_admin_revoke_bot_token(jsonb_build_object('token_hash', repeat('1', 64)), 'Bot test');
  exception when others then rejected := sqlerrm like '%not found%';
  end;
  if not rejected then raise exception 'Turning off an unknown PC must say so'; end if;

  result := public.purchase_bot_heartbeat(jsonb_build_object(
    'state', 'ok', 'version', 'test', 'detail', jsonb_build_object('sessions', 3),
    'groups', jsonb_build_array(group_a, group_b, '  ', group_a)
  ));
  if exists (select 1 from jsonb_array_elements_text(result->'watch') name where name in (group_a, group_b)) then
    raise exception 'New groups must not be watched until the admin turns them on';
  end if;
  if (select count(*) from public.purchase_wechat_groups where group_name in (group_a, group_b)) <> 2 then
    raise exception 'Heartbeat must record each named chat once';
  end if;
  if (select state from public.purchase_bot_status where id = 1) <> 'ok' then
    raise exception 'Heartbeat must store the helper state';
  end if;

  select id into chat_id from public.purchase_wechat_groups where group_name = group_a;
  result := public.purchase_admin_save_wechat_group(jsonb_build_object('id', chat_id, 'watch', true, 'create_supplier', true), 'Bot test');
  supplier := (result->>'supplier_id')::bigint;
  if not exists (select 1 from public.suppliers where id = supplier and name = group_a and wechat = group_a) then
    raise exception 'Turning a group on with create_supplier must add a supplier named after it';
  end if;
  result := public.purchase_bot_heartbeat(jsonb_build_object('state', 'ok', 'groups', '[]'::jsonb));
  if not (result->'watch') ? group_a then raise exception 'A watched group must come back to the helper'; end if;

  target := public.purchase_bot_group_target(group_a);
  if not (target->>'watch')::boolean or (target->>'supplier_id')::bigint <> supplier or target ? 'order_id' and target->>'order_id' is not null then
    raise exception 'Target must be the supplier with no open order yet: %', target;
  end if;
  if (public.purchase_bot_group_target(group_b)->>'watch')::boolean then
    raise exception 'An unwatched group must not be a target';
  end if;
  if (public.purchase_bot_group_target('no such group ' || stamp)->>'watch')::boolean then
    raise exception 'An unknown group must not be a target';
  end if;

  result := public.purchase_admin_import_chat(jsonb_build_object(
    'source', 'wechat_bot', 'supplier_id', supplier,
    'items', jsonb_build_array(jsonb_build_object('description', 'iPhone 15 屏幕', 'quantity', 10, 'unit_cost', 120))
  ), 'WeChat helper');
  order_id := (result->>'order_id')::bigint;
  if not exists (select 1 from public.purchase_orders where id = order_id and source = 'wechat_bot') then
    raise exception 'Helper orders must be marked wechat_bot';
  end if;
  target := public.purchase_bot_group_target(group_a);
  if (target->>'order_id')::bigint is distinct from order_id then
    raise exception 'The supplier''s open order must be the target: %', target;
  end if;

  result := public.purchase_admin_import_chat(jsonb_build_object(
    'source', 'wechat_bot', 'order_id', order_id,
    'parcels', jsonb_build_array(jsonb_build_object('tracking_no', 'SF7788' || stamp, 'contents', '屏幕 ×10'))
  ), 'WeChat helper');
  if not exists (select 1 from public.purchase_parcels where tracking_no = 'SF7788' || stamp
      and source = 'wechat_bot' and supplier_id = supplier and purchase_order_id = order_id) then
    raise exception 'Helper parcels must be marked wechat_bot and linked to the order';
  end if;

  rejected := false;
  begin
    perform public.purchase_admin_import_chat(jsonb_build_object('source', 'sheet', 'parcels',
      jsonb_build_array(jsonb_build_object('tracking_no', 'X1' || stamp))), 'Bot test');
  exception when others then rejected := sqlerrm like '%Invalid import source%';
  end;
  if not rejected then raise exception 'Unknown import sources must be rejected'; end if;

  perform public.purchase_bot_log_event(jsonb_build_object(
    'group_name', group_a, 'supplier_id', supplier, 'status', 'saved',
    'messages', jsonb_build_array(jsonb_build_object('type', 'text', 'text', 'SF7788' || stamp)),
    'result', jsonb_build_object('po_number', 'PO-TEST')
  ));
  snapshot := public.purchase_admin_snapshot();
  if not exists (select 1 from jsonb_array_elements(snapshot->'bot_events') event
      where event->>'group_name' = group_a and (event->>'message_count')::integer = 1) then
    raise exception 'Snapshot must list helper events with a message count';
  end if;
  if not exists (select 1 from jsonb_array_elements(snapshot->'bot_events') event
      where event->>'group_name' = group_a and not event ? 'messages') then
    raise exception 'Snapshot must not carry raw chat messages';
  end if;
  if not exists (select 1 from jsonb_array_elements(snapshot->'wechat_groups') chat
      where chat->>'group_name' = group_a and (chat->>'watch')::boolean) then
    raise exception 'Snapshot must list WeChat groups';
  end if;
  if snapshot->'bot_status'->>'state' is null then raise exception 'Snapshot must carry the helper status'; end if;
  if not exists (select 1 from jsonb_array_elements(snapshot->'bot_tokens') token
      where token->>'token_hash' = hash and token->>'label' = '店里电脑' and token->>'revoked_at' is null) then
    raise exception 'Snapshot must list registered helper PCs';
  end if;

  rejected := false;
  begin
    perform public.purchase_bot_log_event(jsonb_build_object('group_name', group_a, 'status', 'maybe'));
  exception when others then rejected := true;
  end;
  if not rejected then raise exception 'Unknown event statuses must be rejected'; end if;
end;
$test$;
rollback;
