-- Keep the existing RPC name for its callers, but base suggestions entirely on
-- repair payments taken on the report date. Card movement or completion alone
-- must never create a daily sales row. The takings helper allocates deposits
-- and mixed-invoice payments to their actual order lines.
create or replace function public.daily_report_completed_repair_suggestions(
  target_store_id bigint,
  target_date date
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with paid_repair_lines as (
    select
      movement.sales_order_id,
      movement.line_id,
      min(movement.transaction_at) as paid_at,
      sum(movement.amount) as amount_today,
      string_agg(distinct movement.staff_name, ', ' order by movement.staff_name) as collector_name
    from public.pos_takings_line_movements(
      array[target_store_id], target_date, target_date
    ) movement
    where movement.event_type = 'sale'
      and movement.line_type = 'repair'
      and movement.line_id is not null
      and movement.amount > 0
      and lower(btrim(coalesce(movement.payment_method, ''))) <> 'store credit'
    group by movement.sales_order_id, movement.line_id
    having sum(movement.amount) > 0
  ), rows_with_signature as (
    select
      'sale-line:' || sales_line.id::text as source_key,
      ticket.ticket_code,
      paid.paid_at,
      coalesce(nullif(btrim(ticket.title), ''), nullif(btrim(sales_line.name), ''), 'Repair') as model_and_color,
      coalesce(nullif(btrim(job.name), ''), nullif(btrim(ticket.issue), ''),
        nullif(btrim(sales_line.name), ''), 'Repair payment') as problem_and_parts_used,
      coalesce(nullif(btrim(job.completed_by), ''), nullif(btrim(ticket.updated_by), ''),
        nullif(btrim(paid.collector_name), ''), '') as tech_name,
      sales_order.invoice_number::text as invoice_number,
      paid.amount_today
    from paid_repair_lines paid
    join public.pos_sales_order_lines sales_line
      on sales_line.id = paid.line_id and sales_line.sales_order_id = paid.sales_order_id
    join public.pos_sales_orders sales_order on sales_order.id = paid.sales_order_id
      and sales_order.store_id = target_store_id
    left join public.pos_repair_tickets ticket on ticket.id = sales_line.repair_ticket_id
    left join public.pos_repair_ticket_jobs job on job.id = sales_line.repair_job_id
  ), signed_rows as (
    select
      row_data.*,
      md5(jsonb_build_array(
        row_data.source_key, row_data.paid_at, row_data.model_and_color,
        row_data.problem_and_parts_used, row_data.tech_name,
        row_data.invoice_number, row_data.amount_today
      )::text) as source_signature
    from rows_with_signature row_data
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'source_key', source_key,
    'source_signature', source_signature,
    'ticket_code', ticket_code,
    'completed_at', paid_at,
    'model_and_color', model_and_color,
    'problem_and_parts_used', problem_and_parts_used,
    'tech_name', tech_name,
    'invoice_number', invoice_number,
    'amount', amount_today::text
  ) order by paid_at, source_key), '[]'::jsonb)
  from signed_rows;
$$;

revoke all on function public.daily_report_completed_repair_suggestions(bigint, date)
  from public, anon, authenticated;
grant execute on function public.daily_report_completed_repair_suggestions(bigint, date)
  to service_role;
