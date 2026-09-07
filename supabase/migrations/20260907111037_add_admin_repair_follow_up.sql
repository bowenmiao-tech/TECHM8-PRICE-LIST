-- One management view of every open repair across all active stores.
--
-- This is intentionally a small, read-only payload. It exposes the contact,
-- repair and payment fields needed for ordering parts and following customers,
-- but never returns the intake password, unlock pattern, photos or signatures.

create or replace function public.get_admin_repair_follow_up(session_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  report_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;

  with active_stores as materialized (
    select
      store.id,
      store.store_code,
      store.store_name,
      store.sort_order
    from public.store_locations store
    where store.active = true
      and store.store_code <> 'warehouse'
  ),
  active_tickets as materialized (
    select ticket.*
    from public.pos_repair_tickets ticket
    join active_stores store on store.id = ticket.store_id
    where ticket.active = true
      and ticket.closed_at is null
      and ticket.status <> 'finished'
  ),
  job_summary as materialized (
    select
      job.repair_ticket_id,
      count(*) filter (where job.status <> 'cancelled')::integer as job_count,
      count(*) filter (
        where job.status not in ('completed', 'cancelled')
      )::integer as unfinished_job_count,
      coalesce(jsonb_agg(jsonb_build_object(
        'name', job.name,
        'note', job.note,
        'status', job.status,
        'price', job.price
      ) order by job.sort_order, job.created_at) filter (
        where job.status <> 'cancelled'
      ), '[]'::jsonb) as jobs
    from public.pos_repair_ticket_jobs job
    join active_tickets ticket on ticket.id = job.repair_ticket_id
    group by job.repair_ticket_id
  ),
  linked_orders as materialized (
    select distinct
      sales_line.repair_ticket_id,
      sales_order.id,
      sales_order.payment_status,
      sales_order.total,
      sales_order.amount_paid
    from public.pos_sales_order_lines sales_line
    join public.pos_sales_orders sales_order
      on sales_order.id = sales_line.sales_order_id
    join active_tickets ticket
      on ticket.id = sales_line.repair_ticket_id
  ),
  payment_summary as materialized (
    select
      linked_order.repair_ticket_id,
      count(*)::integer as invoice_count,
      round(sum(greatest(linked_order.total - linked_order.amount_paid, 0)), 2) as balance_due
    from linked_orders linked_order
    group by linked_order.repair_ticket_id
  ),
  ticket_rows as materialized (
    select
      ticket.id,
      ticket.ticket_code,
      store.store_code,
      store.store_name,
      store.sort_order,
      coalesce(ticket.display_label, '') as display_label,
      ticket.title,
      ticket.issue,
      ticket.price,
      ticket.status,
      ticket.special_order,
      ticket.motherboard_repair,
      ticket.device_in_store,
      ticket.customer_name,
      ticket.customer_phone,
      ticket.customer_contact,
      ticket.created_by,
      ticket.updated_by,
      ticket.created_at,
      ticket.updated_at,
      ticket.status_updated_at,
      greatest(
        0,
        (now() at time zone 'Australia/Brisbane')::date
          - (ticket.created_at at time zone 'Australia/Brisbane')::date
      ) as open_days,
      greatest(
        0,
        (now() at time zone 'Australia/Brisbane')::date
          - (ticket.status_updated_at at time zone 'Australia/Brisbane')::date
      ) as status_days,
      coalesce(job_summary.job_count, 0) as job_count,
      coalesce(job_summary.unfinished_job_count, 0) as unfinished_job_count,
      coalesce(job_summary.jobs, '[]'::jsonb) as jobs,
      coalesce(payment_summary.invoice_count, 0) as invoice_count,
      coalesce(payment_summary.balance_due, 0) as balance_due,
      case
        when coalesce(payment_summary.balance_due, 0) > 0 then 'deposit'
        when coalesce(payment_summary.invoice_count, 0) > 0 then 'paid'
        else 'unpaid'
      end as payment_status,
      case
        when ticket.status = 'need_to_order' then 'ordering'
        when ticket.status = 'waiting_shipping' then 'shipping'
        when ticket.status = 'repairing' then 'workshop'
        else 'customer'
      end as follow_up_group
    from active_tickets ticket
    join active_stores store on store.id = ticket.store_id
    left join job_summary on job_summary.repair_ticket_id = ticket.id
    left join payment_summary on payment_summary.repair_ticket_id = ticket.id
  )
  select jsonb_build_object(
    'ok', true,
    'generated_at', now(),
    'summary', jsonb_build_object(
      'active', count(*),
      'need_to_order', count(*) filter (where status = 'need_to_order'),
      'waiting_shipping', count(*) filter (where status = 'waiting_shipping'),
      'repairing', count(*) filter (where status = 'repairing'),
      'customer_follow_up', count(*) filter (
        where status in (
          'waiting_customer_confirmation',
          'waiting_pickup',
          'over_3_months_uncollected'
        )
      ),
      'stale', count(*) filter (where status_days >= 7)
    ),
    'stores', coalesce((
      select jsonb_agg(jsonb_build_object(
        'store_code', store_row.store_code,
        'store_name', store_row.store_name,
        'active_count', store_row.active_count,
        'need_to_order', store_row.need_to_order,
        'waiting_shipping', store_row.waiting_shipping,
        'customer_follow_up', store_row.customer_follow_up
      ) order by store_row.sort_order)
      from (
        select
          store.store_code,
          store.store_name,
          store.sort_order,
          count(ticket.id)::integer as active_count,
          count(ticket.id) filter (
            where ticket.status = 'need_to_order'
          )::integer as need_to_order,
          count(ticket.id) filter (
            where ticket.status = 'waiting_shipping'
          )::integer as waiting_shipping,
          count(ticket.id) filter (
            where ticket.status in (
              'waiting_customer_confirmation',
              'waiting_pickup',
              'over_3_months_uncollected'
            )
          )::integer as customer_follow_up
        from active_stores store
        left join ticket_rows ticket on ticket.store_code = store.store_code
        group by store.store_code, store.store_name, store.sort_order
      ) store_row
    ), '[]'::jsonb),
    'tickets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'ticket_code', ticket.ticket_code,
        'store_code', ticket.store_code,
        'store_name', ticket.store_name,
        'display_label', ticket.display_label,
        'title', ticket.title,
        'issue', ticket.issue,
        'price', ticket.price,
        'status', ticket.status,
        'follow_up_group', ticket.follow_up_group,
        'special_order', ticket.special_order,
        'motherboard_repair', ticket.motherboard_repair,
        'device_in_store', ticket.device_in_store,
        'customer_name', ticket.customer_name,
        'customer_phone', ticket.customer_phone,
        'customer_contact', ticket.customer_contact,
        'payment_status', ticket.payment_status,
        'balance_due', ticket.balance_due,
        'invoice_count', ticket.invoice_count,
        'job_count', ticket.job_count,
        'unfinished_job_count', ticket.unfinished_job_count,
        'jobs', ticket.jobs,
        'open_days', ticket.open_days,
        'status_days', ticket.status_days,
        'created_by', ticket.created_by,
        'updated_by', ticket.updated_by,
        'created_at', ticket.created_at,
        'updated_at', ticket.updated_at,
        'status_updated_at', ticket.status_updated_at
      ) order by
        case ticket.status
          when 'need_to_order' then 1
          when 'waiting_shipping' then 2
          when 'waiting_customer_confirmation' then 3
          when 'waiting_pickup' then 4
          when 'over_3_months_uncollected' then 5
          else 6
        end,
        ticket.status_updated_at,
        ticket.sort_order,
        ticket.ticket_code)
      from ticket_rows ticket
    ), '[]'::jsonb)
  ) into report_payload
  from ticket_rows;

  return report_payload;
end;
$$;

revoke all on function public.get_admin_repair_follow_up(text)
  from public, anon, authenticated;
grant execute on function public.get_admin_repair_follow_up(text)
  to anon, authenticated;

comment on function public.get_admin_repair_follow_up(text) is
  'Admin-session-only read model for ordering parts and following active repairs across every store. Sensitive intake security fields are intentionally omitted.';
