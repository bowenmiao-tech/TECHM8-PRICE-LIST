create index if not exists pos_used_devices_sold_order_idx
on public.pos_used_devices (sold_order_id)
where sold_order_id is not null;

create index if not exists pos_used_devices_sold_order_line_idx
on public.pos_used_devices (sold_order_line_id)
where sold_order_line_id is not null;

create index if not exists pos_used_device_transactions_sales_order_idx
on public.pos_used_device_transactions (related_sales_order_id)
where related_sales_order_id is not null;

create index if not exists pos_used_device_transactions_sales_order_line_idx
on public.pos_used_device_transactions (related_sales_order_line_id)
where related_sales_order_line_id is not null;
