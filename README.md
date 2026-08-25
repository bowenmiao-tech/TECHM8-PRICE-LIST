# TECHM8 Staff Portal

Internal staff web portal for TECHM8 quoting, intake, reporting, LCD inventory, and internal troubleshooting guides.

Public company website:
- [https://www.techm8australia.com/](https://www.techm8australia.com/)

This repo is the internal staff site, not the public website.

## Core Entry Points

Front-end staff pages:
- `index.html` - staff email login; successful login opens POS
- `pos.html` - Today Progress, store POS, Repair Board, Used Devices, and Invoice History
- `quote.html` - repair quote lookup
- `repair_workflow.html` - intake / workflow page
- `daily-report.html` - daily report + weekly LCD count
- `nl-report.html` - password-protected North Lakes outsourced product sales entry and history
- `staff-documents.html` - staff document templates and report examples
- `problem-solving.html` - internal guide library
- `backup_price_lookup.html` - backup quote page

Admin pages:
- `admin.html` - admin portal entry page; admin login required here first
- `price-admin.html` - price admin
- `daily-report-admin.html` - report review page
- `nl-report-admin.html` - North Lakes product cost, payable, temporary save, and upload admin
- `lcd-inventory-admin.html` - LCD inventory admin
- `schedule-admin.html` - POS roster and staff PIN admin
- `stocktake-admin.html` - temporary per-staff POS stocktake access control

Database / auth:
- `supabase_schema.sql` - source of truth for schema, seed, functions, and RPCs
- `staff-auth.js` - shared front-end auth overlay and session logic
- `supabase-config.js` - Supabase endpoint config

## Authentication Rules

Staff access:
- Staff-facing pages use the individual email/password session flow from `staff-auth.js`.
- Every new staff account starts with the temporary password `123456`.
- First login is blocked until the staff member creates a private account password and four-digit POS PIN.
- The four-digit PIN is verified by the database when a staff name is selected in POS; PINs are never stored in browser storage.

Admin access:
- Admin must enter through `admin.html`.
- `admin.html` itself must require admin login.
- After admin login, admin chooses between:
  - price admin
  - daily report admin
  - LCD inventory admin
- Do not expose admin pages as open pages.

Password rules:
- Staff passwords and POS PINs are individual credentials, not one shared front-end password.
- `price-admin.html` does not change staff credentials.
- Do not expose password hashes or PIN hashes in browser-readable tables or API responses.

## POS System

`pos.html` is the operational POS for Park Ridge, North Lakes, Fairfield, Toowong, and Brassall. Warehouse is not a POS store.

### Current Scope

Completed product-sale flow:
- Live products load through the browser-safe `pos-products` Edge Function.
- Product loading follows the API `has_more` pagination flag, so catalogues larger than 500 rows are loaded completely.
- Product browsing opens on a category grid; staff can enter a category or switch to `All Products` without losing the fixed checkout panel.
- Product cards show one main image, name, sale price, and stock for the selected store.
- Search supports product name, SKU, and barcode.
- The POS always shows these fixed retail groups, including empty groups: `Phone Cases`, `Tablet Cases`, `Screen Protection`, `Cables & Adapters`, `Charging & Power`, `Audio`, `Mounts & Holders`, `Watch Accessories`, `Computer & Gaming`, `Other Electronics`, and `Uncategorized`.
- Each main group opens a fixed second-level category grid before showing products. Empty second-level groups remain visible.
- `Phone Cases > Apple iPhone`, `Samsung Galaxy`, and `Google Pixel` open a model grid before product cards, using the catalogue fit profile so shared-fit cases remain one product group.
- A selected phone model can be filtered by case style (`MagSafe`, clear/back cover, shockproof, wallet, flip, fashion, or other). Global name, SKU, barcode, and compact model searches such as `15pm` or `S24U` bypass the navigation layers and return products directly.
- Existing API categories are mapped into the hierarchy in the POS display layer. Source product records are not renamed or rewritten, and search still includes the original category and subcategory.
- `Computer & Gaming > Keyboards, Mice & Accessories` contains the 41 reviewed keyboards, mice, keyboard/mouse sets, keycaps, and mouse pads. `Other Computer Accessories` contains the 1 webcam and 8 laptop bags/sleeves.
- Bowen can open `Arrange POS` directly to drag and save the display order of main categories, second-level categories, and products. No second login is required; the control is hidden from all other staff and every save is rechecked by the backend.
- POS display order is shared across stores. Store inventory remains independent and is never changed by arranging the catalogue.
- An authorized stocktake mode allows staff to correct the fixed POS main/subcategory and the selected store's quantity without adding the product to cart.
- Stocktake access is disabled by default and is enabled or disabled per active staff login account from `stocktake-admin.html`; the permission follows the authenticated email/session rather than a name selected in the POS.
- The Edge Function rechecks access on every save. Turning access off blocks further saves even if the POS page is still open.
- Store quantity changes write only to `product_store_inventory` for the currently selected store. The product's online total stock is then recalculated from all store inventory rows.
- Stocktake saves are atomic and append an audit row containing staff, store, product, previous/new category, and previous/new quantity.
- Grouped colour/option products share one POS category, but quantity remains independent for the exact selected SKU and store.
- A local product snapshot is displayed immediately when available, while the protected live API refreshes in the background.
- Product images are loaded progressively, and gallery thumbnails are intentionally omitted to keep the POS fast.
- The entire product card adds the item to the cart.
- Zero-stock products are intentionally allowed to be sold.
- Grouped products use one POS/website card and one main image. Sellable colours remain separate product rows with their own SKU, barcode, cost, price, and store stock.
- CTFY, EFM, and OtterBox phone cases use one card per device model and brand. Each card previews its available text options; clicking it opens the exact case images, titles, prices, and store stock while retaining every original SKU as an independent sellable child option. CTFY sales print and email as `CTFY` while the exact SKU remains on the invoice line.
- Clicking a multi-colour product group opens a compact colour selector. Watch bands open a size selector even when a style currently has only one available size; branded case collections open an image selector; ordinary one-variant groups and legacy products still add directly.
- An exact SKU or barcode search bypasses grouping and returns the precise sellable variant.

POS product hierarchy:

| Main category | Second-level categories |
| --- | --- |
| Phone Cases | Apple iPhone; Samsung Galaxy; Google Pixel; Other & Universal |
| Tablet Cases | Apple iPad; Samsung Galaxy Tab; Other & Universal |
| Screen Protection | Phone Screen Protection; Tablet Screen Protection; Watch & Lens Protection |
| Cables & Adapters | Charging & Data Cables; Display & Computer Cables; Network Cables; Audio Cables & Adapters; OTG & Card Readers; Car Connectivity |
| Charging & Power | Wall Chargers; Wireless Chargers; Car Chargers; Laptop Chargers; Power Banks |
| Audio | Wired Earphones & Headphones; Wireless Earbuds & Headphones; Headsets; Speakers; Microphones |
| Mounts & Holders | Vehicle Mounts; Phone & Tablet Stands; Laptop Stands; Monitor Mounts; Selfie Sticks & Live Stands; Wallets, Card Holders & Grips |
| Watch Accessories | Watch Bands; Watch Cases |
| Computer & Gaming | PC Components; Keyboards, Mice & Accessories; Other Computer Accessories; Hubs & Docks; Networking; Storage; Consoles & Controllers; Gaming & Simulation |
| Other Electronics | Drones & Accessories; Personal Fans; Lighting & Clocks; Tracker Cases; Other Electronics |
| Uncategorized | Products display immediately without a second-level category |

Phone and tablet case catalogue reconciliation completed on 19 August 2026:
- The complete RepairDesk export was checked only for `5. Phone Cases` and `6. iPad & Tablet Cases`; every other product category was left unchanged.
- The active phone-case catalogue now contains 1,741 sellable variants under 505 product groups. The previous 915 variants were preserved and 826 missing variants were added.
- The 477 branded variants are consolidated into 105 model-and-brand cards: 267 CTFY variants under 25 cards, 71 EFM variants under 23 cards, and 139 OtterBox variants under 57 cards. Cost, sale price, image, barcode, and per-store stock remain independent on every exact SKU.
- All 283 approved tablet-case variants were already present, so no tablet product was changed. Four duplicate source rows and `TM8-TAB-10064` remain excluded.
- The explicitly removed `iPhone 12 Pro Max EFM Phone Case`, `Universal Cartoon Case`, model-ambiguous `iPhone EFM Phone Case`, and three EFM Aspen rows without a reliable cost are permanently excluded from the import catalogue. AirPods/AirTag accessories remain excluded because they are not phone cases.
- Every added product has a RepairDesk image, a unique SKU/barcode/source ID, a positive cost below retail, POS visibility enabled, online visibility disabled, and zero starting stock with no store-inventory rows.
- The repeatable reconciliation is `supabase/website-migrations/20260819125528_reconcile_missing_phone_cases.sql`; the branded collection regroup is `supabase/website-migrations/20260820093000_regroup_branded_phone_cases.sql`; the CTFY display rename is `supabase/website-migrations/20260820101457_rename_casetify_to_ctfy.sql`; the full reviewed payload and exception workbook are under `outputs/phone-case-catalog-reconciliation-20260819/`.

Computer product catalogue import completed on 12 August 2026:
- The reviewed source contained 183 products. The 41 owner-marked red rows were excluded and the 5 exact existing DualSense products were preserved without changes.
- 137 products were imported: 135 approved new rows plus the 2 owner-confirmed MSI A13 products that remain separate from the existing catalogue items.
- No category records were created, renamed, or removed. Products were assigned to the existing database categories and continue to use the POS display hierarchy above.
- Every imported product is active and visible in POS, hidden from the online storefront, starts with zero stock, and has one working main image.
- The three owner-supplied images are stored in the public `product-images` Supabase Storage bucket.
- The repeatable import source is `supabase/website-migrations/20260812011000_import_repairdesk_computer_products.sql`; its generated payload is `outputs/computer-product-catalog-rebuild/TECHM8_Computer_Products_Import.json`.

Audio, holder, stand, and fan catalogue import completed on 12 August 2026:
- The two reviewed RepairDesk exports contain 49 products. Every row was matched to its current RepairDesk POS main image.
- Forty-three products are now managed by this import. Six exact existing products were preserved and only assigned to `Audio > Wireless Earbuds & Headphones`, so all 49 reviewed products are available in POS.
- Headphone adapters use `Cables & Adapters > Audio Cables & Adapters`; wired and wireless headphones use their corresponding `Audio` subcategories. Phone stands, selfie/live stands, laptop stands, and personal fans use their matching fixed POS subcategories.
- New products are active in POS, hidden online, start at zero total stock, and have no store-inventory rows. Each store therefore begins independently at zero until stocktake updates that store.
- The owner-confirmed costs from 13 August 2026 enabled the final seven products and corrected the existing Remax G6 cost. No reviewed product remains blocked by missing cost.
- The review workbook and confirmed overrides are under `outputs/audio-holder-fan-catalog-20260812/`. The repeatable migrations are `supabase/website-migrations/20260812194702_import_repairdesk_audio_holder_fan_products.sql` and `supabase/website-migrations/20260813001836_finalize_audio_holder_fan_costs.sql`.

Watch band catalogue import completed on 13 August 2026:
- The reviewed RepairDesk export contained 66 rows. Five exact duplicate rows were consolidated, leaving 61 sellable size variants under 35 style-and-colour groups.
- POS shows one card per band style and colour. Clicking the card opens the available `38/40mm` and/or `42/44mm` size choices before adding the exact SKU to the cart.
- Every size variant keeps its own SKU, barcode, cost, price, image, and store inventory. All stores start independently at zero stock, while zero stock remains sellable in POS.
- Products are assigned to `Watch Accessories > Watch Bands`, are visible in POS, and remain hidden from the online storefront. The repeatable import is `supabase/website-migrations/20260813121131_import_repairdesk_watch_band_catalog.sql`.

Miscellaneous accessory catalogue import completed on 14 August 2026:
- The catalogue contains 36 products: 34 from `products (28).xlsx`, plus the Blue and Pink Silicone Card Holder variants recovered from the complete `products (21).xlsx` export. All 36 have a working RepairDesk main image, a unique POS SKU, and a unique internal EAN-13 barcode.
- Seventeen colour variants are grouped into four selectable POS cards: MagSafe Silicone Phone Grip, MagSafe Multi-Wallet, MagSafe Card Wallet, and the complete five-colour Adhesive Silicone Card Holder.
- Twenty-one products use `Mounts & Holders > Wallets, Card Holders & Grips`; the remaining classified products use the matching `Other Electronics` subcategories. This import initially assigns nine products to the top-level `Uncategorized` view; later stocktake corrections may add more. The view opens its products directly without showing a second-level category.
- All products are active in POS, hidden from the online storefront, start at zero total stock, and have no store-inventory rows. Each store therefore remains independently at zero until stocktake updates that store.
- The owner-confirmed zero cost and zero retail values are preserved intentionally. The repeatable generator is `scripts/build-product-28-catalog-import.mjs`; the generated payload and review workbook are under `outputs/product-28-catalog-review-20260813/`; the deployed migrations are `supabase/website-migrations/20260813144142_add_missing_silicone_card_holder_colors.sql` and `supabase/website-migrations/20260814004500_import_repairdesk_misc_accessory_catalog.sql`.

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

Completed second-hand device flow:
- `Used Devices` is a separate POS workspace for both customer buyback and device sale.
- Acquisitions are purchase/intake records and never create negative sales invoices.
- Seller name, phone, address, ID reference, age, ownership, how the device was obtained, declaration, payout method, and staff/store audit are mandatory.
- Device records use their own acquisition, inventory, and immutable transaction-ledger tables.
- IMEI or serial is unique across the device inventory; phones require a 15-digit IMEI.
- Inspection, IMEI status/reference, activation-lock removal, and data-erasure checks gate `Ready for sale`.
- Every acquisition must use the selected store's open shift. Cash and bank-transfer payouts are included in shift reconciliation as paid-out amounts.
- Ready devices can be added to the normal cart as one unique item. The database locks the record during checkout and blocks duplicate sales.
- Used-device sales use the existing store invoice sequence, split payments, receipt, Invoice History, and refund flow.
- A fully refunded device returns to `Inspection` before it can be sold again.

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

Completed Today Progress / Target flow:
- The staff-facing POS Report page is removed. The existing aggregate report RPC remains available for a future management-only page.
- The page is a compact daily scorecard plus the complete Instant Quote flow; unused sales, repair, glass, refund, and bonus panels are no longer shown.
- Each staff-confirmed Google Review earns 5 points. The event is saved centrally with an idempotency key and can only be recorded during the store's open shift.
- A paid invoice earns device-bundle points only when it contains at least one device and one normal product: each device earns 5 points and each accessory earns 5 points. A device sold alone earns 0; refunds reduce the qualifying net quantities.
- An explicit store/date/staff daily point target takes priority. Otherwise a matching monthly target is converted into an adaptive daily target from the points still required and the calendar days remaining, rounded up to the next 5 points.
- The embedded quote uses a cached first display plus a parallel live refresh of all repair-price pages, includes IMEI, S/N, and Apple A-model lookup tools, and opens the POS `Create Repair Ticket` flow with the selected quote prefilled.
- Ticket creation validates the customer already selected in the top-right shared customer field. The selected record must exist and contain a valid phone number before the original three-question ticket modal opens.
- The page refreshes from Supabase on entry, staff/store change, checkout, manual refresh, and every 30 seconds while visible. A labelled local cache is used only as a temporary offline display.
- End Shift writes a finalized per-staff result snapshot. Closed shifts show the frozen result instead of recalculating historical performance.

Completed multi-terminal state:
- Customer records are company-wide and cached locally only for temporary network failure.
- The top-right customer field remains empty until at least two characters are entered, then searches name, email, and phone with tolerant matching instead of listing the full directory.
- New Customer checks the normalized phone number before saving; an existing match can be selected to fill the complete customer record and continue the current sale or repair flow.
- Held carts are shared within the selected store and cached locally until database sync succeeds.
- One open store shift is shared by all terminals at that store.
- Opening cash entered on one terminal is visible to the others.
- The first staff member using a store each Brisbane business day must explicitly Start Shift and confirm opening cash. Refreshes and device restarts resume that same database shift without asking again.
- Close Shift ends the shared store shift. Any shift left open from a prior business date is automatically system-closed at the previous day boundary, so it can never carry into the next morning.
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
- product groups, colour variants, fit profiles, and directional device compatibility in the website product database
- repair tickets and activity
- invoices / sales orders
- invoice lines and split payments
- refunds and refund lines
- receipt email audit fields
- per-store invoice counters
- formal POS report aggregates and database-backed Today Progress targets/results
- company-wide customer directory shared by all active POS stores; home/source store remains historical metadata
- 11,863 canonical RepairDesk customer masters linked to 12,144 protected source records from Toowong, Park Ridge, Fairfield, North Lakes, and Brassall
- per-store held carts
- per-store opening cash, active shift, and end-shift reconciliation
- second-hand seller acquisitions, unique device inventory, status history, and buy/sell ledger
- per-staff stocktake permission, fixed POS category assignments, store-specific stocktake quantities, and stocktake audit history

Browser-local convenience state:
- selected staff/store and local staff PIN/assignment overrides
- offline cache for customers, held carts, shifts, and recent orders
- cached Today Progress payload used only during temporary network failure

Do not use browser-local values as the source of truth for accounting or management reports. Shared records and financial totals must come from the database APIs.

### Supabase Deployment Map

- Static front end: `pos.html` on the website Git deployment.
- Edge Function project: `fwlronvmgqzkleofriis`.
- Staff/POS database project: `abkjbhmifswfexpjkval`.
- `pos-products` proxies the protected internal product API without exposing its API key.
- `pos-products` also checks stocktake permission and atomically saves approved POS category/store-inventory changes.
- `internal-products` returns optional product-group, colour, fit-profile, compatible-device, and assigned POS-category fields while preserving the legacy product response.
- `pos-repair-tickets`, `pos-sales-orders`, `pos-shared-state`, `pos-used-devices`, and `send-pos-receipt-email` validate `x-staff-session` and call staff/POS database RPCs.
- Full endpoint and migration deployment notes are in `supabase/README.md`.

Required POS migrations, in order:
1. `20260711140805_pos_sales_orders.sql`
2. `20260711144825_pos_invoice_numbers.sql`
3. `20260712122942_unify_pos_invoices_and_repair_workflow.sql`
4. `20260713084027_add_invoice_history_date_filters.sql`
5. `20260714103000_add_pos_reports_and_shared_state.sql`
6. `20260717134620_add_used_device_trading.sql`
7. `20260717141622_fix_used_device_shift_integrity.sql`
8. `20260717150100_index_used_device_sales_links.sql`
9. `20260719010220_add_pos_today_progress.sql`
10. `20260719011727_fix_pos_today_progress_category.sql`
11. `20260719013325_fix_pos_today_progress_repair_attribution.sql`
12. `20260719013856_index_pos_daily_target_results_shift_code.sql`
13. `20260812111500_add_pos_stocktake_permissions.sql`
14. `20260820145225_add_staff_email_first_login_credentials.sql`
15. `20260820151527_disable_legacy_shared_staff_password_rpc.sql`
16. `20260820152151_configure_bowen_staff_login.sql`
17. `20260820153840_require_customer_search_query.sql`
18. `20260821010000_make_pos_customers_global.sql`
19. `20260821093757_simplify_staff_roles_and_bind_stocktake_access.sql`
20. `20260823145405_expire_stale_pos_store_shifts.sql`
21. `20260825095329_fix_google_review_event_code_ambiguity.sql`
22. `20260825163946_clear_test_pos_receipts_and_repair_tickets.sql`
23. `20260825163948_enforce_numeric_repair_prices.sql`

Product-project stocktake migration:
- `supabase/website-migrations/20260812112500_add_pos_stocktake_updates.sql`

### Current Limitations And Roadmap

Tablet-case catalogue rollout:
- 287 source variants are active in POS under 67 product groups. Online visibility remains off until the matching storefront grouping code is deployed.
- New SKUs use `TM8-TAB-<source item id>` and new internal EAN-13 barcodes use the reserved `2999` prefix; both ranges were checked against the existing catalogue before import.
- Every store and the online store start at zero stock. Zero stock is informational and does not block POS checkout or online ordering.
- All 287 imported variants now have confirmed costs, unique SKUs, unique barcodes, and a usable variant or group image.
- Product and online inventory are intentionally zero and no imported variant is assigned to a store.
- `Hard Case` and `Bubble Hard Case` cost $15; every `Twist Leather Case` costs $5; every `Z-Fold Case` and `Z-Flip Case` costs $4.
- The 16 owner-confirmed exception costs are stored in `outputs/product-catalog-rebuild/TECHM8_Tablet_Case_Cost_Overrides.json` so future rebuilds retain them. No product remains blocked by missing cost.
- Compatibility is directional from a case fit profile to supported device models. Reverse compatibility is never inferred.
- The confirmed legacy profiles include iPad 9.7-inch Gen 5/6 and Air 1/2, iPad Pro 12.9-inch 2018-2022, and iPad Air 4/5 plus iPad Pro 11-inch 2018-2022.
- `TM8-TAB-10064` and its empty Samsung Tab S9 FE product group were removed because no usable product or group image exists.
- Review workbook and draft import files are under `outputs/product-catalog-rebuild/`.
- POS and public storefront code both understand product groups and colour variants. Keep online visibility off until the storefront change has been deployed, then activate approved groups and variants together. Inventory remains zero until manually adjusted per store or online.

Second-hand device follow-ups:
- add Supabase Storage photo capture for seller ID and device-condition evidence
- add a printable or signed acquisition agreement generated from the saved purchase record
- integrate an approved IMEI/blacklist provider instead of storing only the manual AMTA result reference
- add inter-store device transfer with immutable source/destination events

Optional later integrations:
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
- Anna
- Bonnie
- Bowen
- Fiona
- Jinny
- Joanna Chen

RepairDesk staff details synchronized into `staff_directory` include email, RepairDesk user ID, role, and default store. POS authorization deliberately has only two roles: `techm8contact@gmail.com` (Bowen) is `admin`, and every other account is forced to `staff`. Henry Ang, JANAPHY, and Steven T remain available in historical records but are inactive and are not shown in new staff selectors.

## Daily Report Admin Rules

`daily-report-admin.html` is for review, not staff entry.

North Lakes uses a dedicated outsourced sales flow. Selecting North Lakes and a staff member on
`daily-report.html`, then pressing `Start NL Report`, requires the NL password and opens `nl-report.html`.
The default NL password is `4509`; administrators can change it from `nl-report-admin.html`.

NL sales rules:
- NL sale prices are entered and stored including GST.
- Admin costs are entered excluding GST.
- The system adds 10% GST to the admin cost and uses the GST-inclusive result for the NL payable total.
- Historical lines retain their saved cost and sale price values.
- NL can save a daily draft and submit it; submitted sales lines are read-only.
- Admin has two cost actions: `Save Temporarily` keeps entered ex-GST costs editable, while `Upload`
  requires every product cost and publishes the final GST-inclusive payable amount.
- Temporarily saved costs stay private to admin; NL sees payable costs only after `Upload`.

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
