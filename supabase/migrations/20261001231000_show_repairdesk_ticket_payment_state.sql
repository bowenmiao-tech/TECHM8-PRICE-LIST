-- Show original date and reconciled invoice payment state on imported RepairDesk cards.
CREATE OR REPLACE FUNCTION public.pos_repair_ticket_payload(ticket_row pos_repair_tickets)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', ticket_row.ticket_code,
    'ticket_code', ticket_row.ticket_code,
    'store_id', stores.store_code,
    'storeId', stores.store_code,
    'store_code', stores.store_code,
    'storeCode', stores.store_code,
    'store_name', stores.store_name,
    'title', ticket_row.title,
    'cardKind', ticket_row.card_kind,
    'displayLabel', coalesce(ticket_row.display_label, ''),
    'issue', ticket_row.issue,
    'price', ticket_row.price,
    'status', ticket_row.status,
    'boardPosition', coalesce(ticket_row.board_position, 0),
    'deviceInStore', ticket_row.device_in_store,
    'motherboardRepair', ticket_row.motherboard_repair,
    'specialOrder', ticket_row.special_order,
    'customerName', ticket_row.customer_name,
    'customerPhone', ticket_row.customer_phone,
    'customerContact', ticket_row.customer_phone,
    'resolution', ticket_row.resolution,
    'readyForPickupAt', ticket_row.ready_for_pickup_at,
    'closedAt', ticket_row.closed_at,
    'paymentStatus', case
      when invoice_summary.balance_due > 0 then 'deposit'
      when invoice_summary.invoice_count > 0 then 'paid'
      else 'unpaid'
    end,
    'invoiceOrderId', base_invoice.order_code,
    'invoiceNumber', base_invoice.invoice_number,
    'salesOrderLineId', base_invoice.sales_order_line_id,
    'orderTotal', base_invoice.order_total,
    'depositPaid', base_invoice.amount_paid,
    'balanceDue', invoice_summary.balance_due,
    'baseInvoiced', base_invoice.sales_order_line_id is not null,
    'basePrice', base_price.amount,
    'baseJobName', coalesce(nullif(btrim(ticket_row.issue), ''), 'Repair service'),
    'jobs', jobs.rows,
    'invoiceHistory', invoice_summary.rows,
    'unbilledTotal', round(
      case when base_invoice.sales_order_line_id is null then base_price.amount else 0 end
      + jobs.unbilled_total, 2),
    'outstandingTotal', round(
      invoice_summary.balance_due
      + case when base_invoice.sales_order_line_id is null then base_price.amount else 0 end
      + jobs.unbilled_total, 2),
    'hasUnfinishedJobs', jobs.unfinished_count > 0,
    'canClose', (ticket_row.card_kind = 'memo' or base_invoice.sales_order_line_id is not null)
      and jobs.unbilled_count = 0
      and jobs.unfinished_count = 0
      and invoice_summary.balance_due = 0,
    'createdBy', ticket_row.created_by,
    'updatedBy', ticket_row.updated_by,
    'createdAt', ticket_row.created_at,
    'updatedAt', ticket_row.updated_at,
    'statusUpdatedAt', ticket_row.status_updated_at,
    'intake', ticket_row.intake,
    'activity', public.pos_repair_ticket_activity(ticket_row),
    'active', ticket_row.active,
    'comments', ticket_row.comments
  ) || case when ticket_row.intake#>>'{legacy,sourceSystem}' = 'repairdesk' then
    jsonb_build_object(
      'legacySource', 'RepairDesk',
      'createdAt', (ticket_row.intake#>>'{legacy,sourceCreatedAt}')::timestamptz,
      'invoiceNumber', ticket_row.intake#>>'{legacy,invoiceNumbers,0}',
      'paymentStatus', case ticket_row.intake#>>'{legacy,paymentClassification}'
        when 'settled' then 'paid'
        when 'balance_due' then 'deposit'
        else 'unpaid' end,
      'baseInvoiced', ticket_row.intake#>>'{legacy,paymentClassification}' <> 'no_invoice',
      'balanceDue', coalesce((ticket_row.intake#>>'{legacy,invoiceBalance}')::numeric, 0),
      'orderTotal', (ticket_row.intake#>>'{legacy,invoiceTotal}')::numeric,
      'depositPaid', (ticket_row.intake#>>'{legacy,invoicePaid}')::numeric,
      'unbilledTotal', case when ticket_row.intake#>>'{legacy,paymentClassification}' = 'no_invoice'
        then base_price.amount else 0 end,
      'outstandingTotal', case when ticket_row.intake#>>'{legacy,paymentClassification}' = 'no_invoice'
        then base_price.amount else coalesce((ticket_row.intake#>>'{legacy,invoiceBalance}')::numeric, 0) end,
      'canClose', ticket_row.intake#>>'{legacy,paymentClassification}' = 'settled'
    )
  else '{}'::jsonb end
  from public.store_locations stores
  cross join lateral (
    select case
      when btrim(coalesce(ticket_row.price, '')) ~ '^[$]?[0-9]+([.][0-9]{1,2})?$'
        then replace(btrim(ticket_row.price), '$', '')::numeric
      else 0
    end as amount
  ) base_price
  left join lateral (
    select
      sales_line.id as sales_order_line_id,
      sales_order.order_code,
      sales_order.invoice_number,
      sales_order.total as order_total,
      sales_order.amount_paid
    from public.pos_sales_order_lines sales_line
    join public.pos_sales_orders sales_order on sales_order.id = sales_line.sales_order_id
    where sales_line.repair_ticket_id = ticket_row.id
      and sales_line.repair_job_id is null
    order by sales_order.created_at
    limit 1
  ) base_invoice on true
  cross join lateral (
    select
      coalesce(jsonb_agg(jsonb_build_object(
        'id', job.job_code,
        'jobCode', job.job_code,
        'name', job.name,
        'price', job.price,
        'note', job.note,
        'status', job.status,
        'approvalMethod', job.approval_method,
        'approvedByCustomer', job.approved_by_customer,
        'approvedByStaff', job.approved_by_staff,
        'approvedAt', job.approved_at,
        'completedBy', job.completed_by,
        'completedAt', job.completed_at,
        'invoiced', billed.sales_order_line_id is not null,
        'invoiceOrderId', billed.order_code,
        'invoiceNumber', billed.invoice_number,
        'createdBy', job.created_by,
        'createdAt', job.created_at,
        'updatedBy', job.updated_by,
        'updatedAt', job.updated_at
      ) order by job.sort_order, job.created_at, job.id), '[]'::jsonb) as rows,
      coalesce(sum(job.price) filter (
        where job.status <> 'cancelled' and billed.sales_order_line_id is null
      ), 0) as unbilled_total,
      count(*) filter (
        where job.status <> 'cancelled' and billed.sales_order_line_id is null
      ) as unbilled_count,
      count(*) filter (where job.status not in ('completed', 'cancelled')) as unfinished_count
    from public.pos_repair_ticket_jobs job
    left join lateral (
      select sales_line.id as sales_order_line_id, sales_order.order_code, sales_order.invoice_number
      from public.pos_sales_order_lines sales_line
      join public.pos_sales_orders sales_order on sales_order.id = sales_line.sales_order_id
      where sales_line.repair_job_id = job.id
      limit 1
    ) billed on true
    where job.repair_ticket_id = ticket_row.id
  ) jobs
  cross join lateral (
    select
      coalesce(jsonb_agg(jsonb_build_object(
        'orderId', linked.order_code,
        'invoiceNumber', linked.invoice_number,
        'paymentStatus', linked.payment_status,
        'total', linked.total,
        'amountPaid', linked.amount_paid,
        'balanceDue', linked.balance_due,
        'createdAt', linked.created_at,
        'lines', linked.lines
      ) order by linked.created_at desc), '[]'::jsonb) as rows,
      coalesce(sum(linked.balance_due), 0) as balance_due,
      count(*) as invoice_count
    from (
      select
        sales_order.id,
        sales_order.order_code,
        sales_order.invoice_number,
        sales_order.payment_status,
        sales_order.total,
        sales_order.amount_paid,
        round(greatest(sales_order.total - sales_order.amount_paid, 0), 2) as balance_due,
        sales_order.created_at,
        (
          select coalesce(jsonb_agg(jsonb_build_object(
            'name', ticket_line.name,
            'amount', ticket_line.line_total,
            'repairJobId', repair_job.job_code
          ) order by ticket_line.line_number), '[]'::jsonb)
          from public.pos_sales_order_lines ticket_line
          left join public.pos_repair_ticket_jobs repair_job on repair_job.id = ticket_line.repair_job_id
          where ticket_line.sales_order_id = sales_order.id
            and ticket_line.repair_ticket_id = ticket_row.id
        ) as lines
      from public.pos_sales_orders sales_order
      where exists (
        select 1
        from public.pos_sales_order_lines sales_line
        where sales_line.sales_order_id = sales_order.id
          and sales_line.repair_ticket_id = ticket_row.id
      )
    ) linked
  ) invoice_summary
  where stores.id = ticket_row.store_id;
$function$;
