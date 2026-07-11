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

`pos-sales-orders` saves completed POS sales to the database and returns individual orders for receipt delivery. The browser first records the paid order locally, then calls this endpoint with the same order id. Retries are idempotent.

Browser calls:

```text
POST https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-sales-orders
GET  https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-sales-orders?order_id=POS-...
```

Apply `supabase/migrations/20260711140805_pos_sales_orders.sql` to the staff-auth database, then deploy:

```bash
supabase functions deploy pos-sales-orders --no-verify-jwt
```

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
