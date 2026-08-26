-- A repair ticket used to be reported as 'paid' the moment any invoice line
-- existed for it. With deposits that is wrong: taking a deposit creates the
-- invoice line while most of the money is still owing, so the board and the
-- ticket modal would both claim the job was settled.
--
-- The ticket now reports 'deposit' while the invoice still has a balance, and
-- carries the numbers the POS needs to show it.

create or replace function public.pos_repair_ticket_payload(ticket_row public.pos_repair_tickets)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', ticket_row.ticket_code,
    'ticket_code', ticket_row.ticket_code,
    'store_id', stores.store_code,
    'storeId', stores.store_code,
    'store_code', stores.store_code,
    'storeCode', stores.store_code,
    'store_name', stores.store_name,
    'title', ticket_row.title,
    'issue', ticket_row.issue,
    'price', ticket_row.price,
    'status', ticket_row.status,
    'deviceInStore', ticket_row.device_in_store,
    'motherboardRepair', ticket_row.motherboard_repair,
    'specialOrder', ticket_row.special_order,
    'customerName', ticket_row.customer_name,
    'customerPhone', ticket_row.customer_phone,
    'customerContact', ticket_row.customer_phone,
    'resolution', ticket_row.resolution,
    'readyForPickupAt', ticket_row.ready_for_pickup_at,
    'closedAt', ticket_row.closed_at,
    'paymentStatus', coalesce(invoice.payment_status, 'unpaid'),
    'invoiceOrderId', invoice.order_code,
    'invoiceNumber', invoice.invoice_number,
    'salesOrderLineId', invoice.sales_order_line_id,
    'orderTotal', invoice.order_total,
    'depositPaid', invoice.amount_paid,
    'balanceDue', invoice.balance_due,
    'createdBy', ticket_row.created_by,
    'updatedBy', ticket_row.updated_by,
    'createdAt', ticket_row.created_at,
    'updatedAt', ticket_row.updated_at,
    'statusUpdatedAt', ticket_row.status_updated_at,
    'intake', ticket_row.intake,
    'activity', ticket_row.activity,
    'comments', ticket_row.comments
  )
  from public.store_locations stores
  left join lateral (
    select
      sales_line.id as sales_order_line_id,
      sales_order.order_code,
      sales_order.invoice_number,
      sales_order.total as order_total,
      sales_order.amount_paid,
      round(greatest(sales_order.total - sales_order.amount_paid, 0), 2) as balance_due,
      case
        when sales_order.payment_status = 'deposit' then 'deposit'
        when coalesce(refunded.amount, 0) <= 0 then 'paid'
        when coalesce(refunded.amount, 0) < sales_line.line_total then 'partially_refunded'
        else 'refunded'
      end as payment_status
    from public.pos_sales_order_lines sales_line
    join public.pos_sales_orders sales_order on sales_order.id = sales_line.sales_order_id
    left join lateral (
      select coalesce(sum(refund_line.amount), 0) as amount
      from public.pos_sales_refund_lines refund_line
      where refund_line.sales_order_line_id = sales_line.id
    ) refunded on true
    where sales_line.repair_ticket_id = ticket_row.id
    limit 1
  ) invoice on true
  where stores.id = ticket_row.store_id;
$$;
