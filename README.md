# TECHM8 Staff Portal

Internal staff web portal for TECHM8 quoting, intake, reporting, LCD inventory, and internal troubleshooting guides.

Public company website:
- [https://www.techm8australia.com/](https://www.techm8australia.com/)

This repo is the internal staff site, not the public website.

## Core Entry Points

Front-end staff pages:
- `index.html` - staff portal home
- `quote.html` - repair quote lookup
- `repair_workflow.html` - intake / workflow page
- `daily-report.html` - daily report + weekly LCD count
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
