-- Product project: one-off import of the "中澳跟单" Google Sheet into purchase_* tables.
--
-- The data itself is intentionally not kept in this public repository (it holds
-- supplier names, tracking numbers and purchase amounts). It was loaded on
-- 2026-10-02 directly into the database, then rebuilt the same day so that:
--   * same background colour in column I (国际单号) = one international shipment;
--   * hidden history rows 6-876 were imported as closed batches;
--   * rows that share an international number were merged into one batch.
-- All imported rows carry source = 'sheet_import' and source_ref = the sheet row.
select 1;
