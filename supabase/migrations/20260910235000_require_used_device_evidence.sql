-- Evidence gates on the buyback flow.
--
--   * A purchase cannot be saved without at least three intake photos, taken
--     while the form was open and claimed by the acquisition that pays for the
--     device. Money and proof now move together.
--   * A device cannot reach the shelf without at least one listing photo, so
--     the photos that will describe it online exist before it is sellable.
--   * A device therefore always starts in inspection. Marking it ready is a
--     second, deliberate step once it has been cleaned up and photographed.
--
-- Devices bought before this migration carry `evidence_required = false` and
-- keep working unchanged.

create or replace function public.create_pos_used_device_acquisition(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  selected_staff public.staff_directory%rowtype;
  acquisition_row public.pos_used_device_acquisitions%rowtype;
  device_row public.pos_used_devices%rowtype;
  acquisition_code_value text := 'BUY-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
  device_code_value text := 'USED-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
  seller_name_value text := trim(coalesce(payload->>'seller_name', ''));
  seller_phone_value text := trim(coalesce(payload->>'seller_phone', ''));
  seller_address_value text := trim(coalesce(payload->>'seller_address', ''));
  seller_is_owner_value boolean := lower(coalesce(payload->>'seller_is_owner', 'true')) = 'true';
  normalized_imei_value text := regexp_replace(coalesce(payload->>'imei', ''), '[^0-9]', '', 'g');
  serial_value text := trim(coalesce(payload->>'serial_number', ''));
  clean_status_value text := coalesce(nullif(trim(payload->>'clean_check_status'), ''), 'Pending');
  purchase_cost_value numeric(12,2) := round(coalesce(nullif(payload->>'purchase_cost', '')::numeric, 0), 2);
  sale_price_value numeric(12,2) := round(coalesce(nullif(payload->>'sale_price', '')::numeric, 0), 2);
  inspection_value jsonb := coalesce(payload->'inspection', '{}'::jsonb);
  intake_key_value uuid := nullif(btrim(coalesce(payload->>'intake_key', '')), '')::uuid;
  intake_photo_count integer;
  declaration_value text := 'The seller declares they have the legal right to sell this device, the device is not financed, leased, lost, stolen, or network blocked, and the recorded information is correct.';
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;
  if jsonb_typeof(payload) <> 'object' then raise exception 'Payload must be an object'; end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = coalesce(trim(payload->>'store_code'), '')
    and store_location.store_code <> 'warehouse';
  if not found then raise exception 'Store not found'; end if;

  select * into selected_staff
  from public.staff_directory staff
  where staff.active = true and lower(staff.display_name) = lower(coalesce(trim(payload->>'staff_name'), ''))
  limit 1;
  if not found then raise exception 'Staff member not found'; end if;

  if seller_name_value = '' then raise exception 'Seller name is required'; end if;
  if seller_phone_value = '' then raise exception 'Seller phone is required'; end if;
  if seller_address_value = '' then raise exception 'Seller address is required'; end if;
  if trim(coalesce(payload->>'seller_id_type', '')) = '' or trim(coalesce(payload->>'seller_id_reference', '')) = '' then
    raise exception 'Seller ID type and reference are required';
  end if;
  if lower(coalesce(payload->>'seller_age_confirmed', 'false')) <> 'true' then raise exception 'Seller identity must be confirmed'; end if;
  if lower(coalesce(payload->>'ownership_declaration', 'false')) <> 'true' then raise exception 'Ownership declaration is required'; end if;
  -- The acquisition note is optional; it is recorded when the seller offers it.
  if not seller_is_owner_value and (
    trim(coalesce(payload->>'owner_name', '')) = '' or trim(coalesce(payload->>'owner_address', '')) = ''
  ) then raise exception 'Owner name and address are required when the seller is not the owner'; end if;

  if trim(coalesce(payload->>'category', '')) not in ('Phone', 'Tablet', 'Laptop', 'Watch', 'Game Console', 'Other') then
    raise exception 'Device category is required';
  end if;
  if trim(coalesce(payload->>'brand', '')) = '' or trim(coalesce(payload->>'model', '')) = '' then
    raise exception 'Device brand and model are required';
  end if;
  if trim(coalesce(payload->>'category', '')) <> 'Other' and trim(coalesce(payload->>'storage', '')) = '' then
    raise exception 'Device storage is required';
  end if;
  if trim(coalesce(payload->>'condition_grade', '')) not in ('As New', 'Good', 'Fair', 'Poor', 'Faulty') then
    raise exception 'Device condition is required';
  end if;
  -- One identifier is enough; the IMEI-or-serial rule below still applies.
  if normalized_imei_value <> '' and length(normalized_imei_value) <> 15 then raise exception 'IMEI must contain 15 digits'; end if;
  if normalized_imei_value = '' and serial_value = '' then raise exception 'IMEI or serial number is required'; end if;
  if clean_status_value not in ('Clean', 'Blocked', 'Pending', 'Not Applicable') then raise exception 'Invalid device check status'; end if;
  -- A blocked handset is refused outright. Keeping it out of stock was never
  -- enough, because the payout happens in the same step as the purchase.
  if clean_status_value = 'Blocked' then
    raise exception 'A device that failed the lost or stolen check cannot be bought';
  end if;
  if clean_status_value = 'Clean' and trim(coalesce(payload->>'clean_check_reference', '')) = '' then
    raise exception 'IMEI check reference is required for a clean result';
  end if;
  -- Every purchase starts in inspection. Reaching the shelf needs listing
  -- photos, which cannot exist before the device record does.
  if coalesce(nullif(trim(payload->>'status'), ''), 'inspection') <> 'inspection' then
    raise exception 'A purchase starts in inspection. Photograph the device for sale, then mark it ready';
  end if;
  if purchase_cost_value <= 0 or sale_price_value <= 0 then raise exception 'Purchase cost and sale price must be above zero'; end if;
  if trim(coalesce(payload->>'payout_method', '')) not in ('Cash', 'Bank Transfer') then raise exception 'Invalid payout method'; end if;

  -- Proof of what was handed over, before the money moves.
  if intake_key_value is null then
    raise exception 'Photograph the device before saving the purchase';
  end if;
  select count(*) into intake_photo_count
  from public.pos_used_device_intake_uploads upload
  where upload.intake_key = intake_key_value
    and upload.store_id = selected_store.id
    and upload.stage = 'intake'
    and upload.claimed_device_id is null;
  if intake_photo_count < 3 then
    raise exception 'At least three intake photos are required before a purchase can be saved';
  end if;

  insert into public.pos_used_device_acquisitions (
    acquisition_code, store_id, shift_id, seller_name, seller_phone, seller_email,
    seller_address, seller_id_type, seller_id_reference, seller_age_confirmed,
    seller_is_owner, owner_name, owner_address, acquisition_statement,
    ownership_declaration, payout_method, payout_amount, declaration_text,
    acquired_by
  ) values (
    acquisition_code_value,
    selected_store.id,
    nullif(trim(payload->>'shift_id'), ''),
    seller_name_value,
    seller_phone_value,
    lower(trim(coalesce(payload->>'seller_email', ''))),
    seller_address_value,
    trim(payload->>'seller_id_type'),
    trim(payload->>'seller_id_reference'),
    true,
    seller_is_owner_value,
    trim(coalesce(payload->>'owner_name', '')),
    trim(coalesce(payload->>'owner_address', '')),
    trim(coalesce(payload->>'acquisition_statement', '')),
    true,
    trim(payload->>'payout_method'),
    purchase_cost_value,
    declaration_value,
    selected_staff.display_name
  ) returning * into acquisition_row;

  insert into public.pos_used_devices (
    device_code, acquisition_id, store_id, category, brand, model, variant,
    color, storage, imei, normalized_imei, serial_number, condition_grade,
    battery_health, inspection, clean_check_status, clean_check_reference,
    clean_checked_at, activation_lock_removed, data_erased_confirmed,
    purchase_cost, sale_price, status, notes, photo_urls, acquired_by,
    acquired_at, updated_by, ready_at
  ) values (
    device_code_value,
    acquisition_row.id,
    selected_store.id,
    trim(payload->>'category'),
    trim(payload->>'brand'),
    trim(payload->>'model'),
    trim(coalesce(payload->>'variant', '')),
    trim(coalesce(payload->>'color', '')),
    trim(coalesce(payload->>'storage', '')),
    trim(coalesce(payload->>'imei', '')),
    normalized_imei_value,
    serial_value,
    trim(payload->>'condition_grade'),
    nullif(payload->>'battery_health', '')::integer,
    inspection_value,
    clean_status_value,
    trim(coalesce(payload->>'clean_check_reference', '')),
    case when clean_status_value in ('Clean', 'Blocked') then now() else null end,
    lower(coalesce(payload->>'activation_lock_removed', 'false')) = 'true',
    lower(coalesce(payload->>'data_erased_confirmed', 'false')) = 'true',
    purchase_cost_value,
    sale_price_value,
    'inspection',
    trim(coalesce(payload->>'notes', '')),
    '[]'::jsonb,
    selected_staff.display_name,
    acquisition_row.acquired_at,
    selected_staff.display_name,
    null
  ) returning * into device_row;

  -- The photos taken during the purchase become this device's intake evidence.
  insert into public.pos_used_device_updates (id, device_id, kind, stage, storage_path, file_name, author)
  select upload.id, device_row.id, 'photo', upload.stage, upload.storage_path, upload.file_name, upload.author
  from public.pos_used_device_intake_uploads upload
  where upload.intake_key = intake_key_value
    and upload.store_id = selected_store.id
    and upload.claimed_device_id is null;

  update public.pos_used_device_intake_uploads
  set claimed_device_id = device_row.id
  where intake_key = intake_key_value
    and store_id = selected_store.id
    and claimed_device_id is null;

  insert into public.pos_used_device_transactions (
    transaction_code, device_id, store_id, transaction_type, from_status,
    to_status, amount, payment_method, staff_name, counterparty_name,
    counterparty_phone, notes, transaction_payload
  ) values (
    'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
    device_row.id,
    selected_store.id,
    'acquisition',
    null,
    device_row.status,
    purchase_cost_value,
    acquisition_row.payout_method,
    selected_staff.display_name,
    acquisition_row.seller_name,
    acquisition_row.seller_phone,
    'Device purchased from seller',
    jsonb_build_object('acquisition_code', acquisition_row.acquisition_code, 'intake_photos', intake_photo_count)
  );

  return jsonb_build_object('ok', true, 'device', public.pos_used_device_payload(device_row));
end;
$$;

do $migration$
declare
  definition text;
  patched text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'update_pos_used_device'
    and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'update_pos_used_device was not found'; end if;

  patched := replace(
    definition,
    $anchor$  ) then raise exception 'Device cannot be marked ready until all checks pass'; end if;$anchor$,
    $replacement$  ) then raise exception 'Device cannot be marked ready until all checks pass'; end if;
  if status_value = 'ready_for_sale' and device_row.evidence_required and not exists (
    select 1 from public.pos_used_device_updates entry
    where entry.device_id = device_row.id and entry.kind = 'photo' and entry.stage = 'listing'
  ) then raise exception 'Add at least one listing photo before the device is ready for sale'; end if;$replacement$
  );
  if patched = definition then
    raise exception 'used device evidence patch: the ready-for-sale anchor was not found';
  end if;

  execute patched;
end;
$migration$;

revoke execute on function public.create_pos_used_device_acquisition(text, jsonb) from public, anon, authenticated;
grant execute on function public.create_pos_used_device_acquisition(text, jsonb) to anon, authenticated, service_role;

comment on function public.create_pos_used_device_acquisition(text, jsonb) is
  'Internal POS buyback intake. Records the second-hand dealer register fields, refuses a device that failed the lost-or-stolen check, requires at least three intake photos taken during the purchase, and always starts the device in inspection.';
