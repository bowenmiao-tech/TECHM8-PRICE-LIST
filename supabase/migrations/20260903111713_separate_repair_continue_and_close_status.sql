-- Continuing a repair and finishing a repair are different decisions.
-- A finished card is closed, not left with the operational waiting-pickup status.

alter table public.pos_repair_tickets
  drop constraint if exists pos_repair_tickets_status_check;

alter table public.pos_repair_tickets
  add constraint pos_repair_tickets_status_check
  check (status in (
    'need_to_order',
    'waiting_shipping',
    'repairing',
    'waiting_pickup',
    'waiting_customer_confirmation',
    'over_3_months_uncollected',
    'closed'
  ));

update public.pos_repair_tickets
set status = 'closed'
where closed_at is not null
  and status <> 'closed';

create or replace function public.finalize_pos_repair_ticket_after_checkout(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  order_row public.pos_sales_orders%rowtype;
  decision text := lower(btrim(coalesce(payload->>'decision', '')));
  next_status text := coalesce(nullif(lower(btrim(payload->>'next_status')), ''), 'repairing');
  result_value text := coalesce(nullif(lower(btrim(payload->>'resolution')), ''), 'repaired');
  unbilled_count integer;
  unfinished_count integer;
  open_balance_count integer;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Payload must be an object'; end if;
  actor := public.pos_authorized_actor(session_token, coalesce(payload->>'store_code', payload->>'store_id'), payload->>'staff_name');

  select * into ticket_row
  from public.pos_repair_tickets ticket
  where ticket.ticket_code = coalesce(btrim(payload->>'ticket_code'), '')
  for update;
  if not found then raise exception 'Repair ticket not found'; end if;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then raise exception 'Repair ticket belongs to another store'; end if;

  select * into order_row
  from public.pos_sales_orders sales_order
  where sales_order.order_code = coalesce(btrim(payload->>'order_code'), '')
    and sales_order.store_id = ticket_row.store_id;
  if not found then raise exception 'Paid invoice not found'; end if;
  if order_row.payment_status <> 'paid' or round(order_row.amount_paid, 2) < round(order_row.total, 2) then
    raise exception 'Repair card cannot be completed before full payment';
  end if;
  if not exists (
    select 1 from public.pos_sales_order_lines sales_line
    where sales_line.sales_order_id = order_row.id
      and sales_line.repair_ticket_id = ticket_row.id
  ) then raise exception 'Invoice does not belong to this repair card'; end if;

  if decision = 'keep' then
    if ticket_row.closed_at is not null then raise exception 'This repair card is already closed'; end if;
    if next_status not in ('need_to_order', 'waiting_shipping', 'repairing', 'waiting_pickup', 'waiting_customer_confirmation', 'over_3_months_uncollected') then
      raise exception 'Invalid next repair status';
    end if;

    update public.pos_repair_tickets
    set status = next_status,
        resolution = null,
        closed_at = null,
        ready_for_pickup_at = case when next_status in ('waiting_pickup', 'over_3_months_uncollected') then now() else null end,
        updated_by = actor->>'staff_name',
        status_updated_at = now(),
        updated_at = now(),
        activity = jsonb_build_array(jsonb_build_object(
          'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
          'type', 'status',
          'text', 'continued this repair card after invoice #' || order_row.invoice_number || ' in ' || replace(next_status, '_', ' '),
          'staffName', actor->>'staff_name',
          'at', now()
        )) || coalesce(activity, '[]'::jsonb)
    where id = ticket_row.id;
  elsif decision = 'finish' then
    if ticket_row.closed_at is not null then
      return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
    end if;
    if result_value not in ('repaired', 'no_fault_found', 'customer_declined', 'unrepairable', 'cancelled', 'returned_unrepaired', 'referred') then
      raise exception 'Invalid repair outcome';
    end if;

    select count(*) into unbilled_count
    from (
      select 1
      where not exists (
        select 1 from public.pos_sales_order_lines sales_line
        where sales_line.repair_ticket_id = ticket_row.id and sales_line.repair_job_id is null
      )
      union all
      select 1
      from public.pos_repair_ticket_jobs job
      where job.repair_ticket_id = ticket_row.id
        and job.status <> 'cancelled'
        and not exists (select 1 from public.pos_sales_order_lines sales_line where sales_line.repair_job_id = job.id)
    ) missing;

    select count(*) into unfinished_count
    from public.pos_repair_ticket_jobs job
    where job.repair_ticket_id = ticket_row.id
      and job.status not in ('completed', 'cancelled');

    select count(distinct sales_order.id) into open_balance_count
    from public.pos_sales_orders sales_order
    join public.pos_sales_order_lines sales_line on sales_line.sales_order_id = sales_order.id
    where sales_line.repair_ticket_id = ticket_row.id
      and round(sales_order.amount_paid, 2) < round(sales_order.total, 2);

    if unbilled_count > 0 then raise exception 'Unbilled repair work remains on this card'; end if;
    if unfinished_count > 0 then raise exception 'Repair work must be completed or cancelled before closing this card'; end if;
    if open_balance_count > 0 then raise exception 'An invoice balance is still owing on this card'; end if;

    update public.pos_repair_tickets
    set status = 'closed',
        resolution = result_value,
        ready_for_pickup_at = coalesce(ready_for_pickup_at, now()),
        closed_at = now(),
        updated_by = actor->>'staff_name',
        status_updated_at = now(),
        updated_at = now(),
        activity = jsonb_build_array(jsonb_build_object(
          'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
          'type', 'finished',
          'text', 'closed this repair card after invoice #' || order_row.invoice_number || ' - ' || replace(result_value, '_', ' '),
          'staffName', actor->>'staff_name',
          'at', now()
        )) || coalesce(activity, '[]'::jsonb)
    where id = ticket_row.id;
  else
    raise exception 'Decision must be keep or finish';
  end if;

  select * into ticket_row from public.pos_repair_tickets where id = ticket_row.id;
  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;

revoke all on function public.finalize_pos_repair_ticket_after_checkout(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.finalize_pos_repair_ticket_after_checkout(text, jsonb)
  to service_role;

comment on function public.finalize_pos_repair_ticket_after_checkout(text, jsonb) is
  'Authenticated post-payment choice: continue on the Repair Board or close the card. Closed cards use status closed, never waiting_pickup.';
