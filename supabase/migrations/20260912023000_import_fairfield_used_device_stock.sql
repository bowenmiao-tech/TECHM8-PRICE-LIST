-- Fairfield's existing second-hand stock, from the store's spreadsheet.
--
-- Six devices bought between 19 November 2025 and 11 September 2026, before the
-- POS recorded buybacks. They are loaded so the stock, the costs and the online
-- prices are in one place, and so the photo, inspection and publishing steps
-- can run on them like any other device.
--
-- WHAT THE SPREADSHEET DID NOT HAVE, and how it is recorded rather than guessed:
--
--   * Seller name, phone, address and ID. Nothing is invented. Every field says
--     "Not recorded", `seller_age_confirmed` and `ownership_declaration` are
--     false, and `declaration_text` says the paper form in store is the record.
--     An auditor reading the register sees the gap instead of a fiction.
--   * Payout method. Recorded as Cash, which is the assumption stated in the
--     acquisition note. These sit in a closed import shift so they never touch
--     a real shift reconciliation.
--   * Condition grade. Set to Good as a placeholder and said so in the device
--     memo. It is correctable from the POS since
--     20260912021500_allow_used_device_detail_corrections, and it has to be
--     confirmed before the device can be sold, because the grade is what the
--     public listing tells the customer.
--   * Inspection results and the lost-or-stolen check. Left empty and Pending.
--     Staff answer the checklist when they make each device ready; the gate
--     will not let a device reach the shelf or the website until they have.
--
-- The "Additional Cost Price" column becomes a refurbishment cost row, so the
-- spreadsheet's Total Price is reproduced as purchase price plus refurbishment,
-- and margin is calculated against the real number.
--
-- The five IMEIs were checked against the Luhn checksum before loading; all
-- five are valid, so none was mistyped in transit. The iPad has an Apple serial
-- rather than an IMEI and is stored as one.

do $import$
declare
  store_row public.store_locations%rowtype;
  shift_code_value text := 'FF-BUYBACK-IMPORT-20260912';
  import_actor text := 'Spreadsheet import';
  acquisition_row public.pos_used_device_acquisitions%rowtype;
  device_row public.pos_used_devices%rowtype;
  item record;
  imported_count integer := 0;
begin
  select * into store_row from public.store_locations where store_code = 'fairfield' and active;
  if not found then raise exception 'Fairfield store not found'; end if;

  -- The acquisition table insists on an open shift for the store. These are
  -- historical purchases, so they get their own shift, which is closed again
  -- before this block ends and never appears as Fairfield's working shift.
  insert into public.pos_store_shifts (
    shift_code, store_id, business_date, status, opened_by,
    current_staff_name, last_staff_name
  ) values (
    shift_code_value, store_row.id, date '2026-09-12', 'open', import_actor,
    import_actor, import_actor
  )
  on conflict (shift_code) do nothing;

  for item in
    select * from (values
      (date '2025-11-19', 'Tablet', 'iPad Air 4',        '64GB',  'Black', null::integer, '',                'DMPDL58CQ16M', 100.00, 0.00, 449.00),
      (date '2026-07-10', 'Phone',  'iPhone 11',         '128GB', 'Black', 100,           '354004101779845', '', 213.20,  50.00, 399.00),
      (date '2026-08-31', 'Phone',  'iPhone 11 Pro Max', '256GB', 'Green', 100,           '353914108904207', '', 321.00,  19.00, 429.00),
      (date '2026-08-31', 'Phone',  'iPhone 15 Pro Max', '256GB', 'Grey',  89,            '351149510086317', '', 771.00,  50.00, 949.00),
      (date '2026-08-31', 'Phone',  'iPhone 14 Pro Max', '128GB', 'Black', 85,            '358165606246527', '', 621.00,  50.00, 749.00),
      (date '2026-09-11', 'Phone',  'iPhone 12 Pro',     '256GB', 'Black', 100,           '354991554565921', '', 150.00,  30.00, 449.00)
    ) as source(
      purchased_on, category, model, storage, color, battery_health,
      imei, serial_number, purchase_cost, refurb_cost, sale_price
    )
  loop
    -- The iPad carries a serial instead of an IMEI.
    if item.imei = '' and item.serial_number = '' then
      continue;
    end if;

    if exists (
      select 1 from public.pos_used_devices device
      where (item.imei <> '' and device.normalized_imei = item.imei)
         or (item.serial_number <> '' and lower(device.serial_number) = lower(item.serial_number))
    ) then
      raise notice 'Skipping % - already in inventory', coalesce(nullif(item.imei, ''), item.serial_number);
      continue;
    end if;

    insert into public.pos_used_device_acquisitions (
      acquisition_code, store_id, shift_id, seller_name, seller_phone, seller_email,
      seller_address, seller_id_type, seller_id_reference, seller_age_confirmed,
      seller_is_owner, owner_name, owner_address, acquisition_statement,
      ownership_declaration, payout_method, payout_amount, declaration_text,
      acquired_by, acquired_at
    ) values (
      'BUY-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)),
      store_row.id,
      shift_code_value,
      'Not recorded',
      'Not recorded',
      '',
      'Not recorded',
      'Not recorded',
      'Not recorded',
      false,
      true,
      '',
      '',
      'Imported from the Fairfield stock spreadsheet on 12 September 2026. The purchase predates POS buyback recording, so seller details, payout method and inspection results were never captured in the system. Payout method is recorded as Cash by assumption.',
      false,
      'Cash',
      item.purchase_cost,
      'No seller declaration was captured in the POS for this purchase. The paper buyback form held at Fairfield is the record of sale.',
      import_actor,
      (item.purchased_on + time '12:00') at time zone 'Australia/Brisbane'
    ) returning * into acquisition_row;

    insert into public.pos_used_devices (
      device_code, acquisition_id, store_id, category, brand, model, variant,
      color, storage, imei, normalized_imei, serial_number, condition_grade,
      battery_health, inspection, clean_check_status, clean_check_reference,
      activation_lock_removed, data_erased_confirmed, purchase_cost, sale_price,
      status, notes, acquired_by, acquired_at, updated_by
    ) values (
      'USED-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)),
      acquisition_row.id,
      store_row.id,
      item.category,
      'Apple',
      item.model,
      '',
      item.color,
      item.storage,
      item.imei,
      item.imei,
      item.serial_number,
      'Good',
      item.battery_health,
      '{}'::jsonb,
      'Pending',
      '',
      false,
      false,
      item.purchase_cost,
      item.sale_price,
      'inspection',
      'Imported from the Fairfield stock list on 12 September 2026. The condition grade is a placeholder: confirm it on the bench before this goes on sale, because it is what the website tells the customer. No intake photos exist for this purchase. Run the IMEI check, complete the inspection, and add listing photos before marking it ready.',
      import_actor,
      acquisition_row.acquired_at,
      import_actor
    ) returning * into device_row;

    if item.refurb_cost > 0 then
      insert into public.pos_used_device_costs (
        id, device_id, kind, description, amount, staff_name, created_at
      ) values (
        gen_random_uuid(),
        device_row.id,
        'part',
        'Refurbishment recorded on the Fairfield stock list',
        item.refurb_cost,
        import_actor,
        acquisition_row.acquired_at
      );
    end if;

    insert into public.pos_used_device_transactions (
      transaction_code, device_id, store_id, transaction_type, from_status,
      to_status, amount, payment_method, staff_name, counterparty_name,
      counterparty_phone, notes, transaction_payload, created_at
    ) values (
      'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
      device_row.id,
      store_row.id,
      'acquisition',
      null,
      device_row.status,
      item.purchase_cost,
      'Cash',
      import_actor,
      'Not recorded',
      '',
      'Imported from the Fairfield stock list; not bought through the POS',
      jsonb_build_object(
        'acquisition_code', acquisition_row.acquisition_code,
        'source', 'fairfield-stock-spreadsheet-20260912',
        'listed_total_price', item.purchase_cost + item.refurb_cost
      ),
      acquisition_row.acquired_at
    );

    imported_count := imported_count + 1;
  end loop;

  update public.pos_store_shifts
  set status = 'closed', closed_at = now(), closed_by = import_actor
  where shift_code = shift_code_value;

  -- Opening a shift finalises a Today Progress scorecard for it. This one never
  -- traded, so its all-zero card is removed rather than left sitting in the
  -- store's daily figures under the name of an importer.
  delete from public.pos_daily_target_results where shift_code = shift_code_value;

  raise notice 'Fairfield buyback import: % devices loaded', imported_count;
end;
$import$;
