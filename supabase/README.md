# Supabase Edge Functions

## POS Products

`pos-products` is the browser-safe POS product endpoint.

The upstream `internal-products` response also supports grouped catalogue fields:

```text
product_group_code / product_group_name / product_group_image_url
variant_name / variant_color
brand / model / compatibility
fit_profile.code / fit_profile.display_name / fit_profile.compatible_devices
```

Legacy products return these fields as empty values and continue to work unchanged. POS groups colour variants only when `product_group_code` is present.

The public POS page calls:

```text
GET https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-products?page=1&limit=500
```

Stocktake calls use the same endpoint and staff-session headers:

```text
GET https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-products?mode=stocktake-context
PUT https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-products
```

The context call returns the authenticated account's permission and the fixed POS category taxonomy. The `PUT` body contains `store_slug`, `product_id`, `pos_category_id`, and an integer `quantity`; staff identity is always derived from `x-staff-session`.

Required stocktake migrations:

```text
# Staff/POS project abkjbhmifswfexpjkval
supabase/migrations/20260812111500_add_pos_stocktake_permissions.sql
supabase/migrations/20260821093757_simplify_staff_roles_and_bind_stocktake_access.sql

# Product project fwlronvmgqzkleofriis
supabase/website-migrations/20260812112500_add_pos_stocktake_updates.sql
```

Security and data rules:
- All staff permissions begin disabled and are controlled through admin-session RPCs.
- `pos-products` verifies the authenticated staff account's current permission on every save; caller-provided staff names cannot change which account's permission is used.
- The product-project RPC updates the fixed POS category and one exact product/store inventory row in one transaction.
- Grouped variants share the POS category at product-group level; inventory always remains per variant SKU and per store.
- `products.stock_quantity` is recalculated as the sum of all store inventory rows after each save.
- Every successful save appends `pos_stocktake_changes`; browser roles have no direct table access.

Browser headers:

```text
x-staff-session: <staff session token from staff-auth.js>
apikey: <public anon key>
authorization: Bearer <public anon key>
```

The internal products API key stays on the Supabase server as an Edge Function secret.

Required secrets:

```bash
supabase secrets set STAFF_AUTH_SUPABASE_URL=https://abkjbhmifswfexpjkval.supabase.co
supabase secrets set STAFF_AUTH_SUPABASE_ANON_KEY=<staff auth Supabase anon key>
supabase secrets set INTERNAL_PRODUCTS_ENDPOINT=https://fwlronvmgqzkleofriis.supabase.co/functions/v1/internal-products
supabase secrets set INTERNAL_PRODUCTS_API_KEY=<internal products API key>
```

Deploy:

```bash
supabase functions deploy pos-products --no-verify-jwt
```

`--no-verify-jwt` is intentional here because the function verifies the existing staff session token with `verify_staff_session`.

Grouped product catalogue setup belongs to the website/product project `fwlronvmgqzkleofriis`:

```text
supabase/website-migrations/20260805023000_add_grouped_product_catalog.sql
supabase/website-migrations/20260805024500_index_grouped_product_compatibility.sql
```

The migrations add product groups, fit profiles, directional device compatibility, and variant/source fields without changing existing product visibility. New imported catalogue rows must begin hidden with zero product stock and no store-inventory rows. Zero stock is informational and does not block POS checkout or online ordering.

The current tablet-case catalogue contains 283 active products. Four duplicate RepairDesk source rows and `TM8-TAB-10064` are deliberately excluded. All approved variants are active and visible in POS; online visibility remains off until the matching public-storefront grouping change is deployed. All Twist Leather Cases cost $5, all Z-Fold and Z-Flip Cases cost $4, Hard and Bubble Hard Cases cost $15, and the 16 owner-confirmed exception costs are persisted in `outputs/product-catalog-rebuild/TECHM8_Tablet_Case_Cost_Overrides.json`. No imported product remains blocked by missing cost.

The complete phone-case reconciliation is stored in:

```text
supabase/website-migrations/20260819125528_reconcile_missing_phone_cases.sql
supabase/website-migrations/20260820093000_regroup_branded_phone_cases.sql
supabase/website-migrations/20260820101457_rename_casetify_to_ctfy.sql
outputs/phone-case-catalog-reconciliation-20260819/TECHM8_Phone_Cases_Import.json
outputs/phone-case-catalog-reconciliation-20260819/TECHM8_Phone_Cases_Final_Review.xlsx
```

It preserves the previous 915 phone-case variants and adds 826 missing variants, for 1,741 active POS variants under 505 product groups. The branded regroup keeps 477 exact SKUs independent while presenting them as 105 model-and-brand cards: 25 CTFY, 23 EFM, and 57 OtterBox groups. Each child retains its own cost, sale price, image, barcode, and store inventory. CTFY card titles and receipts use the short `CTFY` label. All added products use RepairDesk images, remain hidden online, and start with zero product stock and no store-inventory rows. The two previously removed products, the model-ambiguous `iPhone EFM Phone Case`, and the three EFM Aspen rows without a reliable cost are permanently excluded from the import catalogue. AirPods/AirTag accessories and duplicate source rows also remain excluded.

Deploy the product-project API after changing fields returned to POS:

```bash
supabase functions deploy internal-products --no-verify-jwt
```

The computer-product catalogue import is stored in:

```text
supabase/website-migrations/20260812011000_import_repairdesk_computer_products.sql
outputs/computer-product-catalog-rebuild/TECHM8_Computer_Products_Import.json
```

It imports 137 owner-approved products into existing categories only. Forty-one red review rows are excluded, five exact DualSense products remain untouched, and the two owner-confirmed MSI A13 products are retained as separate new records. All imported rows are active in POS, hidden online, start at zero stock, and have one validated main image. The migration rejects category, SKU, or source-identity conflicts and validates the full catalogue before committing.

The audio, holder, stand, and fan catalogue import is stored in:

```text
supabase/website-migrations/20260812194702_import_repairdesk_audio_holder_fan_products.sql
outputs/audio-holder-fan-catalog-20260812/TECHM8_Audio_Holder_Fan_Import.json
outputs/audio-holder-fan-catalog-20260812/TECHM8_Audio_Holder_Fan_Import_Review.xlsx
```

It reviews 49 RepairDesk products and validates one current RepairDesk POS image for every row. The first migration imports 36 complete new products while preserving six exact existing products and assigning their fixed POS category. The owner-confirmed follow-up is stored in `20260813001836_finalize_audio_holder_fan_costs.sql`; it imports the final seven products and corrects the existing Remax G6 cost. All 49 reviewed products are now available in POS, and none remains blocked by missing cost. Imported products are POS-visible, online-hidden, and start with zero product stock and no store-inventory rows, so every store remains independently at zero until its own stocktake update.

## POS Repair Tickets

`pos-repair-tickets` is the browser-safe Repair Board endpoint. Repair tickets belong to a store, not to the staff member who created them. Staff identity is kept as the creator/updater/activity actor.

Browser calls:

```text
GET https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-repair-tickets?store_code=parkridge
PUT https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-repair-tickets
DELETE https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-repair-tickets?ticket_code=RPR-...&staff_name=Andy
```

Browser headers:

```text
x-staff-session: <staff session token from staff-auth.js>
apikey: <public anon key>
authorization: Bearer <public anon key>
```

Database setup:

```bash
# Apply the pos_repair_tickets table and RPCs from supabase_schema.sql first.
```

Deploy:

```bash
supabase functions deploy pos-repair-tickets --no-verify-jwt
```

`--no-verify-jwt` is intentional here because the function verifies the existing staff session token through the database RPCs.

## POS Sales Orders

`pos-sales-orders` is the single invoice API for retail products, repairs, special items, and mixed baskets. Checkout must be saved to the database before the cart is cleared. Retries with the same order id are idempotent.

Browser calls:

```text
POST https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-sales-orders
GET  https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-sales-orders?order_id=POS-...
GET  https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-sales-orders?store_code=northlakes&q=customer&from_date=2026-07-01&to_date=2026-07-13
PUT  https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-sales-orders
GET  https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-sales-orders?mode=report&store_code=northlakes&from_date=2026-07-01&to_date=2026-07-14&staff_name=Andy
GET  https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-sales-orders?mode=today-progress&store_code=northlakes&staff_name=Andy
```

Apply `supabase/migrations/20260711140805_pos_sales_orders.sql` to the staff-auth database, then deploy:

```bash
supabase functions deploy pos-sales-orders --no-verify-jwt
```

Apply `supabase/migrations/20260712122942_unify_pos_invoices_and_repair_workflow.sql` after the invoice-number migration. It adds normalized order lines and payments, repair-ticket invoice links, line-level refunds, Repair Board search, and Invoice History search.

Invoice History can combine its keyword search with `from_date` and `to_date` (`YYYY-MM-DD`). Dates are inclusive and use each order's Brisbane `business_date`; sending the same value for both parameters performs an exact-day search.

Every store has one shared invoice sequence across all sale types. A retail sale, repair sale, or mixed sale consumes the next number from the same store counter. Repair invoices are not stored in a separate invoice table.

Repair tickets require a real customer name and phone at both the browser and database layers. A repair ticket can be linked to only one original sales-order line, preventing duplicate checkout. Refunds create separate immutable refund records and do not alter or delete the original invoice.

Apply `supabase/migrations/20260714103000_add_pos_reports_and_shared_state.sql` after the invoice date-filter migration. Report mode calls `get_pos_sales_report` and returns database totals for sales, refunds, GST, invoice count, units, average invoice, sale type, category, payment method, staff, and day.

The staff POS does not expose the report page. `mode=report` and `get_pos_sales_report` are retained as backend support for a future management-only reporting surface.

Apply the Today Progress migrations after the used-device migrations:

```text
20260719010220_add_pos_today_progress.sql
20260719011727_fix_pos_today_progress_category.sql
20260719013325_fix_pos_today_progress_repair_attribution.sql
20260719013856_index_pos_daily_target_results_shift_code.sql
20260820135124_redesign_daily_scorecard.sql
```

`mode=today-progress` calls `get_pos_today_progress` and requires `store_code` and `staff_name`; `business_date` is optional and defaults to the current Brisbane date. It returns:

- Google Review count and points (5 points per staff-confirmed review)
- qualifying device-bundle orders, net device/accessory quantities, and points (5 per device plus 5 per accessory; device-only sales score 0)
- the active daily point target and its source: an explicit daily override, an adaptive monthly-target calculation, a staff/store default, or the system default
- points earned and points remaining for the day
- `projected` status during an open shift or a frozen `finalized` result after End Shift

`pos_daily_targets` stores store/date/staff daily overrides, `pos_monthly_targets` stores monthly point goals, `pos_google_review_events` stores the manual review confirmations, and `pos_daily_target_results` stores immutable operational snapshots generated when a store shift closes. All tables are protected by RLS and are not exposed directly to browser roles; staff access is through the session-validating RPC and Edge Function only.

Repair completion is attributed to the employee recorded in the ticket activity that moved the job to Waiting pickup. A later checkout by another employee does not transfer the repair credit; `updated_by` is used only as a fallback for older tickets without status activity.

## POS Shared State

`pos-shared-state` stores customer records, held carts, and store shifts in the staff/POS database. Every operation validates `x-staff-session`; the tables themselves are not exposed to browser roles.

Customer records are company-wide rather than store-owned. `store_id` records the home or creation store, while every active POS store can search the same customer master by name, phone, email, company, POS customer ID, or original RepairDesk customer code. The browser requests a small result set as the employee types instead of preloading the full customer table.

RepairDesk customer imports preserve each original source record in `pos_customer_sources`, including its source store and source customer code. This source table is service-role only; sensitive fields such as driving licence details are never included in the browser customer payload. Brassall customer history can therefore remain searchable without adding Brassall as an active POS store.

Build a repeatable import from the RepairDesk customer workbook with:

```text
node scripts/build-repairdesk-customer-import.mjs <customers.xlsx> <temporary-output-directory>
```

The importer removes only identical duplicate source records, merges canonical records only when normalized name plus phone (or name plus email) match, and keeps every source row for later invoice reconciliation. Generated SQL contains customer personal information and must remain in a temporary local directory; do not commit it to Git.

Browser calls:

```text
GET  .../pos-shared-state?resource=customers&store_code=parkridge&q=customer&limit=80
POST .../pos-shared-state  resource=customer, action=save
GET  .../pos-shared-state?resource=holds&store_code=parkridge
POST .../pos-shared-state  resource=hold, action=save|restore
GET  .../pos-shared-state?resource=shift&store_code=parkridge
GET  .../pos-shared-state?resource=shift-totals&store_code=parkridge&shift_id=SHIFT-...
POST .../pos-shared-state  resource=shift, action=open|opening|close
```

Shift rules:
- There is at most one open shift per store.
- Every terminal opening the same store receives the same shift ID.
- Opening cash is written once and then reused by other terminals.
- Shift payment totals combine all invoices with that shift ID, subtract store refunds recorded during the shift window, and subtract used-device acquisition payouts assigned to the shift.
- End shift writes system totals, actual totals, differences, closing cash count, closing staff, and closing timestamp.

Deploy:

```bash
supabase functions deploy pos-shared-state --no-verify-jwt
```

## POS Used Devices

`pos-used-devices` is the browser-safe API for buying, inspecting, listing, and tracing unique second-hand devices. Seller acquisitions and device inventory are stored separately from product stock; selling a ready device still uses the unified `pos-sales-orders` checkout and invoice sequence.

Browser calls:

```text
GET  .../pos-used-devices?resource=devices&store_code=northlakes&q=iphone&status=ready_for_sale
GET  .../pos-used-devices?resource=transactions&store_code=northlakes&q=USED-...
POST .../pos-used-devices  action=acquire
POST .../pos-used-devices  action=update
```

Rules enforced by the database:
- Every acquisition belongs to the selected store and its currently open shift.
- Seller identity, ownership declaration, acquisition history, payout, device identifier, and audit fields are required.
- IMEI and serial identifiers are unique; phone IMEIs contain 15 digits.
- A device cannot be marked ready until its inspection passes, IMEI result is recorded, activation lock is removed, and data erasure is confirmed.
- Checkout locks the unique device row, validates store/status/current price, marks it sold, and appends a sale ledger event.
- A full invoice-line refund returns the device to inspection and appends a refund-return event.

Apply these migrations after POS shared state:

```text
20260717134620_add_used_device_trading.sql
20260717141622_fix_used_device_shift_integrity.sql
20260717150100_index_used_device_sales_links.sql
```

Deploy:

```bash
supabase functions deploy pos-used-devices --no-verify-jwt
```

`--no-verify-jwt` is intentional because the Edge Function and database RPCs validate the existing `x-staff-session` token. Browser requests must also include the public anon `apikey` and bearer authorization headers documented above.

### Invoice Numbers

`invoice_number` is a positive `bigint` allocated independently for each store. Park Ridge, North Lakes, Fairfield, and Toowong each begin at `1`. The database counter update and order insert run in the same transaction, and repeating the same order save keeps its original invoice number.

Apply `supabase/migrations/20260711144825_pos_invoice_numbers.sql` after the sales-order migration.

Historical invoices can be inserted with their original store and invoice number. After a historical import, reseed every store counter through a privileged database connection:

```sql
select public.reseed_pos_store_invoice_counters();
```

The function returns the next invoice number for each store after its imported maximum. It is executable only by `service_role` and database administrators.

Apply `supabase/migrations/20260831194500_add_repairdesk_historical_sales_import.sql` for the controlled RepairDesk importer. Its `import_repairdesk_sales_batch(jsonb)` RPC is restricted to `service_role`, accepts only TechM8 Toowong RepairDesk invoices `1`-`3286`, is idempotent by store and invoice number, preserves historical negative refunds, and never updates inventory or assigns an active shift.

Build the import batches from the downloaded RepairDesk invoice and item-wise-sales exports with:

```text
python scripts/build-repairdesk-toowong-invoice-import.py --invoice-export <invoices.xlsx> --item-report <item-wise-sales.csv> --output-dir <temporary-output-directory>
```

The completed Toowong import contains 3,282 invoices, 4,236 lines, and 3,280 payments. RepairDesk does not contain invoice numbers `300`, `314`, `1035`, or `2114`. The store counter is `3286`, making `3287` the next live invoice. Generated batches contain customer data and must remain outside version control.

## POS Receipt Email

`send-pos-receipt-email` loads an already-saved POS order, renders the store-specific email receipt, sends it through Resend, and records the successful delivery on the order.

The function uses the existing booking email secrets when dedicated POS secrets are not set:

```text
RESEND_API_KEY or RESEND_API_KEY_BOOKING
POS_RECEIPT_FROM or BOOKING_FROM_EMAIL
```

The selected store profile supplies the email Reply-To address. When staff select `Send a copy to the store`, the same store email is used as CC. Store addresses are defined in both `pos.html` and `send-pos-receipt-email/index.ts`; keep the two maps synchronized.

Current store receipt emails:

```text
Park Ridge:  techm8.parkridge@gmail.com
North Lakes: techm8.northlakes@gmail.com
Fairfield:   techm8.fairfield@gmail.com
Toowong:     techm8.toowong@gmail.com
```

Deploy:

```bash
supabase functions deploy send-pos-receipt-email --no-verify-jwt
```

Both functions use `x-staff-session` and the same public Supabase headers documented above. Email provider keys remain server-side.
