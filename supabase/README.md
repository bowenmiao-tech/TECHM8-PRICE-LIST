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
```

Apply `supabase/migrations/20260711140805_pos_sales_orders.sql` to the staff-auth database, then deploy:

```bash
supabase functions deploy pos-sales-orders --no-verify-jwt
```

Apply `supabase/migrations/20260712122942_unify_pos_invoices_and_repair_workflow.sql` after the invoice-number migration. It adds normalized order lines and payments, repair-ticket invoice links, line-level refunds, Repair Board search, and Invoice History search.

Invoice History can combine its keyword search with `from_date` and `to_date` (`YYYY-MM-DD`). Dates are inclusive and use each order's Brisbane `business_date`; sending the same value for both parameters performs an exact-day search.

Every store has one shared invoice sequence across all sale types. A retail sale, repair sale, or mixed sale consumes the next number from the same store counter. Repair invoices are not stored in a separate invoice table.

Repair tickets require a real customer name and phone at both the browser and database layers. A repair ticket can be linked to only one original sales-order line, preventing duplicate checkout. Refunds create separate immutable refund records and do not alter or delete the original invoice.

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
POS_RECEIPT_COPY_TO (optional; defaults to techm8contact@gmail.com)
```

Deploy:

```bash
supabase functions deploy send-pos-receipt-email --no-verify-jwt
```

Both functions use `x-staff-session` and the same public Supabase headers documented above. Email provider keys remain server-side.
