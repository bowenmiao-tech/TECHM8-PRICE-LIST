-- Invoiced repair work could never be marked complete, so the card could never
-- be closed.
--
-- update_pos_repair_ticket_job refuses every change once a job has an invoice
-- line, which is right for the name, the price and the approval: those are on a
-- document the customer already paid. It also blocked the status, and
-- finalize_pos_repair_ticket_after_checkout requires every job to be completed
-- or cancelled. Billing a job while it was still "approved" therefore left the
-- card permanently open, with no control in the POS that could rescue it.
--
-- Paying for work and finishing work are separate decisions here, so the fix is
-- a status-only transition rather than loosening the edit guard. Cancelling
-- invoiced work is deliberately not allowed: money has changed hands, so that
-- belongs in the refund flow.

create or replace function public.complete_pos_repair_ticket_job(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  job_row public.pos_repair_ticket_jobs%rowtype;
begin
  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Job payload must be an object';
  end if;
  actor := public.pos_authorized_actor(
    session_token,
    coalesce(payload->>'store_code', payload->>'store_id'),
    payload->>'staff_name'
  );

  select * into job_row
  from public.pos_repair_ticket_jobs
  where job_code = coalesce(btrim(payload->>'job_code'), '')
  for update;
  if not found then raise exception 'Repair job not found'; end if;

  select * into ticket_row
  from public.pos_repair_tickets
  where id = job_row.repair_ticket_id
  for update;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then
    raise exception 'Repair ticket belongs to another store';
  end if;
  if ticket_row.closed_at is not null then
    raise exception 'This repair card is closed.';
  end if;

  if job_row.status = 'cancelled' then
    raise exception 'This repair was cancelled and cannot be completed';
  end if;
  if job_row.status = 'completed' then
    return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
  end if;

  update public.pos_repair_ticket_jobs
  set status = 'completed',
      completed_by = actor->>'staff_name',
      completed_at = now(),
      updated_by = actor->>'staff_name',
      updated_at = now()
  where id = job_row.id;

  update public.pos_repair_tickets
  set updated_by = actor->>'staff_name',
      updated_at = now(),
      activity = jsonb_build_array(jsonb_build_object(
        'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
        'type', 'job',
        'text', 'marked repair complete: ' || job_row.name,
        'staffName', actor->>'staff_name',
        'at', now()
      )) || coalesce(activity, '[]'::jsonb)
  where id = ticket_row.id
  returning * into ticket_row;

  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;

revoke all on function public.complete_pos_repair_ticket_job(text, jsonb) from public;
revoke all on function public.complete_pos_repair_ticket_job(text, jsonb) from anon;
revoke all on function public.complete_pos_repair_ticket_job(text, jsonb) from authenticated;
grant execute on function public.complete_pos_repair_ticket_job(text, jsonb) to service_role;

comment on function public.complete_pos_repair_ticket_job(text, jsonb) is
  'Marks one repair job complete without touching its name, price, or approval, so work billed before it was finished can still be closed off.';
