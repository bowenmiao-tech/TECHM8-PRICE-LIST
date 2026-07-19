# Supabase Edge Functions

## POS Products

`pos-products` is the browser-safe POS product endpoint.

The public POS page calls:

```text
GET https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-products?page=1&limit=500
```

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

## POS Shared State

`pos-shared-state` stores customer records, held carts, and store shifts in the staff/POS database. Every operation validates `x-staff-session`; the tables themselves are not exposed to browser roles.

Browser calls:

```text
GET  .../pos-shared-state?resource=customers&store_code=parkridge
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
