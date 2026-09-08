-- Run as the database owner; every fixture change is rolled back.
begin;
do $$
declare
  original public.pos_repair_tickets%rowtype;
  changed public.pos_repair_tickets%rowtype;
  initial_count integer;
  saved_count integer;
  derived_count integer;
begin
  select * into strict original from public.pos_repair_tickets
    where active and closed_at is null order by id limit 1;
  initial_count := jsonb_array_length(original.activity);
  update public.pos_repair_tickets set updated_by='Audit test employee',
    status=case when status='repairing' then 'waiting_pickup' else 'repairing' end,
    activity='[]'::jsonb where id=original.id returning * into changed;
  assert jsonb_array_length(changed.activity)>initial_count, 'Missing status audit';
  assert changed.activity @> original.activity, 'Stale save erased history';
  assert exists(select 1 from jsonb_array_elements(changed.activity) e
    where e->>'type'='status' and e->>'staffName'='Audit test employee'
      and (e->>'at')::timestamptz >= transaction_timestamp()), 'Wrong actor or date';
  saved_count:=jsonb_array_length(changed.activity);
  update public.pos_repair_tickets set activity='[]'::jsonb where id=original.id returning * into changed;
  assert jsonb_array_length(changed.activity)=saved_count, 'Duplicate event on no-op save';
  update public.pos_repair_tickets set closed_at=now(), updated_by='Done employee'
    where id=original.id returning * into changed;
  assert exists(select 1 from jsonb_array_elements(changed.activity) e
    where e->>'type'='finished' and e->>'staffName'='Done employee'), 'Missing Done audit';
  update public.pos_repair_tickets set active=false,updated_by='Delete employee'
    where id=original.id returning * into changed;
  assert exists(select 1 from jsonb_array_elements(changed.activity) e
    where e->>'type'='deleted' and e->>'staffName'='Delete employee'), 'Missing delete audit';
  assert (public.pos_repair_ticket_payload(changed)->>'active')::boolean=false, 'Missing archived state';
  begin
    update public.pos_repair_tickets set active=true where id=original.id;
    raise exception 'TEST FAILURE: deleted ticket reopened';
  exception when others then
    if sqlerrm <> 'Deleted repair tickets cannot be reopened by saving an old page' then raise; end if;
  end;
  select t.* into strict original from public.pos_repair_tickets t where exists (
    select 1 from public.pos_sales_order_lines l join public.pos_sales_order_payments p on p.sales_order_id=l.sales_order_id
    where l.repair_ticket_id=t.id) order by t.id limit 1;
  select count(*) into derived_count from jsonb_array_elements(public.pos_repair_ticket_activity(original)) e
    where e->>'source'='invoice' and e->>'type'='paid';
  assert derived_count>0, 'Historical checkout events missing';
  update public.pos_repair_tickets set activity=public.pos_repair_ticket_activity(original)
    where id=original.id returning * into changed;
  assert not exists(select 1 from jsonb_array_elements(changed.activity) e where e->>'source'='invoice'), 'Derived invoices persisted twice';
  assert derived_count=(select count(*) from jsonb_array_elements(public.pos_repair_ticket_activity(changed)) e
    where e->>'source'='invoice' and e->>'type'='paid'), 'Checkout duplicated on save';
end $$;
rollback;
select 'PASS: actor/date, stale saves, Done, delete, no reopening, historical payments and no duplicate payment events; all fixture changes rolled back' as result;
