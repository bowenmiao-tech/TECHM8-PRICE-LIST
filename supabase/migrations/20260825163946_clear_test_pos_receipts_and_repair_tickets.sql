-- One-time production cleanup requested before live POS use.
-- The audited snapshot contained 9 receipts and 13 repair tickets. Abort if
-- that scope changes so a newly-created real transaction is never swept up.
do $$
declare
  receipt_count integer;
  repair_ticket_count integer;
  refund_count integer;
  repair_intake_count integer;
  linked_used_device_count integer;
  linked_used_device_transaction_count integer;
begin
  select count(*) into receipt_count from public.pos_sales_orders;
  select count(*) into repair_ticket_count from public.pos_repair_tickets;
  select count(*) into refund_count from public.pos_sales_refunds;
  select count(*) into repair_intake_count from public.repair_intakes;
  select count(*) into linked_used_device_count
  from public.pos_used_devices
  where sold_order_id is not null or sold_order_line_id is not null;
  select count(*) into linked_used_device_transaction_count
  from public.pos_used_device_transactions
  where related_sales_order_id is not null or related_sales_order_line_id is not null;

  if receipt_count <> 9 or repair_ticket_count <> 13
    or refund_count <> 0 or repair_intake_count <> 0 then
    raise exception
      'POS cleanup scope changed: receipts %, tickets %, refunds %, legacy intakes %',
      receipt_count, repair_ticket_count, refund_count, repair_intake_count;
  end if;

  if linked_used_device_count <> 0 or linked_used_device_transaction_count <> 0 then
    raise exception
      'POS cleanup stopped because a used-device record is linked to a receipt';
  end if;
end;
$$;

delete from public.pos_sales_refund_lines;
delete from public.pos_sales_refunds;

-- Order lines and payments use ON DELETE CASCADE from their receipt.
delete from public.pos_sales_orders;
delete from public.pos_repair_tickets;
delete from public.repair_intakes;

-- Reset test invoice sequences so each store's first live receipt starts at 1.
delete from public.pos_store_invoice_counters;

do $$
begin
  if exists (select 1 from public.pos_sales_orders)
    or exists (select 1 from public.pos_sales_order_lines)
    or exists (select 1 from public.pos_sales_order_payments)
    or exists (select 1 from public.pos_sales_refunds)
    or exists (select 1 from public.pos_sales_refund_lines)
    or exists (select 1 from public.pos_repair_tickets)
    or exists (select 1 from public.repair_intakes)
    or exists (select 1 from public.pos_store_invoice_counters) then
    raise exception 'POS test receipt and repair cleanup did not finish';
  end if;
end;
$$;
