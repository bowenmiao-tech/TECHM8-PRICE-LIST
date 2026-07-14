# TECHM8 Staff Portal

Internal staff web portal for TECHM8 quoting, intake, reporting, LCD inventory, and internal troubleshooting guides.

Public company website:
- [https://www.techm8australia.com/](https://www.techm8australia.com/)

This repo is the internal staff site, not the public website.

## Core Entry Points

Front-end staff pages:
- `index.html` - staff portal home
- `pos.html` - store POS, Repair Board, Invoice History, and POS Reports
- `quote.html` - repair quote lookup
- `repair_workflow.html` - intake / workflow page
- `daily-report.html` - daily report + weekly LCD count
- `staff-documents.html` - staff document templates and report examples
- `problem-solving.html` - internal guide library
- `backup_price_lookup.html` - backup quote page

Admin pages:
- `admin.html` - admin portal entry page; admin login required here first
- `price-admin.html` - price admin
- `daily-report-admin.html` - report review page
- `lcd-inventory-admin.html` - LCD inventory admin

Database / auth:
- `supabase_schema.sql` - source of truth for schema, seed, functions, and RPCs
- `staff-auth.js` - shared front-end auth overlay and session logic
- `supabase-config.js` - Supabase endpoint config

## Authentication Rules

Staff access:
- Staff-facing pages use the shared staff password flow from `staff-auth.js`.
- The login overlay on `index.html` must clearly state this is the internal staff site.
- The login overlay on `index.html` must include a button linking to the public website.

Admin access:
- Admin must enter through `admin.html`.
- `admin.html` itself must require admin login.
- After admin login, admin chooses between:
  - price admin
  - daily report admin
  - LCD inventory admin
- Do not expose admin pages as open pages.

Password rules:
- Keep current password behavior unchanged unless explicitly requested.
- `price-admin.html` keeps the front-end staff password update feature.
- Do not add a general admin password edit UI unless explicitly requested.

## POS System

`pos.html` is the operational POS for Park Ridge, North Lakes, Fairfield, and Toowong. Brassall and Warehouse are not POS stores.

### Current Scope

Completed product-sale flow:
- Live products load through the browser-safe `pos-products` Edge Function.
- Product cards show image, name, sale price, and stock for the selected store.
- Search supports product name, SKU, and barcode.
- Category tabs come from the product API.
- The entire product card adds the item to the cart.
- Zero-stock products are intentionally allowed to be sold.
- Quantity change, cancel, hold, and resume are available.
- Held carts are stored per store and shared between POS terminals.
- Restoring a held cart is atomic, so another terminal cannot restore the same cart again.

Completed checkout flow:
- Cash, Card, Afterpay, CNYpay, and Bank Transfer are supported as recorded payment methods.
- Split payments are supported. Each confirmed payment reduces the remaining balance.
- `Full Payment` assigns the complete remaining balance to the selected method.
- Checkout is complete only after the order is saved to the POS database.
- The cart is retained when database saving fails, so staff can retry safely.
- Repeating the same order ID is idempotent and does not create another invoice.
- Payment methods are recorded only; there is no EFTPOS or payment-provider integration yet.

Completed invoice flow:
- Retail, repair, special-product, and mixed sales share `pos_sales_orders`.
- Each store has its own invoice sequence starting at `1`.
- Invoice numbers are not shared between stores.
- Invoice History is always restricted to the selected store.
- Search supports invoice number, order reference, customer, phone, repair ticket, product, and SKU.
- Date search supports a specific day, date range, today, yesterday, last 7 days, this month, and all dates.
- Refunds are immutable records linked to the original invoice and can be entered per line.
- Original invoice lines are never deleted or overwritten by a refund.

Completed receipt flow:
- Completing payment opens receipt actions after the database save.
- Available actions are `Print Thermal Receipt` and `Email Thermal Receipt` only.
- Printing or emailing is optional; closing the receipt dialog does not undo the sale.
- Thermal printing uses an 80 mm layout and store-specific business details.
- Receipt email is sent by `send-pos-receipt-email` through Resend.
- Email Reply-To and optional CC use the selected store's email address.
- Email success is recorded against the saved order.

Completed POS reporting:
- Reports read saved invoices, normalized lines, split payments, and immutable refunds from the database.
- Filters support selected store, start/end date, shortcut ranges, and optional staff member.
- Summary totals include gross sales, refunds, net sales, GST, invoices, units, average invoice, and refund count.
- Breakdowns include retail/repair/special sales, product category, payments received, refund method, staff, and daily totals.
- Sales use Brisbane `business_date`; refunds use their Brisbane transaction date.
- The Today Target page remains a local incentive panel and is not an accounting report.

Completed multi-terminal state:
- Customer records are shared within the selected store and cached locally for temporary network failure.
- Held carts are shared within the selected store and cached locally until database sync succeeds.
- One open store shift is shared by all terminals at that store.
- Opening cash entered on one terminal is visible to the others.
- All new sales use the shared shift ID, and end-shift reconciliation reloads payment/refund totals from the database before closing.
- Closing a shift is database-authoritative; the local shift is not cleared when database closing fails.

### Repair Board

Repair tickets belong to a store, not to the employee who created them. Every employee viewing the same store sees the same open tickets and has the same Repair Board permissions.

Every repair ticket requires:
- customer name
- customer phone
- store
- device title / model
- issue and quoted price
- current status
- creator/updater audit details

Open Board columns:
- `need_to_order` - Need to order
- `waiting_shipping` - Waiting shipping
- `repairing` - Parts arrived / Repairing
- `waiting_customer_confirmation` - Waiting customer confirmation
- `waiting_pickup` - Waiting pickup
- `over_3_months_uncollected` - Over 3 months uncollected

Repair rules:
- `cancelled` and `returned_unrepaired` are resolutions that remain in Waiting pickup until collected.
- A paid repair is closed and removed from the open Board.
- A paid repair card cannot be added to the cart again.
- A paid repair can only open its invoice or refund flow.
- One repair ticket can be linked to only one original invoice line.
- Board search supports ticket, customer, phone, device, issue, and IMEI/intake content.
- Finished invoices are searched in Invoice History, not in a separate Finished Board column.

### Data Ownership

Database-backed and shared between terminals:
- live product snapshot returned by `pos-products`
- repair tickets and activity
- invoices / sales orders
- invoice lines and split payments
- refunds and refund lines
- receipt email audit fields
- per-store invoice counters
- formal POS report aggregates
- per-store customer directory
- per-store held carts
- per-store opening cash, active shift, and end-shift reconciliation

Browser-local convenience state:
- selected staff/store and local staff PIN/assignment overrides
- offline cache for customers, held carts, shifts, and recent orders
- Today Target amount and incentive progress

Do not use browser-local values as the source of truth for accounting or management reports. Shared records and financial totals must come from the database APIs.

### Supabase Deployment Map

- Static front end: `pos.html` on the website Git deployment.
- Edge Function project: `fwlronvmgqzkleofriis`.
- Staff/POS database project: `abkjbhmifswfexpjkval`.
- `pos-products` proxies the protected internal product API without exposing its API key.
- `pos-repair-tickets`, `pos-sales-orders`, `pos-shared-state`, and `send-pos-receipt-email` validate `x-staff-session` and call staff/POS database RPCs.
- Full endpoint and migration deployment notes are in `supabase/README.md`.

Required POS migrations, in order:
1. `20260711140805_pos_sales_orders.sql`
2. `20260711144825_pos_invoice_numbers.sql`
3. `20260712122942_unify_pos_invoices_and_repair_workflow.sql`
4. `20260713084027_add_invoice_history_date_filters.sql`
5. `20260714103000_add_pos_reports_and_shared_state.sql`

### Current Limitations And Roadmap

Next major module - second-hand device buy/sell:
- Buying a device from a customer must be a separate purchase/intake record, not a negative sales invoice.
- Capture seller name, phone, ID reference, ownership declaration, device model, IMEI/serial, condition checks, grade, photos, offered cost, approved cost, payout method, and staff/store audit.
- Enforce unique IMEI/serial and record blacklist/ownership checks before purchase approval.
- Suggested states: `draft`, `awaiting_check`, `offer_made`, `purchased`, `rejected`, `in_stock`, `sold`, `returned`.
- Once purchased, create one used-device inventory item with its acquisition cost and store location.
- Selling that item uses the existing unified POS invoice and marks the used-device inventory item as sold.

Optional later integrations:
- stock write-back to the product/inventory system
- payment terminal integrations

## Homepage Rules

`index.html` is the internal staff homepage.

Important behavior:
- Customer-facing warning belongs on the password/login overlay, not the post-login homepage body.
- Post-login homepage should focus on staff workflows only.
- Keep official website link available from the login overlay.

## Backup Quote Page Rules

`backup_price_lookup.html` must remain independent.

Allowed dependency:
- It may share the same staff password/login system.

Not allowed:
- It must not depend on Supabase for price lookup data.
- It must not be affected by ongoing changes to main quote logic.

Data source:
- Backup quote page reads local `data.json`
- Apple model lookup reads local `apple_a_model_map.json`

## Daily Report Rules

`daily-report.html` combines:
- daily report submission
- weekly LCD inventory count entry

General report rules:
- A daily report may be submitted even if there are zero repair lines.
- Do not require at least one repair row.
- If a row is present, that row still needs valid field content.

Draft rules:
- Drafts are saved per `store + staff + report_date`.
- Staff can resume saved drafts from the setup area.
- If a real report for the same store/date already exists, stale draft handling should not block normal submitted-report behavior.

Submission UX rules:
- After successful daily report submission, show the success summary screen.
- Success screen should include:
  - repair summary
  - end-of-day reporting summary
  - one random encouragement message from database
  - close button

Encouragement messages:
- Stored in database, not hardcoded in page text.
- Randomly select one on successful daily report submission.

Staff currently seeded in `staff_directory`:
- Andy
- Bonnie
- Bowen
- Fiona
- Henry Ang
- JANAPHY
- Jinny
- Joanna Chen
- Steven T

## Daily Report Admin Rules

`daily-report-admin.html` is for review, not staff entry.

Display rules:
- Hide empty sections.
- Do not show filler messages like `No faulty / broken LCD rows` when the section has no content.
- Compress empty output so each report card stays short.

## LCD Inventory Rules

Live inventory source of truth:
- `lcd_inventory_items.current_qty`

Ways live LCD inventory changes:
- Admin edits inventory rows directly in `lcd-inventory-admin.html`
- Approved LCD usage from daily reports deducts live stock
- Approved weekly LCD count overwrites live stock with counted quantity

Important:
- When weekly LCD count is approved, the new count replaces old live quantity directly.
- Do not protect old values.
- Do not keep stale-page anti-overwrite logic for weekly count.

## Weekly LCD Count Rules

Purpose:
- Weekly count limits submission frequency
- It does not preserve historical live quantities

Cycle rule:
- Weekly LCD count can be submitted once per store per cycle
- Cycle reset time is Saturday `00:00` Brisbane time

Manual reset rule:
- Admin can reset a store's current weekly LCD count task before scheduled reset
- This allows staff to submit a new count immediately for that store

Approval rule:
- Weekly count submission does not change live qty until admin approval
- On approval, counted quantity overwrites live inventory quantity
- Rejection does not change live qty

Status display rule:
- Store sections in LCD admin should show current weekly count status
- Reset button must remain visible alongside status

## LCD Inventory Admin Rules

`lcd-inventory-admin.html` must support:
- add
- edit
- delete
- duplicate
- single-row save
- save all modified rows

Save-all rule:
- `Save All LCD Rows` should only submit rows actually changed
- Do not re-upload every visible row if unchanged

Store section rule:
- Store sections are collapsed by default
- Open only when needed

Visual stock rule:
- `Current Qty` cell color is the full cell background, not just border
- `0` -> soft red
- `1` -> soft yellow
- `2 and above` -> soft green

## LCD Category Rules

Categories are manually controlled in admin. Do not rely on automatic grouping as the final authority.

Allowed categories:
- `iPhone`
- `Samsung`
- `Google Pixel`
- `iPad`
- `Oppo`
- `Other Models`

Important grouping rule:
- `Samsung Galaxy S` and `Note` belong to the same `Samsung` category
- Do not split them into separate visible category groups

Seed / migration rule:
- If category is already manually set correctly, do not overwrite it during later cleanup logic

## Problem Solving Library Rules

`problem-solving.html` is the internal guide library.

Document templates and completed report examples belong in `staff-documents.html`, not `problem-solving.html`.

Guide-card image rules:
- Card images should use the intended local asset
- Do not leave blank placeholders when a specific image has been chosen

Panic log guide rules:
- `guide-iphone-panic-logs.html` uses left-side model navigation and right-side model content
- Images must be attached to the correct model only
- Do not put all panic images into one shared section
- If the linked source page has no usable image, leave that model without images
- Do not substitute another model's image just to fill the space

Current specific panic-log image intent:
- `iPhone 15 / 15 Plus` only uses images from the iPhone 15 page
- `iPhone 15 Pro / Pro Max` only uses images from the iPhone 15 Pro / Pro Max page
- `iPhone 14 Pro / Pro Max` only uses images from the iPhone 14 Pro / Pro Max page

Laptop battery guide rules:
- Use local images, not hotlinked remote images
- Instructions must say to open the report in a web browser
- Do not assume double-click always opens in browser

KMS guide rules:
- KMS guide has its own cover image and tool interface reference
- Keep the local hosted batch download link available

## Quote / Intake Rules

Quote page behavior:
- IMEI lookup and Apple A-model search are staff tools
- S/N lookup button may open an external Samsung lookup page if needed

Workflow behavior:
- Staff can continue from quote into intake/workflow
- Quoted price should remain editable inside workflow

## General Change Rules

When editing this project later:
- Preserve business logic already agreed in this README unless explicitly changed
- Prefer updating `supabase_schema.sql` when a rule affects schema, seed, or RPC logic
- Prefer local hosted assets over unstable external dependencies when possible
- For guide images, use the correct source image for the correct model/page; do not mix them
