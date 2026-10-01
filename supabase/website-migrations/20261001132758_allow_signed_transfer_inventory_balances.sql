-- Product project: POS sales already allow negative physical inventory.
-- Receiving/returning stock must record the actual signed balance, including
-- receipts which only partially cover a deficit. Do not reset any store stock.
alter table public.inventory_movements
  drop constraint if exists inventory_movements_quantity_before_check,
  drop constraint if exists inventory_movements_quantity_after_check;

-- Keep the arithmetic, nonzero delta, movement type, FK and idempotency checks.
-- Physical dispatch availability remains enforced by create_pos_stock_transfer.
