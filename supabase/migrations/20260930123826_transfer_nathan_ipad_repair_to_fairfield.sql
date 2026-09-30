-- Owner-requested correction: this customer's repair belongs to Fairfield.
-- Preserve signed snapshots and their original evidence paths.
do $transfer$
declare
  ticket public.pos_repair_tickets%rowtype;
  source_store public.store_locations%rowtype;
  destination_store public.store_locations%rowtype;
begin
  select * into strict source_store from public.store_locations where store_code = 'toowong' and active;
  select * into strict destination_store from public.store_locations where store_code = 'fairfield' and active;

  -- Keep the temporary exception to the store-immutability guard isolated.
  -- This statement is atomic: any error rolls back both the data and DDL.
  lock table public.pos_repair_tickets in access exclusive mode;
  select * into strict ticket from public.pos_repair_tickets
  where ticket_code = 'RPR-1790726578960' for update;
  if ticket.store_id <> source_store.id
    or ticket.customer_name <> 'Nathan Ravell'
    or ticket.title <> 'Apple iPad iPad Pro 10.5 (2017)'
    or ticket.issue <> 'Charging Socket'
    or not ticket.active or ticket.closed_at is not null then
    raise exception 'Repair no longer matches the requested TW-to-FF correction';
  end if;
  if exists (select 1 from public.pos_sales_order_lines where repair_ticket_id = ticket.id) then
    raise exception 'Repair has an invoice; store correction requires invoice review';
  end if;
  if not exists (
    select 1 from pg_trigger where tgrelid = 'public.pos_repair_tickets'::regclass
      and tgname = 'pos_repair_ticket_store_immutable' and tgenabled = 'O'
  ) then raise exception 'Expected store guard is not enabled'; end if;

  alter table public.pos_repair_tickets disable trigger pos_repair_ticket_store_immutable;
  update public.pos_repair_tickets
  set store_id = destination_store.id,
      updated_by = 'Admin (owner-requested correction)',
      activity = jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'type', 'store_transfer',
        'text', 'corrected store ownership from TW (Toowong) to FF (Fairfield) at the owner request; customer belongs to FF',
        'from_store', source_store.store_code,
        'to_store', destination_store.store_code,
        'at', clock_timestamp()
      )) || coalesce(activity, '[]'::jsonb)
  where id = ticket.id and store_id = source_store.id;
  if not found then raise exception 'Repair store correction did not update a row'; end if;
  alter table public.pos_repair_tickets enable trigger pos_repair_ticket_store_immutable;
end;
$transfer$;
