-- Fill missing identifiers without rewriting prices, signatures, or the intake.
create or replace function public.set_pos_repair_ticket_device_id(session_token text, payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  new_imei text := btrim(coalesce(payload->>'device_imei', ''));
  new_serial text := btrim(coalesce(payload->>'device_serial', ''));
  next_intake jsonb;
begin
  actor := public.pos_authorized_actor(session_token,
    coalesce(payload->>'store_code', payload->>'store_id'), payload->>'staff_name');
  if new_imei = '' and new_serial = '' then raise exception 'Enter an IMEI or serial number'; end if;
  if new_imei <> '' and new_imei !~ '^[0-9]{15}$' then raise exception 'IMEI must contain exactly 15 digits'; end if;
  if length(new_serial) > 100 then raise exception 'Serial number is too long'; end if;
  select * into ticket_row from public.pos_repair_tickets
    where ticket_code = coalesce(btrim(payload->>'ticket_code'), '') for update;
  if not found then raise exception 'Repair ticket not found'; end if;
  if ticket_row.store_id is distinct from nullif(actor->>'store_id', '')::bigint then
    raise exception 'Repair ticket belongs to another store';
  end if;
  if not ticket_row.active then raise exception 'Repair ticket is not active'; end if;
  if ticket_row.card_kind = 'memo' then raise exception 'Memo cards do not have device identifiers'; end if;
  next_intake := coalesce(ticket_row.intake, '{}'::jsonb);
  if new_imei <> '' then
    if coalesce(next_intake->>'deviceImei', '') not in ('', new_imei) then
      raise exception 'IMEI is already recorded';
    end if;
    next_intake := next_intake || jsonb_build_object('deviceImei', new_imei);
  end if;
  if new_serial <> '' then
    if coalesce(next_intake->>'deviceSerial', '') not in ('', new_serial) then
      raise exception 'Serial number is already recorded';
    end if;
    next_intake := next_intake || jsonb_build_object('deviceSerial', new_serial);
  end if;
  next_intake := next_intake || jsonb_build_object('deviceIdType',
    case when coalesce(next_intake->>'deviceImei', '') <> '' then 'imei' else 'sn' end);
  if next_intake = ticket_row.intake then
    return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
  end if;
  update public.pos_repair_tickets set intake = next_intake,
    updated_by = actor->>'staff_name', updated_at = now(),
    activity = jsonb_build_array(jsonb_build_object('id', gen_random_uuid()::text,
      'type', 'device-id', 'field', 'intake', 'text', 'added missing device identifiers',
      'staffName', actor->>'staff_name', 'at', now())) || coalesce(activity, '[]'::jsonb)
    where id = ticket_row.id returning * into ticket_row;
  return jsonb_build_object('ok', true, 'ticket', public.pos_repair_ticket_payload(ticket_row));
end;
$$;
revoke all on function public.set_pos_repair_ticket_device_id(text, jsonb) from public, anon, authenticated;
grant execute on function public.set_pos_repair_ticket_device_id(text, jsonb) to service_role;
