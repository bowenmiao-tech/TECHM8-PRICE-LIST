-- What a device actually cost, not just what was paid for it.
--
-- Margin was purchase price against sale price. Everything spent making a
-- device sellable -- a screen, a battery, an hour of bench time, an external
-- data recovery -- was invisible, so a device could look profitable while
-- losing money. Costs are now recorded against the device and every margin
-- figure uses purchase price plus refurbishment.
--
-- Parts are recorded here as an amount, not deducted from product inventory.
-- Product stock lives in the separate website/product project, so a real
-- deduction is a cross-project change and is deliberately not attempted here.
-- The `repair_ticket_code` column is the link to follow when it is.

create table public.pos_used_device_costs (
  id uuid primary key,
  device_id bigint not null references public.pos_used_devices(id) on delete restrict,
  kind text not null check (kind in ('part', 'labour', 'external')),
  description text not null check (length(btrim(description)) > 0 and length(description) <= 300),
  amount numeric(12,2) not null check (amount > 0),
  repair_ticket_code text not null default '',
  staff_name text not null,
  created_at timestamptz not null default now()
);

create index pos_used_device_costs_device_idx
  on public.pos_used_device_costs (device_id, created_at desc);

alter table public.pos_used_device_costs enable row level security;
revoke all on public.pos_used_device_costs from public, anon, authenticated;
grant all on public.pos_used_device_costs to service_role;

create or replace function public.pos_used_device_refurb_cost(target_device_id bigint)
returns numeric
language sql
stable
set search_path = ''
as $$
  select round(coalesce(sum(cost.amount), 0), 2)
  from public.pos_used_device_costs cost
  where cost.device_id = target_device_id;
$$;

create or replace function public.get_pos_used_device_costs(session_token text, store_code text, device_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  context jsonb;
  device_id_value bigint;
  result jsonb;
begin
  context := public.authorize_pos_used_device_evidence(session_token, store_code, device_code);
  device_id_value := (context->>'device_id')::bigint;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', cost.id, 'kind', cost.kind, 'description', cost.description,
    'amount', cost.amount, 'repair_ticket_code', cost.repair_ticket_code,
    'staff_name', cost.staff_name, 'created_at', cost.created_at
  ) order by cost.created_at desc, cost.id), '[]'::jsonb) into result
  from public.pos_used_device_costs cost
  where cost.device_id = device_id_value;

  return jsonb_build_object(
    'ok', true,
    'costs', result,
    'refurb_cost', public.pos_used_device_refurb_cost(device_id_value),
    'writable', context->'writable'
  );
end;
$$;

create or replace function public.add_pos_used_device_cost(session_token text, store_code text, device_code text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  context jsonb;
  cost_id uuid := (payload->>'id')::uuid;
  device_id_value bigint;
  kind_value text := coalesce(nullif(btrim(payload->>'kind'), ''), 'part');
  description_value text := btrim(coalesce(payload->>'description', ''));
  amount_value numeric(12,2) := round(coalesce(nullif(payload->>'amount', '')::numeric, 0), 2);
  existing public.pos_used_device_costs%rowtype;
begin
  context := public.authorize_pos_used_device_evidence(session_token, store_code, device_code);
  if not (context->>'writable')::boolean then raise exception 'Closed device records are read-only'; end if;
  device_id_value := (context->>'device_id')::bigint;
  if cost_id is null then raise exception 'Cost ID is required'; end if;
  if kind_value not in ('part', 'labour', 'external') then raise exception 'Invalid cost type'; end if;
  if description_value = '' or length(description_value) > 300 then raise exception 'Describe the cost in up to 300 characters'; end if;
  if amount_value <= 0 then raise exception 'A cost must be above zero'; end if;

  -- A retry after an uncertain response must not add the cost twice.
  select * into existing from public.pos_used_device_costs where id = cost_id;
  if found then
    if existing.device_id <> device_id_value then raise exception 'Cost ID already used'; end if;
    return jsonb_build_object('ok', true, 'id', existing.id);
  end if;

  insert into public.pos_used_device_costs(id, device_id, kind, description, amount, repair_ticket_code, staff_name)
  values (
    cost_id, device_id_value, kind_value, description_value, amount_value,
    left(btrim(coalesce(payload->>'repair_ticket_code', '')), 100), context->>'author'
  );

  return jsonb_build_object(
    'ok', true,
    'id', cost_id,
    'refurb_cost', public.pos_used_device_refurb_cost(device_id_value)
  );
end;
$$;

revoke all on function public.pos_used_device_refurb_cost(bigint) from public, anon, authenticated;
revoke all on function public.get_pos_used_device_costs(text, text, text) from public, anon, authenticated;
revoke all on function public.add_pos_used_device_cost(text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.pos_used_device_refurb_cost(bigint) to service_role;
grant execute on function public.get_pos_used_device_costs(text, text, text) to service_role;
grant execute on function public.add_pos_used_device_cost(text, text, text, jsonb) to service_role;

-- The device payload carries the true cost, so every screen showing a device
-- shows what it really cost rather than only the payout.
do $migration$
declare
  definition text;
  patched text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'pos_used_device_payload' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'pos_used_device_payload was not found'; end if;

  patched := replace(
    definition,
    $anchor$    'purchase_cost', device_row.purchase_cost,$anchor$,
    $replacement$    'purchase_cost', device_row.purchase_cost,
    'refurb_cost', public.pos_used_device_refurb_cost(device_row.id),
    'total_cost', round(device_row.purchase_cost + public.pos_used_device_refurb_cost(device_row.id), 2),$replacement$
  );
  if patched = definition then
    raise exception 'refurbishment cost patch: the payload anchor was not found';
  end if;
  execute patched;
end;
$migration$;

-- Stock value and realised margin follow the same definition of cost.
do $migration$
declare
  definition text;
  patched text;
  previous text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'search_pos_used_devices' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'search_pos_used_devices was not found'; end if;

  patched := definition;

  previous := patched;
  patched := replace(
    patched,
    $anchor$        'stock_cost', coalesce(sum(purchase_cost) filter (where status in ('inspection', 'ready_for_sale')), 0),$anchor$,
    $replacement$        'stock_cost', coalesce(sum(purchase_cost + public.pos_used_device_refurb_cost(used_device.id)) filter (where status in ('inspection', 'ready_for_sale')), 0),$replacement$
  );
  if patched = previous then
    raise exception 'refurbishment cost patch: the stock cost anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$        'realized_margin', coalesce(sum(sale_transaction.amount - used_device.purchase_cost) filter (where used_device.status = 'sold'), 0)$anchor$,
    $replacement$        'realized_margin', coalesce(sum(sale_transaction.amount - used_device.purchase_cost - public.pos_used_device_refurb_cost(used_device.id)) filter (where used_device.status = 'sold'), 0)$replacement$
  );
  if patched = previous then
    raise exception 'refurbishment cost patch: the realized margin anchor was not found';
  end if;

  execute patched;
end;
$migration$;

-- Selling under cost stays possible, but it has to be said out loud. The
-- reason is what the ledger records, and it is what the admin alert reads.
do $migration$
declare
  definition text;
  patched text;
  previous text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'update_pos_used_device' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'update_pos_used_device was not found'; end if;

  patched := definition;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  change_note_value text := trim(coalesce(payload->>'change_note', ''));$anchor$,
    $replacement$  change_note_value text := trim(coalesce(payload->>'change_note', ''));
  below_cost_reason_value text := trim(coalesce(payload->>'below_cost_reason', ''));
  total_cost_value numeric(12,2);$replacement$
  );
  if patched = previous then
    raise exception 'below cost patch: the declaration anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  if price_value <= 0 then raise exception 'Sale price must be above zero'; end if;$anchor$,
    $replacement$  if price_value <= 0 then raise exception 'Sale price must be above zero'; end if;
  total_cost_value := round(device_row.purchase_cost + public.pos_used_device_refurb_cost(device_row.id), 2);
  -- Only a deliberate move to a losing price needs a reason. Adding a repair
  -- cost later can put an existing price under water, and that must not block
  -- an unrelated status change.
  if price_value <> device_row.sale_price and price_value < total_cost_value and below_cost_reason_value = '' then
    raise exception 'This price is below the % this device has cost. Record a reason to price it there', total_cost_value;
  end if;$replacement$
  );
  if patched = previous then
    raise exception 'below cost patch: the price validation anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$      coalesce(nullif(change_note_value, ''), 'Sale price updated'),
      jsonb_build_object('previous_price', previous_price, 'sale_price', device_row.sale_price)$anchor$,
    $replacement$      coalesce(nullif(below_cost_reason_value, ''), nullif(change_note_value, ''), 'Sale price updated'),
      jsonb_build_object('previous_price', previous_price, 'sale_price', device_row.sale_price,
        'total_cost', total_cost_value, 'below_cost', device_row.sale_price < total_cost_value,
        'below_cost_reason', below_cost_reason_value)$replacement$
  );
  if patched = previous then
    raise exception 'below cost patch: the price ledger anchor was not found';
  end if;

  execute patched;
end;
$migration$;

comment on table public.pos_used_device_costs is
  'Money spent making a second-hand device sellable. Purchase price plus these costs is the figure every margin uses.';
