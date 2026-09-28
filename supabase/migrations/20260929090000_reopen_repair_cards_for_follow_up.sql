-- A customer who comes back with a problem after a repair was closed brings
-- the receipt, not the ticket code. Staff searched the invoice number, found
-- nothing, and had to rebuild the history by hand. Two changes:
--   1. The Repair Board search also matches the invoice number (with or
--      without "#") and the POS order code of any invoice billed on a card.
--   2. A Done card can be reopened onto the board for a follow-up check. The
--      reason is kept as a note on the original card, so the earlier repair,
--      invoices, photos and the new complaint all stay in one place.

create or replace function public.search_pos_repair_tickets(
  session_token text,
  target_store_code text,
  search_query text default ''::text,
  result_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  selected_store public.store_locations%rowtype;
  tickets_payload jsonb;
  query_value text := trim(coalesce(search_query, ''));
  phone_query text := regexp_replace(coalesce(search_query, ''), '[^0-9]', '', 'g');
  invoice_query text := regexp_replace(trim(coalesce(search_query, '')), '^#\s*', '');
  safe_limit integer := least(greatest(coalesce(result_limit, 200), 1), 500);
begin
  if not public.is_valid_staff_session(session_token) then
    raise exception 'Invalid session';
  end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = coalesce(trim(target_store_code), '')
    and store_location.store_code <> 'warehouse';

  if not found then
    raise exception 'Store not found';
  end if;

  select coalesce(
    jsonb_agg(public.pos_repair_ticket_payload(ticket) order by ticket.board_position, ticket.status_updated_at desc, ticket.created_at desc),
    '[]'::jsonb
  )
  into tickets_payload
  from (
    select repair_ticket.*
    from public.pos_repair_tickets repair_ticket
    where repair_ticket.store_id = selected_store.id
      and (query_value <> '' or (repair_ticket.active = true and repair_ticket.closed_at is null))
      and (
        query_value = ''
        or repair_ticket.ticket_code ilike '%' || query_value || '%'
        or repair_ticket.display_label ilike '%' || query_value || '%'
        or repair_ticket.customer_name ilike '%' || query_value || '%'
        or repair_ticket.customer_phone ilike '%' || query_value || '%'
        or (phone_query <> '' and regexp_replace(repair_ticket.customer_phone, '[^0-9]', '', 'g') like '%' || phone_query || '%')
        or repair_ticket.title ilike '%' || query_value || '%'
        or repair_ticket.issue ilike '%' || query_value || '%'
        or repair_ticket.intake::text ilike '%' || query_value || '%'
        or exists (
          select 1
          from public.pos_sales_order_lines sales_line
          join public.pos_sales_orders sales_order on sales_order.id = sales_line.sales_order_id
          where sales_line.repair_ticket_id = repair_ticket.id
            and (
              (invoice_query ~ '^[0-9]+$' and sales_order.invoice_number::text = invoice_query)
              or sales_order.order_code ilike '%' || query_value || '%'
            )
        )
      )
    order by repair_ticket.board_position, repair_ticket.status_updated_at desc, repair_ticket.created_at desc
    limit safe_limit
  ) ticket;

  return jsonb_build_object(
    'ok', true,
    'store_code', selected_store.store_code,
    'store_name', selected_store.store_name,
    'tickets', tickets_payload
  );
end;
$function$;

create or replace function public.reopen_pos_repair_ticket(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  reason text := btrim(coalesce(payload->>'reason', ''));
  next_status text := coalesce(nullif(lower(btrim(payload->>'status')), ''), 'repairing');
  device_back boolean;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Payload must be an object'; end if;
  actor := public.pos_authorized_actor(session_token, coalesce(payload->>'store_code', payload->>'store_id'), payload->>'staff_name');

  if reason = '' then raise exception 'Describe what the customer came back with'; end if;
  if char_length(reason) > 2000 then raise exception 'Keep the follow-up note under 2,000 characters'; end if;
  if next_status not in ('need_to_order', 'waiting_shipping', 'repairing', 'waiting_pickup', 'waiting_customer_confirmation') then
    raise exception 'Invalid board column';
  end if;
  device_back := coalesce(nullif(payload->>'device_in_store', '')::boolean, true);

  select * into ticket_row
  from public.pos_repair_tickets ticket
  where ticket.ticket_code = coalesce(btrim(payload->>'ticket_code'), '')
  for update;
  if not found then raise exception 'Repair ticket not found'; end if;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then raise exception 'Repair ticket belongs to another store'; end if;
  if not ticket_row.active then raise exception 'Deleted repair tickets cannot be reopened'; end if;
  if ticket_row.closed_at is null then raise exception 'This card is already open on the Repair Board'; end if;

  -- Type 'status' stops the activity trigger adding a second "moved" event;
  -- the reopened flag lets the board show which cards are follow-ups.
  update public.pos_repair_tickets
  set status = next_status,
      resolution = null,
      closed_at = null,
      ready_for_pickup_at = case when next_status = 'waiting_pickup' then now() else null end,
      device_in_store = device_back,
      board_position = 0,
      updated_by = actor->>'staff_name',
      status_updated_at = now(),
      updated_at = now(),
      activity = jsonb_build_array(jsonb_build_object(
        'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
        'type', 'status',
        'reopened', true,
        'text', 'reopened this card for a follow-up check (was closed as '
          || replace(coalesce(ticket_row.resolution, 'done'), '_', ' ')
          || ') in ' || replace(next_status, '_', ' '),
        'staffName', actor->>'staff_name',
        'at', now()
      )) || coalesce(activity, '[]'::jsonb)
  where id = ticket_row.id;

  insert into public.pos_repair_ticket_updates(id, repair_ticket_id, kind, body, author)
  values (gen_random_uuid(), ticket_row.id, 'comment', 'Follow-up check: ' || reason, actor->>'staff_name');

  select * into ticket_row from public.pos_repair_tickets where id = ticket_row.id;
  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$function$;

comment on function public.reopen_pos_repair_ticket(text, jsonb) is
  'Puts a Done (closed, not deleted) repair or memo card back on the Repair Board for a follow-up check and saves the reason as a note on the card. Invoices, jobs and history are untouched.';

revoke all on function public.reopen_pos_repair_ticket(text, jsonb) from public, anon, authenticated;
grant execute on function public.reopen_pos_repair_ticket(text, jsonb) to service_role;
