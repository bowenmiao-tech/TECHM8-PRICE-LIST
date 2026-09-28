-- A RepairDesk help sentence was imported as an item SKU on some historical invoices.
-- Remove only recognizable placeholder text; keep actual product identifiers.
update public.pos_sales_order_lines
set sku = ''
where sku ~* 'stock[[:space:]-]*keeping[[:space:]]+unit|scannable[[:space:]]+barcode|track[[:space:]]+the[[:space:]]+movement[[:space:]]+of[[:space:]]+inventory';
