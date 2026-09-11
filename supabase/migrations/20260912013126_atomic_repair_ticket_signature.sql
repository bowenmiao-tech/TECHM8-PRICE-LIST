-- Create a repair ticket and its first signed intake card in one transaction.
-- A failed signature must never leave a new unsigned ticket on the board.

create or replace function public.create_pos_repair_ticket_with_signature(
  session_token text,
  ticket_payload jsonb,
  signature_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_code_value text;
  signature_ticket_code text;
  normalized_ticket jsonb;
  normalized_signature jsonb;
  ticket_result jsonb;
  signature_result jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
begin
  if jsonb_typeof(ticket_payload) <> 'object' then
    raise exception 'Ticket payload must be an object';
  end if;
  if jsonb_typeof(signature_payload) <> 'object' then
    raise exception 'Signature payload must be an object';
  end if;

  ticket_code_value := coalesce(
    nullif(btrim(ticket_payload->>'ticket_code'), ''),
    nullif(btrim(ticket_payload->>'id'), '')
  );
  signature_ticket_code := nullif(btrim(signature_payload->>'ticket_code'), '');
  if ticket_code_value is null then
    raise exception 'Ticket id is required';
  end if;
  if signature_ticket_code is null or signature_ticket_code <> ticket_code_value then
    raise exception 'The signed card does not match this repair ticket';
  end if;

  actor := public.pos_authorized_actor(
    session_token,
    coalesce(
      ticket_payload->>'store_code',
      ticket_payload->>'store_db_code',
      ticket_payload->>'storeId',
      ticket_payload->>'store_id'
    ),
    coalesce(ticket_payload->>'staff_name', ticket_payload->>'updatedBy', ticket_payload->>'createdBy')
  );

  -- Serialise attempts for the generated ticket number and keep this endpoint
  -- create-only. Existing cards use the ordinary re-sign path instead.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(ticket_code_value, 0));
  if exists (
    select 1 from public.pos_repair_tickets ticket
    where ticket.ticket_code = ticket_code_value
  ) then
    raise exception 'A repair ticket with this number already exists';
  end if;

  normalized_ticket := ticket_payload || jsonb_build_object(
    'id', ticket_code_value,
    'ticket_code', ticket_code_value,
    'store_id', actor->>'store_code',
    'storeId', actor->>'store_code',
    'store_code', actor->>'store_code',
    'store_db_code', actor->>'store_code',
    'staff_name', actor->>'staff_name',
    'createdBy', actor->>'staff_name',
    'updatedBy', actor->>'staff_name',
    'created_by', actor->>'staff_name',
    'updated_by', actor->>'staff_name'
  );
  ticket_result := public.upsert_pos_repair_ticket(session_token, normalized_ticket);
  if not coalesce((ticket_result->>'ok')::boolean, false) then
    raise exception '%', coalesce(ticket_result->>'message', 'Repair ticket could not be created');
  end if;

  normalized_signature := signature_payload || jsonb_build_object(
    'ticket_code', ticket_code_value,
    'store_code', actor->>'store_code',
    'staff_name', actor->>'staff_name'
  );
  signature_result := public.save_pos_repair_card_signature(session_token, normalized_signature);
  if not coalesce((signature_result->>'ok')::boolean, false) then
    raise exception '%', coalesce(signature_result->>'message', 'Signed repair card could not be saved');
  end if;

  select * into ticket_row
  from public.pos_repair_tickets ticket
  where ticket.ticket_code = ticket_code_value;

  return jsonb_build_object(
    'ok', true,
    'ticket', public.pos_repair_ticket_payload(ticket_row),
    'signature', signature_result->'signature'
  );
end;
$$;

comment on function public.create_pos_repair_ticket_with_signature(text, jsonb, jsonb) is
  'Internal Edge Function RPC. Creates a new repair ticket and its first signed intake card atomically; any failure rolls back both records.';

revoke all on function public.create_pos_repair_ticket_with_signature(text, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.create_pos_repair_ticket_with_signature(text, jsonb, jsonb)
  to service_role;
