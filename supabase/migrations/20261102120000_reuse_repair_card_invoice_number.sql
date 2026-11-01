-- One repair card, one invoice number.
--
-- Staff take the inspection fee first and do the repair later. The later
-- checkout used to get a fresh invoice number, so the customer ended up with
-- #4400 for the inspection and #4450 for the repair on the same card. Now any
-- checkout that bills a card which already has an invoice reuses that card's
-- first invoice number.
--
-- The checkouts stay separate sales orders. Each keeps its own business date,
-- staff member, shift and payments, so the repair still counts towards the day
-- and the person who did it, and a closed month is never rewritten. Only the
-- number the customer sees is shared; invoice_part tells the pieces apart.

alter table public.pos_sales_orders
  add column if not exists invoice_part integer not null default 1;

alter table public.pos_sales_orders
  drop constraint if exists pos_sales_orders_invoice_part_positive;
alter table public.pos_sales_orders
  add constraint pos_sales_orders_invoice_part_positive check (invoice_part >= 1);

comment on column public.pos_sales_orders.invoice_part is
  '1 for the checkout that took the invoice number; 2, 3, ... for later checkouts of the same repair card that reuse it.';

-- The first part of a number stays unique on its own, which is also what the
-- RepairDesk import's on-conflict clause targets.
drop index if exists public.pos_sales_orders_store_invoice_number_key;
create unique index pos_sales_orders_store_invoice_number_key
  on public.pos_sales_orders (store_id, invoice_number)
  where invoice_part = 1;
create unique index if not exists pos_sales_orders_store_invoice_part_key
  on public.pos_sales_orders (store_id, invoice_number, invoice_part);

do $migration$
declare
  definition text;
  patched text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'import_repairdesk_sales_batch' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'import_repairdesk_sales_batch was not found'; end if;

  patched := replace(
    definition,
    $anchor$on conflict (store_id, invoice_number) do update set$anchor$,
    $replacement$on conflict (store_id, invoice_number) where invoice_part = 1 do update set$replacement$
  );
  if patched = definition then
    raise exception 'invoice part patch: the import on-conflict anchor was not found';
  end if;
  execute patched;
end;
$migration$;

-- Every checkout path takes its number from pos_store_invoice_counters and
-- then inserts the order, so swapping the number here covers the till, balance
-- checkouts and payment links alike.
create or replace function public.pos_sales_order_reuse_repair_invoice_number()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  earlier public.pos_sales_orders%rowtype;
begin
  if lower(coalesce(new.order_payload->>'legacy_import', 'false')) = 'true'
    or jsonb_typeof(new.order_payload->'items') <> 'array' then
    return new;
  end if;

  -- The first card in the cart that was billed before decides the number.
  select sales_order.* into earlier
  from jsonb_array_elements(new.order_payload->'items') with ordinality as item(value, ordinality)
  join public.pos_repair_tickets repair_ticket
    on repair_ticket.ticket_code = coalesce(
      nullif(trim(item.value->>'ticket_id'), ''),
      nullif(regexp_replace(coalesce(item.value->>'product_id', ''), '^repair-', ''), coalesce(item.value->>'product_id', ''))
    )
   and repair_ticket.store_id = new.store_id
  join public.pos_sales_order_lines sales_line on sales_line.repair_ticket_id = repair_ticket.id
  join public.pos_sales_orders sales_order
    on sales_order.id = sales_line.sales_order_id
   and sales_order.store_id = new.store_id
  where lower(coalesce(item.value->>'is_repair', 'false')) = 'true'
  order by item.ordinality, sales_order.created_at, sales_order.id
  limit 1;
  if not found or earlier.invoice_number = new.invoice_number then return new; end if;

  -- Hand back the number this checkout just took, so the sequence has no gap.
  -- The counter row is still locked by the checkout that bumped it.
  update public.pos_store_invoice_counters
  set last_number = last_number - 1, updated_at = now()
  where store_id = new.store_id and last_number = new.invoice_number;

  perform 1 from public.pos_sales_orders where id = earlier.id for update;
  select coalesce(max(sales_order.invoice_part), 0) + 1 into new.invoice_part
  from public.pos_sales_orders sales_order
  where sales_order.store_id = new.store_id
    and sales_order.invoice_number = earlier.invoice_number;
  new.invoice_number := earlier.invoice_number;
  return new;
end;
$$;

revoke all on function public.pos_sales_order_reuse_repair_invoice_number() from public, anon, authenticated;

drop trigger if exists pos_sales_orders_reuse_repair_invoice_number on public.pos_sales_orders;
create trigger pos_sales_orders_reuse_repair_invoice_number
  before insert on public.pos_sales_orders
  for each row execute function public.pos_sales_order_reuse_repair_invoice_number();

-- The checkout functions pass the counter value they took, which the trigger
-- may have replaced. Read the number off the saved order instead.
create or replace function public.close_pos_repair_tickets_for_order(target_order_id bigint, acting_staff_name text, target_invoice_number bigint, target_customer_name text, target_customer_phone text, should_close boolean)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  saved_invoice_number bigint;
begin
  select coalesce(sales_order.invoice_number, target_invoice_number) into saved_invoice_number
  from public.pos_sales_orders sales_order
  where sales_order.id = target_order_id;

  update public.pos_repair_tickets repair_ticket
  set
    customer_name = target_customer_name,
    customer_phone = target_customer_phone,
    customer_contact = target_customer_phone,
    updated_by = acting_staff_name,
    updated_at = now(),
    activity = jsonb_build_array(jsonb_build_object(
      'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'type', 'paid',
      'text', 'billed work on invoice #' || coalesce(saved_invoice_number, target_invoice_number) || ' and left the repair card open',
      'staffName', acting_staff_name,
      'at', now()
    )) || coalesce(repair_ticket.activity, '[]'::jsonb)
  where repair_ticket.id in (
    select distinct sales_line.repair_ticket_id
    from public.pos_sales_order_lines sales_line
    where sales_line.sales_order_id = target_order_id
      and sales_line.repair_ticket_id is not null
  )
    and repair_ticket.closed_at is null;
end;
$function$;
