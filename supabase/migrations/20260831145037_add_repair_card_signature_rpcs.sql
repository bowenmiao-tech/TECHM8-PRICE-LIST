-- Record and read signed repair cards.
--
-- The actor and store come from pos_authorized_actor, so a signature can never
-- be attributed to another staff member or another store, and signed_at is the
-- server clock rather than anything the browser sends.

create or replace function public.save_pos_repair_card_signature(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  active_terms public.pos_repair_card_terms%rowtype;
  signature_code_value text;
  customer_value text := trim(coalesce(payload->>'signed_customer_name', ''));
  path_value text := trim(coalesce(payload->>'signature_path', ''));
  reason_value text := nullif(trim(coalesce(payload->>'resign_reason', '')), '');
  previous public.pos_repair_card_signatures%rowtype;
  inserted public.pos_repair_card_signatures%rowtype;
begin
  if jsonb_typeof(payload) <> 'object' then raise exception 'Signature payload must be an object'; end if;

  actor := public.pos_authorized_actor(
    session_token,
    coalesce(payload->>'store_code', payload->>'store_id'),
    payload->>'staff_name'
  );

  select * into ticket_row
  from public.pos_repair_tickets
  where ticket_code = coalesce(trim(payload->>'ticket_code'), '')
  for update;
  if not found then raise exception 'Repair ticket not found'; end if;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then
    raise exception 'Repair ticket belongs to another store';
  end if;

  if customer_value = '' then raise exception 'The customer must type their name to sign'; end if;
  if path_value = '' then raise exception 'Signature image is required'; end if;
  if jsonb_typeof(payload->'card_snapshot') <> 'object' then
    raise exception 'Card snapshot is required';
  end if;

  select * into active_terms from public.pos_repair_card_terms where active order by created_at desc limit 1;
  if not found then raise exception 'No active repair card terms'; end if;

  select * into previous
  from public.pos_repair_card_signatures
  where repair_ticket_id = ticket_row.id and superseded_at is null
  order by signed_at desc
  limit 1;

  if found and reason_value is null then
    raise exception 'This card is already signed. A reason is required to re-sign it.';
  end if;

  signature_code_value := 'RCS-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint
    || '-' || substr(md5(random()::text), 1, 6);

  insert into public.pos_repair_card_signatures (
    signature_code, repair_ticket_id, store_id, signature_path, signed_customer_name,
    terms_version, terms_text, card_snapshot, witnessed_by
  ) values (
    signature_code_value, ticket_row.id, ticket_row.store_id, path_value, customer_value,
    active_terms.version, active_terms.body, payload->'card_snapshot', actor->>'staff_name'
  ) returning * into inserted;

  if previous.id is not null then
    update public.pos_repair_card_signatures
    set superseded_at = now(),
        superseded_reason = reason_value,
        superseded_by_signature_code = signature_code_value
    where id = previous.id;
  end if;

  update public.pos_repair_tickets
  set activity = jsonb_build_array(jsonb_build_object(
        'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
        'type', 'signature',
        'text', case when previous.id is null
                  then 'captured the signed repair card'
                  else 're-signed the repair card (' || reason_value || ')' end,
        'staffName', actor->>'staff_name',
        'at', now()
      )) || coalesce(activity, '[]'::jsonb),
      updated_by = actor->>'staff_name',
      updated_at = now()
  where id = ticket_row.id;

  return jsonb_build_object('ok', true, 'signature', to_jsonb(inserted));
end;
$$;

create or replace function public.get_pos_repair_card_signatures(
  session_token text,
  target_store_code text,
  target_ticket_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  rows_payload jsonb;
begin
  actor := public.pos_authorized_actor(session_token, target_store_code, null);

  select * into ticket_row
  from public.pos_repair_tickets
  where ticket_code = coalesce(trim(target_ticket_code), '');
  if not found then raise exception 'Repair ticket not found'; end if;
  if ticket_row.store_id <> nullif(actor->>'store_id', '')::bigint then
    raise exception 'Repair ticket belongs to another store';
  end if;

  select coalesce(jsonb_agg(to_jsonb(s) order by s.signed_at desc), '[]'::jsonb)
  into rows_payload
  from public.pos_repair_card_signatures s
  where s.repair_ticket_id = ticket_row.id;

  return jsonb_build_object('ok', true, 'ticket_code', ticket_row.ticket_code, 'signatures', rows_payload);
end;
$$;

revoke all on function public.save_pos_repair_card_signature(text, jsonb) from public, anon, authenticated;
revoke all on function public.get_pos_repair_card_signatures(text, text, text) from public, anon, authenticated;
grant execute on function public.save_pos_repair_card_signature(text, jsonb) to service_role;
grant execute on function public.get_pos_repair_card_signatures(text, text, text) to service_role;
