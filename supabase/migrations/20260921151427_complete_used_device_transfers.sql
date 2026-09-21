-- Receipt photos use the existing private evidence uploader and signed image access.
alter table public.pos_used_device_transfers add column if not exists receipt_photo_ids uuid[] not null default '{}';

create or replace function public.send_pos_used_device_transfer(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $send_transfer$
declare
  actor jsonb;
  from_store_id bigint;
  to_store public.store_locations%rowtype;
  device_row public.pos_used_devices%rowtype;
  transfer_row public.pos_used_device_transfers%rowtype;
  note_value text := left(btrim(coalesce(payload->>'note', '')), 500);
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Payload must be an object'; end if;

  actor := public.pos_authorized_actor(
    session_token,
    coalesce(payload->>'store_code', ''),
    nullif(btrim(coalesce(payload->>'staff_name', '')), '')
  );
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;
  from_store_id := (actor->>'store_id')::bigint;

  select * into to_store
  from public.store_locations
  where active = true
    and store_code <> 'warehouse'
    and store_code = lower(btrim(coalesce(payload->>'to_store_code', '')));
  if not found then raise exception 'Destination store not found'; end if;
  if to_store.id = from_store_id then raise exception 'A device cannot be sent to the store it is already in'; end if;

  select * into device_row
  from public.pos_used_devices
  where device_code = btrim(coalesce(payload->>'device_code', ''))
  for update;
  if not found then raise exception 'Used device not found'; end if;

  -- Only the store holding the device may send it.
  if device_row.store_id <> from_store_id then
    raise exception 'This device is held by another store, so it cannot be sent from here';
  end if;

  if device_row.status not in ('inspection', 'ready_for_sale') then
    raise exception 'Only a device still in stock can be transferred. This one is %',
      replace(device_row.status, '_', ' ');
  end if;

  if exists (
    select 1 from public.pos_used_device_transfers
    where device_id = device_row.id and status = 'in_transit'
  ) then
    raise exception 'This device is already in transit';
  end if;

  insert into public.pos_used_device_transfers (
    transfer_code, device_id, from_store_id, to_store_id, status,
    device_snapshot, sent_by, sent_note
  ) values (
    'DTR-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)),
    device_row.id,
    from_store_id,
    to_store.id,
    'in_transit',
    jsonb_build_object(
      'device_code', device_row.device_code,
      'category', device_row.category,
      'brand', device_row.brand,
      'model', device_row.model,
      'variant', device_row.variant,
      'color', device_row.color,
      'storage', device_row.storage,
      'imei', device_row.imei,
      'serial_number', device_row.serial_number,
      'condition_grade', device_row.condition_grade,
      'battery_health', device_row.battery_health,
      'clean_check_status', device_row.clean_check_status,
      'sale_price', device_row.sale_price,
      'status', device_row.status,
      'notes', device_row.notes,
      'photo_urls', device_row.photo_urls,
      'ready_at', device_row.ready_at,
      'snapshot_taken_at', now()
    ),
    actor->>'staff_name',
    note_value
  ) returning * into transfer_row;

  -- The device stays owned by the sender until the other end accepts it, but
  -- it is withdrawn from sale immediately: it is not on this shelf any more.
  if device_row.status = 'ready_for_sale' then
    update public.pos_used_devices
    set status = 'inspection', ready_at = null, updated_by = actor->>'staff_name', updated_at = now()
    where id = device_row.id
    returning * into device_row;
  end if;

  insert into public.pos_used_device_transactions (
    transaction_code, device_id, store_id, transaction_type, from_status, to_status,
    amount, payment_method, staff_name, counterparty_name, counterparty_phone,
    notes, transaction_payload
  ) values (
    'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
    device_row.id, from_store_id, 'transfer_out', device_row.status, device_row.status,
    0, '', actor->>'staff_name', to_store.store_name, '',
    case when note_value = '' then 'Sent to ' || to_store.store_name
         else 'Sent to ' || to_store.store_name || ': ' || note_value end,
    jsonb_build_object(
      'transfer_code', transfer_row.transfer_code,
      'to_store_code', to_store.store_code,
      'device_snapshot', transfer_row.device_snapshot
    )
  );

  return jsonb_build_object(
    'ok', true,
    'transfer', public.pos_used_device_transfer_payload(transfer_row)
  );
end;
$send_transfer$;

create or replace function public.receive_pos_used_device_transfer(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $receive_transfer$
declare
  actor jsonb;
  receiving_store_id bigint;
  transfer_row public.pos_used_device_transfers%rowtype;
  device_row public.pos_used_devices%rowtype;
  from_store public.store_locations%rowtype;
  receipt_key uuid := nullif(payload->>'receipt_intake_key', '')::uuid;
  photo_ids uuid[];
  note_value text := left(btrim(coalesce(payload->>'note', '')), 500);
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Payload must be an object'; end if;

  actor := public.pos_authorized_actor(
    session_token,
    coalesce(payload->>'store_code', ''),
    nullif(btrim(coalesce(payload->>'staff_name', '')), '')
  );
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;
  receiving_store_id := (actor->>'store_id')::bigint;

  select * into transfer_row
  from public.pos_used_device_transfers
  where transfer_code = btrim(coalesce(payload->>'transfer_code', ''))
  for update;
  if not found then raise exception 'Transfer not found'; end if;

  if transfer_row.to_store_id <> receiving_store_id then
    raise exception 'This transfer was not sent to your store';
  end if;
  -- A retried confirmation returns the completed transfer without moving it twice.
  if transfer_row.status = 'received' then
    return jsonb_build_object('ok', true, 'transfer', public.pos_used_device_transfer_payload(transfer_row));
  end if;
  if transfer_row.status <> 'in_transit' then
    raise exception 'This transfer was already %', transfer_row.status;
  end if;

  -- Only the destination can accept it. A store cannot receive a device into
  -- itself that was never sent to it.
  if transfer_row.to_store_id <> receiving_store_id then
    raise exception 'This transfer was not sent to your store';
  end if;

  select * into from_store from public.store_locations where id = transfer_row.from_store_id;

  select * into device_row
  from public.pos_used_devices
  where id = transfer_row.device_id
  for update;
  if not found then raise exception 'Used device not found'; end if;

  if device_row.store_id <> transfer_row.from_store_id then
    raise exception 'The device is no longer at the sending store';
  end if;
  -- Lock staged uploads before claiming them, preventing reuse by concurrent receipts.
  select array_agg(locked.id) into photo_ids from (
    select u.id from public.pos_used_device_intake_uploads u
    where u.intake_key = receipt_key and u.store_id = receiving_store_id
      and u.stage = 'intake' and u.claimed_device_id is null
    for update
  ) locked;
  if coalesce(cardinality(photo_ids), 0) = 0 then
    raise exception 'Take at least one receipt photo before confirming receipt';
  end if;

  insert into public.pos_used_device_updates(id, device_id, kind, stage, storage_path, file_name, author)
  select u.id, device_row.id, 'photo', 'refurb', u.storage_path,
    'Transfer ' || transfer_row.transfer_code || ' receipt - ' || coalesce(u.file_name, 'Photo.jpg'), actor->>'staff_name'
  from public.pos_used_device_intake_uploads u where u.id = any(photo_ids);
  update public.pos_used_device_intake_uploads set claimed_device_id = device_row.id where id = any(photo_ids);

  update public.pos_used_device_transfers
  set status = 'received',
      received_by = actor->>'staff_name',
      received_at = now(),
      received_note = note_value,
      receipt_photo_ids = photo_ids,
      updated_at = now()
  where id = transfer_row.id
  returning * into transfer_row;

  -- Confirming receipt changes the store without resetting its inspection or price.
  update public.pos_used_devices
  set store_id = receiving_store_id,
      status = coalesce(transfer_row.device_snapshot->>'status', device_row.status),
      ready_at = case when transfer_row.device_snapshot->>'status' = 'ready_for_sale'
        then coalesce(nullif(transfer_row.device_snapshot->>'ready_at', '')::timestamptz, now()) else device_row.ready_at end,
      updated_by = actor->>'staff_name',
      updated_at = now()
  where id = device_row.id
  returning * into device_row;

  insert into public.pos_used_device_transactions (
    transaction_code, device_id, store_id, transaction_type, from_status, to_status,
    amount, payment_method, staff_name, counterparty_name, counterparty_phone,
    notes, transaction_payload
  ) values (
    'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
    device_row.id, receiving_store_id, 'transfer_in', device_row.status, device_row.status,
    0, '', actor->>'staff_name', from_store.store_name, '',
    case when note_value = '' then 'Received from ' || from_store.store_name
         else 'Received from ' || from_store.store_name || ': ' || note_value end,
    jsonb_build_object(
      'transfer_code', transfer_row.transfer_code,
      'from_store_code', from_store.store_code,
      'device_snapshot', transfer_row.device_snapshot,
      'receipt_photo_ids', to_jsonb(photo_ids)
    )
  );

  return jsonb_build_object(
    'ok', true,
    'transfer', public.pos_used_device_transfer_payload(transfer_row)
  );
end;
$receive_transfer$;

DO $patch$
DECLARE definition text;
BEGIN
  definition := pg_get_functiondef('public.pos_used_device_transfer_payload(public.pos_used_device_transfers)'::regprocedure);
  IF position('''receipt_photo_url'', transfer_row.receipt_photo_url' in definition) = 0 THEN
    RAISE EXCEPTION 'Transfer payload anchor missing';
  END IF;
  EXECUTE replace(definition, '''receipt_photo_url'', transfer_row.receipt_photo_url',
    '''receipt_photo_ids'', to_jsonb(transfer_row.receipt_photo_ids), ''receipt_photo_url'', transfer_row.receipt_photo_url');

  definition := pg_get_functiondef('public.get_admin_used_device_detail(text,text)'::regprocedure);
  IF position('''ledger'', ledger_payload' in definition) = 0 THEN
    RAISE EXCEPTION 'Admin device detail anchor missing';
  END IF;
  EXECUTE replace(definition, '''ledger'', ledger_payload',
    '''transfers'', (select coalesce(jsonb_agg(public.pos_used_device_transfer_payload(t) order by t.sent_at desc), ''[]''::jsonb) from public.pos_used_device_transfers t where t.device_id = device_row.id), ''ledger'', ledger_payload');
END
$patch$;

-- Keep at least one visible photo for each confirmed receipt.
DO $patch$
DECLARE definition text;
BEGIN
  definition := pg_get_functiondef('public.remove_pos_used_device_photo(text,text,text,uuid)'::regprocedure);
  IF position('  select count(*) into others_in_stage' in definition) = 0 THEN
    RAISE EXCEPTION 'Photo removal anchor missing';
  END IF;
  EXECUTE replace(definition, '  select count(*) into others_in_stage',
    '  if exists (
      select 1 from public.pos_used_device_transfers t
      where target_update_id = any(t.receipt_photo_ids) and t.status = ''received''
        and not exists (select 1 from public.pos_used_device_updates p
          where p.id = any(t.receipt_photo_ids) and p.id <> target_update_id)
    ) then raise exception ''Keep at least one receipt photo for this transfer''; end if;
  select count(*) into others_in_stage');
END
$patch$;
