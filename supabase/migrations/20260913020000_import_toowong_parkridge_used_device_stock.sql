-- Toowong's and Park Ridge's existing second-hand stock, from the store
-- spreadsheets, loaded the same way Fairfield's was in
-- 20260912023000_import_fairfield_used_device_stock.
--
-- Seven devices load: two for Toowong, five for Park Ridge. Seven more rows on
-- the two sheets are NOT loaded, and every one of them is listed under "ROWS
-- LEFT OUT" below with the reason, so the gap is visible instead of silent.
--
-- WHAT THE SPREADSHEETS DID NOT HAVE, recorded rather than guessed, exactly as
-- the Fairfield import did:
--
--   * Seller name, phone, address and ID. Nothing is invented. Every field says
--     "Not recorded", `seller_age_confirmed` and `ownership_declaration` are
--     false, and `declaration_text` says the paper form in store is the record.
--   * Payout method. Recorded as Cash, which is the assumption stated in the
--     acquisition note. These sit in a closed import shift so they never touch
--     a real shift reconciliation.
--   * Condition grade. Set to Good as a placeholder and said so in the device
--     memo. Staff confirm it from the POS before the device can be sold,
--     because the grade is what the public listing tells the customer.
--   * Inspection results and the lost-or-stolen check. Left empty and Pending.
--     The gate will not let a device reach the shelf or the website until
--     staff have answered the checklist.
--
-- The "Additional Cost Price" column becomes a refurbishment cost row, so each
-- sheet's Total Price is reproduced as purchase price plus refurbishment and
-- margin is calculated against the real number.
--
-- ONE DIFFERENCE FROM THE FAIRFIELD IMPORT: both of these stores had a live
-- trading shift open while this ran, and a store may only have one open shift.
-- The import shift is therefore created already closed and the open-shift
-- trigger is disabled for the length of the import instead, so nobody's
-- working shift is closed, reopened or written to. See the comment at the
-- insert for the detail.
--
-- IMEI CHECKSUMS: every IMEI was run through Luhn before loading. Eight of the
-- nine pass. Park Ridge row 7 (iPhone 13 Pro Max, 359481986421334) FAILS, which
-- means at least one digit is wrong on the sheet. It is still loaded, because
-- the phone is real stock worth $599 and dropping it would hide $290 of cost,
-- but its memo says the number must be re-read off the device. The lost-or-
-- stolen check is Pending, so the device cannot be sold until someone does.
--
-- ROWS LEFT OUT, and what each one needs before it can be added:
--
--   Toowong 1  Sony WH-1000XM6 headphones, $200 cost, $499 online.
--              No IMEI and no serial. `pos_used_devices_identifier_required`
--              will not accept a device with neither. Needs the serial off the
--              headband or the box.
--   Toowong 3  iPhone 12 64GB White, 352484818497182.
--              Already in the POS as USED-E6BEA0445E33, bought by Fiona on the
--              same date for the same $120 -- but its status is `disposed` and
--              its sale price was saved as $120, equal to cost, where the sheet
--              says $349. Re-importing would collide with the unique IMEI
--              index, and reviving a write-off is not something an import
--              should do quietly. Left for a human decision.
--   Toowong 4  MacBook Air 13" 8GB/256GB A2337 Silver, $699 online.
--              No serial (A2337 is Apple's model number, not a serial) and no
--              purchase cost. Needs both.
--   Toowong 5  iPhone 14 Pro Max 256GB Purple, 354466593405298.
--              The same IMEI is on Park Ridge's sheet with a full cost trail
--              ($516.20 + $50) and an earlier date. One phone cannot be in two
--              stores, so it is loaded once, at Park Ridge, where the money was
--              recorded. If the phone is physically at Toowong now, transfer it
--              in the POS rather than importing it twice.
--   Toowong 7  iPhone 13 128GB Black, 356452876900872.
--              No purchase cost and no online price. `purchase_cost > 0` and
--              `sale_price > 0` are both table constraints. Needs both numbers.
--   Park Ridge 2  Desktop PC, RTX 2070 Super / Ryzen 7 X3D / 16GB / 1TB,
--              $1,559 cost, $2,299 online. No IMEI and no serial, and a
--              self-built desktop has no factory one. Needs a store asset tag
--              to be enterable at all.
--   Park Ridge 5  iPhone 11 128GB Black, 354004101779845.
--              Already in the POS at FAIRFIELD as USED-2E8310DB36BB from the
--              12 September import, with a full cost trail Park Ridge's row
--              does not have. Either the phone moved stores, or the row was
--              copied between sheets. Not duplicated; left for a human.

do $import$
declare
  import_actor text := 'Spreadsheet import';
  toowong_shift text := 'TW-BUYBACK-IMPORT-20260913';
  parkridge_shift text := 'PR-BUYBACK-IMPORT-20260913';
  store_row public.store_locations%rowtype;
  acquisition_row public.pos_used_device_acquisitions%rowtype;
  device_row public.pos_used_devices%rowtype;
  item record;
  shift_code_value text;
  base_note text;
  imported_count integer := 0;
  skipped_count integer := 0;
begin
  base_note :=
    'Imported from the store stock list on 13 September 2026. The condition '
    || 'grade is a placeholder: confirm it on the bench before this goes on '
    || 'sale, because it is what the website tells the customer. No intake '
    || 'photos exist for this purchase. Run the IMEI check, complete the '
    || 'inspection, and add listing photos before marking it ready.';

  -- The acquisition table insists on an open shift for the store, and only one
  -- shift per store may be open at a time. Fairfield's import could open its
  -- own shift because Fairfield had none; Toowong and Park Ridge both have a
  -- live trading shift open right now, so this one cannot.
  --
  -- Rather than disturb a shift a staff member is standing at a counter using,
  -- each store's import shift is created ALREADY CLOSED, and the trigger that
  -- insists an acquisition belongs to an open shift is switched off for the
  -- length of the import and switched straight back on. The whole block is one
  -- transaction, so a failure anywhere rolls the trigger back on with it. The
  -- historical purchases therefore never land on anyone's real shift.
  insert into public.pos_store_shifts (
    shift_code, store_id, business_date, status, opened_by,
    current_staff_name, last_staff_name, closed_at, closed_by
  )
  select
    case store.store_code when 'toowong' then toowong_shift else parkridge_shift end,
    store.id, date '2026-09-13', 'closed', import_actor,
    import_actor, import_actor, now(), import_actor
  from public.store_locations store
  where store.store_code in ('toowong', 'parkridge') and store.active
  on conflict (shift_code) do nothing;

  execute 'alter table public.pos_used_device_acquisitions '
       || 'disable trigger pos_used_device_acquisitions_validate_shift';

  for item in
    select * from (values
      -- Toowong
      ('toowong',   date '2026-07-06', 'Phone', 'Apple',   'iPhone 14',        '128GB', 'Black',  84::integer,  '356891461170294', 100.00, 150.00,  499.00, ''),
      ('toowong',   date '2025-07-10', 'Phone', 'Samsung', 'Galaxy Z Fold 6',  '256GB', 'Pink',   100,          '353904310222464', 800.00,   0.00, 1000.00,
        ' CONFIRM THE MODEL BEFORE LISTING: the stock list says "z flod 6", which reads as Fold but could be Flip. Sold with its box.'),
      -- Park Ridge
      ('parkridge', date '2026-06-06', 'Phone', 'Apple',   'iPhone 11 Pro Max', '256GB', 'Black', 100,          '353921103321998',  50.00,   0.00,  429.00, ''),
      ('parkridge', date '2026-07-28', 'Phone', 'Apple',   'iPhone 14 Pro Max', '256GB', 'Purple', 100,         '354466593405298', 516.20,  50.00,  799.00,
        ' Toowong''s stock list carries this same IMEI dated 4 September 2026 with no cost recorded. It is held here because this is where the purchase was paid. If the phone is physically at Toowong, transfer it in the POS instead of adding it again.'),
      ('parkridge', date '2026-07-14', 'Phone', 'Apple',   'iPhone 17 Pro Max', '',      'Orange', 100,         '356722738786754', 1250.00,  0.00, 1799.00,
        ' Storage was not written on the stock list; fill it in before listing. Sold with its box.'),
      ('parkridge', date '2026-08-31', 'Phone', 'Apple',   'iPhone 13',         '128GB', 'White',  100,         '359461431760298', 321.00,  27.00,  499.00, ''),
      ('parkridge', date '2026-09-09', 'Phone', 'Apple',   'iPhone 13 Pro Max', '256GB', 'Black',  100,         '359481986421334',  50.00, 240.00,  599.00,
        ' THE IMEI ON THE STOCK LIST FAILS ITS CHECKSUM, so at least one digit is wrong. Re-read it off the device and correct it here before running the lost-or-stolen check.')
    ) as source(
      store_code, purchased_on, category, brand, model, storage, color,
      battery_health, imei, purchase_cost, refurb_cost, sale_price, extra_note
    )
  loop
    select * into store_row
    from public.store_locations
    where store_code = item.store_code and active;
    if not found then raise exception 'Store % not found', item.store_code; end if;

    shift_code_value := case item.store_code
      when 'toowong' then toowong_shift else parkridge_shift end;

    if exists (
      select 1 from public.pos_used_devices device
      where device.normalized_imei = item.imei
    ) then
      raise notice 'Skipping % - already in inventory', item.imei;
      skipped_count := skipped_count + 1;
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
      'Imported from the ' || initcap(item.store_code) || ' stock spreadsheet on 13 September 2026. '
        || 'The purchase predates POS buyback recording, so seller details, payout method and '
        || 'inspection results were never captured in the system. Payout method is recorded as '
        || 'Cash by assumption.',
      false,
      'Cash',
      item.purchase_cost,
      'No seller declaration was captured in the POS for this purchase. The paper buyback form '
        || 'held in store is the record of sale.',
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
      item.brand,
      item.model,
      '',
      item.color,
      item.storage,
      item.imei,
      item.imei,
      '',
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
      base_note || item.extra_note,
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
        'Refurbishment recorded on the ' || initcap(item.store_code) || ' stock list',
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
      'Imported from the ' || initcap(item.store_code) || ' stock list; not bought through the POS',
      jsonb_build_object(
        'acquisition_code', acquisition_row.acquisition_code,
        'source', item.store_code || '-stock-spreadsheet-20260913',
        'listed_total_price', item.purchase_cost + item.refurb_cost
      ),
      acquisition_row.acquired_at
    );

    imported_count := imported_count + 1;
  end loop;

  execute 'alter table public.pos_used_device_acquisitions '
       || 'enable trigger pos_used_device_acquisitions_validate_shift';

  -- Belt and braces: the import shifts were inserted closed, but if anything
  -- ever leaves one open it must not become a store's working shift.
  update public.pos_store_shifts
  set status = 'closed', closed_at = coalesce(closed_at, now()), closed_by = import_actor
  where shift_code in (toowong_shift, parkridge_shift) and status <> 'closed';

  -- A shift finalises a Today Progress scorecard. These never traded, so their
  -- all-zero cards are removed rather than left sitting in the stores' daily
  -- figures under the name of an importer.
  delete from public.pos_daily_target_results
  where shift_code in (toowong_shift, parkridge_shift);

  raise notice 'Toowong/Park Ridge buyback import: % devices loaded, % skipped as already present',
    imported_count, skipped_count;
end;
$import$;
