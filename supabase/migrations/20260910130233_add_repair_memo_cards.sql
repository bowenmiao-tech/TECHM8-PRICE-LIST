-- Memo cards share ticket identity, jobs, comments, photos, ordering and audit.
alter table public.pos_repair_tickets add column card_kind text not null default 'repair'
  check (card_kind in ('repair', 'memo'));

do $migration$
declare definition text; patched text; fn text;
begin
  foreach fn in array array['enforce_complete_new_pos_repair_ticket', 'enforce_complete_updated_pos_repair_ticket', 'enforce_pos_repair_ticket_numeric_price'] loop
    select pg_get_functiondef(to_regprocedure('public.' || fn || '()')) into definition;
    definition := replace(definition, E'\r\n', E'\n');
    patched := replace(definition, E'begin\n', E'begin\n  if new.card_kind = ''memo'' then\n    if new.price <> ''$0.00'' then raise exception ''Memo cards cannot have a base charge''; end if;\n    return new;\n  end if;\n');
    if patched = definition then raise exception 'Memo validation anchor missing: %', fn; end if;
    execute patched;
  end loop;
  select pg_get_functiondef('public.pos_repair_ticket_payload(public.pos_repair_tickets)'::regprocedure) into definition;
  patched := replace(definition, '''title'', ticket_row.title,', '''title'', ticket_row.title,
    ''cardKind'', ticket_row.card_kind,');
  if patched = definition then raise exception 'Memo payload kind anchor missing'; end if;
  definition := patched;
  patched := replace(definition, '''canClose'', base_invoice.sales_order_line_id is not null',
    '''canClose'', (ticket_row.card_kind = ''memo'' or base_invoice.sales_order_line_id is not null)');
  if patched = definition then raise exception 'Memo payload close anchor missing'; end if;
  execute patched;
  select pg_get_functiondef('public.finalize_pos_repair_ticket_after_checkout(text,jsonb)'::regprocedure) into definition;
  definition := replace(definition, E'\r\n', E'\n');
  patched := replace(definition, E'select 1\n      where not exists (', E'select 1\n      where ticket_row.card_kind <> ''memo'' and not exists (');
  if patched = definition then raise exception 'Memo checkout anchor missing'; end if;
  execute patched;
end;
$migration$;

create or replace function public.manage_pos_repair_memo(session_token text, payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor jsonb;
  ticket_row public.pos_repair_tickets%rowtype;
  action_value text := payload->>'action';
  code_value text := btrim(coalesce(payload->>'ticket_code',''));
  label_value text := btrim(coalesce(payload->>'display_label',''));
  notes_value text := coalesce(payload->>'notes','');
  name_value text := btrim(coalesce(payload->>'customer_name',''));
  phone_value text := btrim(coalesce(payload->>'customer_phone',''));
  status_value text := payload->>'status';
  event_text text;
  result jsonb;
begin
  actor := public.pos_authorized_actor(session_token,payload->>'store_code',payload->>'staff_name');
  if action_value is null or action_value not in ('create-memo','save-memo','finish-memo','move-memo') then raise exception 'Unknown memo action'; end if;
  if code_value = '' or length(code_value)>100 then raise exception 'Invalid card code'; end if;
  if length(label_value)>80 or length(notes_value)>10000 or length(name_value)>200 or length(phone_value)>200 then raise exception 'Memo text is too long'; end if;
  perform pg_advisory_xact_lock(hashtextextended(code_value,0));
  select * into ticket_row from public.pos_repair_tickets where ticket_code=code_value for update;
  if found then
    if ticket_row.store_id <> (actor->>'store_id')::bigint then raise exception 'Card belongs to another store'; end if;
    if ticket_row.card_kind <> 'memo' then raise exception 'This is not a memo card'; end if;
    if not ticket_row.active then raise exception 'Card has been deleted'; end if;
    if action_value = 'create-memo' then
      return jsonb_build_object('ok',true,'ticket',public.pos_repair_ticket_payload(ticket_row));
    end if;
    if ticket_row.closed_at is not null then
      if action_value = 'finish-memo' then return jsonb_build_object('ok',true,'ticket',public.pos_repair_ticket_payload(ticket_row)); end if;
      raise exception 'Card is already finished';
    end if;
  elsif action_value <> 'create-memo' then raise exception 'Memo card not found';
  end if;
  if action_value = 'create-memo' then
    if status_value is null or status_value not in ('need_to_order','waiting_shipping','repairing','waiting_customer_confirmation','waiting_pickup','over_3_months_uncollected') then raise exception 'Invalid card status'; end if;
    insert into public.pos_repair_tickets(ticket_code,store_id,card_kind,title,display_label,issue,price,status,
      customer_name,customer_phone,customer_contact,device_in_store,intake,created_by,updated_by,board_position)
    values(code_value,(actor->>'store_id')::bigint,'memo','Memo card',label_value,'Memo','$0.00',status_value,
      name_value,phone_value,phone_value,false,jsonb_build_object('memoNotes',notes_value),actor->>'staff_name',actor->>'staff_name',
      coalesce((select max(board_position)+10 from public.pos_repair_tickets where store_id=(actor->>'store_id')::bigint and status=status_value and active and closed_at is null),10))
    returning * into ticket_row;
    event_text := 'created this memo card';
  elsif action_value = 'move-memo' then
    if status_value is null or status_value not in ('need_to_order','waiting_shipping','repairing','waiting_customer_confirmation','waiting_pickup','over_3_months_uncollected') then raise exception 'Invalid card status'; end if;
    update public.pos_repair_tickets set status=status_value,status_updated_at=now(),
      ready_for_pickup_at=case when status_value='waiting_pickup' then now() else null end
    where id=ticket_row.id returning * into ticket_row;
    event_text := 'moved this memo card to ' || replace(status_value,'_',' ');
  elsif action_value = 'save-memo' then
    if exists(select 1 from public.pos_sales_order_lines where repair_ticket_id=ticket_row.id)
      and (name_value is distinct from ticket_row.customer_name or phone_value is distinct from ticket_row.customer_phone) then
      raise exception 'Customer details are locked to the invoice';
    end if;
    update public.pos_repair_tickets set display_label=label_value,
      intake=jsonb_set(coalesce(intake,'{}'::jsonb),'{memoNotes}',to_jsonb(notes_value)),
      customer_name=name_value,customer_phone=phone_value,customer_contact=phone_value
    where id=ticket_row.id returning * into ticket_row;
    event_text := 'updated this memo card';
  else
    result := public.pos_repair_ticket_payload(ticket_row);
    if not coalesce((result->>'canClose')::boolean,false) then raise exception 'Complete and bill the repairs, and settle any balance before finishing'; end if;
    update public.pos_repair_tickets set closed_at=now() where id=ticket_row.id returning * into ticket_row;
    event_text := 'finished this memo card';
  end if;
  update public.pos_repair_tickets set updated_by=actor->>'staff_name',updated_at=now(),
    activity=jsonb_build_array(jsonb_build_object('id','ACT-'||extensions.gen_random_uuid()::text,
      'type',case when action_value='finish-memo' then 'finished' else 'memo' end,
      'text',event_text,'staffName',actor->>'staff_name','at',now())) || coalesce(activity,'[]'::jsonb)
  where id=ticket_row.id returning * into ticket_row;
  return jsonb_build_object('ok',true,'ticket',public.pos_repair_ticket_payload(ticket_row));
end;
$$;
revoke all on function public.manage_pos_repair_memo(text,jsonb) from public,anon,authenticated;
grant execute on function public.manage_pos_repair_memo(text,jsonb) to service_role;
