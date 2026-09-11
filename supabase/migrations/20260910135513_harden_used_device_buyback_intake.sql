-- Buyback intake and inventory corrections.
--
--   1. A device that failed the lost-or-stolen check can no longer be bought.
--      The old rule only kept it off the shelf, so the cash had already left
--      the till by the time anyone was stopped.
--   2. The acquisition note became optional in 20260903040000, but the insert
--      still read the missing key straight into a not-null column. The POS
--      always sends an empty string, so only a second caller would have hit it.
--   3. Ledger rows carry their own `change_note`. They used to reuse the device
--      memo, which meant every status change re-published the running memo and
--      the memo had to be rewritten to explain a single change.
--   4. `ready_at` is the first time a device reached the shelf and is no longer
--      cleared when it returns to inspection, so stock age survives a
--      re-inspection or a refund return.
--
-- The three functions are replaced in full rather than patched by anchor. Their
-- deployed definitions were confirmed to match 20260717134620 plus the
-- 20260903040000 and 20260828134609 changes before this was written.

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
  status_value text := coalesce(nullif(trim(payload->>'status'), ''), 'inspection');
  clean_status_value text := coalesce(nullif(trim(payload->>'clean_check_status'), ''), 'Pending');
  purchase_cost_value numeric(12,2) := round(coalesce(nullif(payload->>'purchase_cost', '')::numeric, 0), 2);
  sale_price_value numeric(12,2) := round(coalesce(nullif(payload->>'sale_price', '')::numeric, 0), 2);
  inspection_value jsonb := coalesce(payload->'inspection', '{}'::jsonb);
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
  if status_value not in ('inspection', 'ready_for_sale') then raise exception 'New devices must start in inspection or ready for sale'; end if;
  if purchase_cost_value <= 0 or sale_price_value <= 0 then raise exception 'Purchase cost and sale price must be above zero'; end if;
  if trim(coalesce(payload->>'payout_method', '')) not in ('Cash', 'Bank Transfer') then raise exception 'Invalid payout method'; end if;

  if status_value = 'ready_for_sale' and (
    clean_status_value not in ('Clean', 'Not Applicable')
    or lower(coalesce(payload->>'activation_lock_removed', 'false')) <> 'true'
    or lower(coalesce(payload->>'data_erased_confirmed', 'false')) <> 'true'
    or (select count(*) from jsonb_each_text(inspection_value) result where lower(result.value) in ('pass', 'na')) < 8
    or exists (select 1 from jsonb_each_text(inspection_value) result where lower(result.value) not in ('pass', 'na'))
  ) then raise exception 'Ready-for-sale devices must pass compliance and inspection checks'; end if;

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
    status_value,
    trim(coalesce(payload->>'notes', '')),
    case when jsonb_typeof(payload->'photo_urls') = 'array' then payload->'photo_urls' else '[]'::jsonb end,
    selected_staff.display_name,
    acquisition_row.acquired_at,
    selected_staff.display_name,
    case when status_value = 'ready_for_sale' then now() else null end
  ) returning * into device_row;

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
    jsonb_build_object('acquisition_code', acquisition_row.acquisition_code)
  );

  return jsonb_build_object('ok', true, 'device', public.pos_used_device_payload(device_row));
end;
$$;

create or replace function public.update_pos_used_device(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  selected_staff public.staff_directory%rowtype;
  device_row public.pos_used_devices%rowtype;
  previous_status text;
  previous_price numeric(12,2);
  status_value text;
  price_value numeric(12,2);
  clean_status_value text;
  clean_reference_value text;
  activation_lock_value boolean;
  data_erased_value boolean;
  inspection_value jsonb;
  change_note_value text := trim(coalesce(payload->>'change_note', ''));
  event_type text;
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;

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

  select * into device_row
  from public.pos_used_devices device
  where device.device_code = coalesce(trim(payload->>'device_code'), '')
    and device.store_id = selected_store.id
  for update;
  if not found then raise exception 'Used device not found'; end if;
  if device_row.status = 'sold' then raise exception 'Sold devices cannot be manually changed'; end if;
  if device_row.status in ('returned_to_seller', 'disposed') then raise exception 'Closed device records cannot be changed'; end if;

  previous_status := device_row.status;
  previous_price := device_row.sale_price;
  status_value := coalesce(nullif(trim(payload->>'status'), ''), device_row.status);
  price_value := round(coalesce(nullif(payload->>'sale_price', '')::numeric, device_row.sale_price), 2);
  clean_status_value := coalesce(nullif(trim(payload->>'clean_check_status'), ''), device_row.clean_check_status);
  clean_reference_value := coalesce(payload->>'clean_check_reference', device_row.clean_check_reference);
  activation_lock_value := case
    when payload ? 'activation_lock_removed' then lower(payload->>'activation_lock_removed') = 'true'
    else device_row.activation_lock_removed
  end;
  data_erased_value := case
    when payload ? 'data_erased_confirmed' then lower(payload->>'data_erased_confirmed') = 'true'
    else device_row.data_erased_confirmed
  end;
  inspection_value := case
    when jsonb_typeof(payload->'inspection') = 'object' then payload->'inspection'
    else device_row.inspection
  end;

  if length(change_note_value) > 500 then raise exception 'Change note is too long'; end if;
  if status_value not in ('inspection', 'ready_for_sale', 'returned_to_seller', 'disposed') then raise exception 'Invalid device status'; end if;
  if price_value <= 0 then raise exception 'Sale price must be above zero'; end if;
  if clean_status_value not in ('Clean', 'Blocked', 'Pending', 'Not Applicable') then raise exception 'Invalid device check status'; end if;
  if clean_status_value = 'Clean' and trim(clean_reference_value) = '' then raise exception 'IMEI check reference is required for a clean result'; end if;
  if status_value = 'ready_for_sale' and (
    clean_status_value not in ('Clean', 'Not Applicable')
    or not activation_lock_value
    or not data_erased_value
    or (select count(*) from jsonb_each_text(inspection_value) result where lower(result.value) in ('pass', 'na')) < 8
    or exists (select 1 from jsonb_each_text(inspection_value) result where lower(result.value) not in ('pass', 'na'))
  ) then raise exception 'Device cannot be marked ready until all checks pass'; end if;

  update public.pos_used_devices
  set status = status_value,
      sale_price = price_value,
      clean_check_status = clean_status_value,
      clean_check_reference = clean_reference_value,
      clean_checked_at = case
        when clean_status_value in ('Clean', 'Blocked') and clean_status_value <> device_row.clean_check_status then now()
        else clean_checked_at
      end,
      activation_lock_removed = activation_lock_value,
      data_erased_confirmed = data_erased_value,
      inspection = inspection_value,
      notes = coalesce(payload->>'notes', notes),
      updated_by = selected_staff.display_name,
      -- First time on the shelf. Going back to inspection no longer erases it,
      -- so stock age is still answerable after a re-inspection.
      ready_at = coalesce(ready_at, case when status_value = 'ready_for_sale' then now() else null end)
  where id = device_row.id
  returning * into device_row;

  if previous_price <> device_row.sale_price then
    insert into public.pos_used_device_transactions (
      transaction_code, device_id, store_id, transaction_type, from_status,
      to_status, amount, staff_name, notes, transaction_payload
    ) values (
      'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
      device_row.id, device_row.store_id, 'price_change', previous_status,
      device_row.status, device_row.sale_price, selected_staff.display_name,
      coalesce(nullif(change_note_value, ''), 'Sale price updated'),
      jsonb_build_object('previous_price', previous_price, 'sale_price', device_row.sale_price)
    );
  end if;

  if previous_status <> device_row.status then
    event_type := case device_row.status
      when 'returned_to_seller' then 'returned_to_seller'
      when 'disposed' then 'disposal'
      else 'status_change'
    end;
    insert into public.pos_used_device_transactions (
      transaction_code, device_id, store_id, transaction_type, from_status,
      to_status, amount, staff_name, notes
    ) values (
      'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
      device_row.id, device_row.store_id, event_type, previous_status,
      device_row.status, 0, selected_staff.display_name,
      coalesce(nullif(change_note_value, ''), 'Device status updated')
    );
  end if;

  return jsonb_build_object('ok', true, 'device', public.pos_used_device_payload(device_row));
end;
$$;

create or replace function public.return_refunded_pos_used_device()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  sales_line public.pos_sales_order_lines%rowtype;
  refund_row public.pos_sales_refunds%rowtype;
  device_row public.pos_used_devices%rowtype;
  returned_total integer;
  refunded_total numeric(12,2);
begin
  select * into sales_line from public.pos_sales_order_lines where id = new.sales_order_line_id;
  if sales_line.used_device_id is null then return new; end if;

  select
    coalesce(sum(returned_quantity), 0),
    round(coalesce(sum(amount), 0), 2)
  into returned_total, refunded_total
  from public.pos_sales_refund_lines
  where sales_order_line_id = sales_line.id;
  if returned_total < 1 then return new; end if;

  select * into refund_row from public.pos_sales_refunds where id = new.refund_id;
  -- `ready_at` is deliberately left alone: it is the first date this device
  -- reached the shelf, and a return does not undo that.
  update public.pos_used_devices
  set status = 'inspection',
      sold_order_id = null,
      sold_order_line_id = null,
      sold_at = null,
      updated_by = refund_row.staff_name
  where id = sales_line.used_device_id
    and status = 'sold'
    and sold_order_line_id = sales_line.id
  returning * into device_row;

  if found then
    insert into public.pos_used_device_transactions (
      transaction_code, device_id, store_id, transaction_type, from_status,
      to_status, amount, payment_method, related_sales_order_id,
      related_sales_order_line_id, staff_name, counterparty_name,
      counterparty_phone, notes, transaction_payload
    ) values (
      'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
      device_row.id, device_row.store_id, 'refund_return', 'sold', 'inspection',
      refunded_total, refund_row.method, sales_line.sales_order_id, sales_line.id,
      refund_row.staff_name, '', '', 'Returned device moved back to inspection',
      jsonb_build_object('refund_code', refund_row.refund_code, 'reason', refund_row.reason)
    );
  end if;
  return new;
end;
$$;

revoke execute on function public.create_pos_used_device_acquisition(text, jsonb) from public, anon, authenticated;
revoke execute on function public.update_pos_used_device(text, jsonb) from public, anon, authenticated;
revoke execute on function public.return_refunded_pos_used_device() from public, anon, authenticated;

grant execute on function public.create_pos_used_device_acquisition(text, jsonb) to anon, authenticated, service_role;
grant execute on function public.update_pos_used_device(text, jsonb) to anon, authenticated, service_role;

comment on function public.create_pos_used_device_acquisition(text, jsonb) is
  'Internal POS buyback intake. Records the second-hand dealer register fields, requires storage outside the Other category, accepts either an IMEI or a serial number, treats the acquisition note as optional, and refuses any device that failed the lost-or-stolen check.';

comment on function public.update_pos_used_device(text, jsonb) is
  'Internal POS used-device update. Status, price, compliance and inspection changes append their own ledger rows; `change_note` explains the change without overwriting the device memo.';
