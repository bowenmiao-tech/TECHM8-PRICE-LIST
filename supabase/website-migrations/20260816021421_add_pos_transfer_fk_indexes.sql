create index if not exists inventory_movements_receipt_idx
  on public.inventory_movements (receipt_id)
  where receipt_id is not null;

create index if not exists inventory_movements_store_idx
  on public.inventory_movements (store_id, created_at desc);

create index if not exists inventory_movements_transfer_item_idx
  on public.inventory_movements (transfer_item_id, created_at desc);

create index if not exists stock_transfer_photos_receipt_id_idx
  on public.stock_transfer_photos (receipt_id)
  where receipt_id is not null;
