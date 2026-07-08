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
