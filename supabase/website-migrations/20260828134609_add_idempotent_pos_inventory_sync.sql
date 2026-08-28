-- Idempotent POS inventory synchronization.
-- The staff-order database remains the source of truth for invoices and
-- refunds. This database stores only the net stock effect already applied for
-- each order/product, so retries cannot double-deduct or double-return stock.

create table if not exists public.pos_inventory_sync_settings (
  singleton boolean primary key default true check (singleton),
  started_at timestamptz not null,
  updated_at timestamptz not null default now()
);

insert into public.pos_inventory_sync_settings (singleton, started_at)
values (true, now() - interval '10 minutes')
on conflict (singleton) do nothing;

create table if not exists public.pos_inventory_order_effects (
  order_code text not null,
  store_id bigint not null references public.stores(id) on delete restrict,
  product_id bigint not null references public.products(id) on delete restrict,
  sold_quantity integer not null default 0 check (sold_quantity >= 0),
  returned_quantity integer not null default 0 check (returned_quantity >= 0),
  applied_delta integer not null default 0,
  revision integer not null default 0 check (revision >= 0),
  actor_staff_name text not null,
  order_created_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (order_code, store_id, product_id),
  check (returned_quantity <= sold_quantity),
  check (applied_delta = returned_quantity - sold_quantity)
);

create index if not exists pos_inventory_order_effects_store_updated_idx
on public.pos_inventory_order_effects (store_id, updated_at desc);

create table if not exists public.pos_inventory_order_movements (
  id bigint generated always as identity primary key,
  movement_key text not null unique,
  order_code text not null,
  store_id bigint not null references public.stores(id) on delete restrict,
  product_id bigint not null references public.products(id) on delete restrict,
  movement_type text not null check (movement_type in ('pos_sale', 'pos_refund_return', 'pos_reconcile')),
  quantity_delta integer not null check (quantity_delta <> 0),
  quantity_before integer not null check (quantity_before >= 0),
  quantity_after integer not null check (quantity_after >= 0),
  actor_staff_name text not null,
  created_at timestamptz not null default now(),
  check (quantity_after = quantity_before + quantity_delta)
);

create index if not exists pos_inventory_order_movements_store_created_idx
on public.pos_inventory_order_movements (store_id, created_at desc);

create index if not exists pos_inventory_order_movements_product_created_idx
on public.pos_inventory_order_movements (product_id, created_at desc);

alter table public.pos_inventory_sync_settings enable row level security;
alter table public.pos_inventory_order_effects enable row level security;
alter table public.pos_inventory_order_movements enable row level security;

revoke all on public.pos_inventory_sync_settings from public, anon, authenticated;
revoke all on public.pos_inventory_order_effects from public, anon, authenticated;
revoke all on public.pos_inventory_order_movements from public, anon, authenticated;
grant select, insert, update on public.pos_inventory_sync_settings to service_role;
grant select, insert, update on public.pos_inventory_order_effects to service_role;
grant select, insert on public.pos_inventory_order_movements to service_role;

create or replace function public.validate_pos_inventory_sale(
  target_store_slug text,
  target_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.stores%rowtype;
  shortages jsonb;
begin
  if jsonb_typeof(target_items) <> 'array' then
    raise exception 'Sale items must be an array';
  end if;

  select * into selected_store
  from public.stores store_row
  where store_row.is_active = true
    and store_row.slug = lower(btrim(coalesce(target_store_slug, '')))
  limit 1;
  if not found then raise exception 'Store not found'; end if;

  with requested as (
    select
      coalesce(item->>'product_id', item->>'id')::bigint as product_id,
      sum(coalesce(nullif(item->>'qty', '')::integer, 0))::integer as quantity
    from jsonb_array_elements(target_items) item
    where coalesce(item->>'product_id', item->>'id', '') ~ '^[0-9]+$'
      and lower(coalesce(item->>'is_repair', 'false')) <> 'true'
      and lower(coalesce(item->>'is_special', 'false')) <> 'true'
      and lower(coalesce(item->>'is_used_device', 'false')) <> 'true'
      and coalesce(item->>'line_type', 'product') not in ('repair', 'special', 'used_device')
    group by coalesce(item->>'product_id', item->>'id')::bigint
  ), checked as (
    select
      requested.product_id,
      requested.quantity as requested_quantity,
      coalesce(inventory.quantity, 0) as available_quantity,
      product.name,
      product.sku
    from requested
    left join public.products product on product.id = requested.product_id
    left join public.product_store_inventory inventory
      on inventory.product_id = requested.product_id
      and inventory.store_id = selected_store.id
    where requested.quantity <= 0
      or product.id is null
      or not product.is_pos_visible
      or coalesce(inventory.quantity, 0) < requested.quantity
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', checked.product_id,
    'name', coalesce(checked.name, 'Unknown product'),
    'sku', coalesce(checked.sku, ''),
    'requested', checked.requested_quantity,
    'available', checked.available_quantity
  ) order by checked.product_id), '[]'::jsonb)
  into shortages
  from checked;

  return jsonb_build_object(
    'ok', jsonb_array_length(shortages) = 0,
    'store_slug', selected_store.slug,
    'shortages', shortages
  );
end;
$$;

create or replace function public.apply_pos_inventory_order_effect(
  target_order_code text,
  target_store_slug text,
  target_staff_name text,
  target_order_created_at timestamptz,
  target_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.stores%rowtype;
  sync_started_at timestamptz;
  row_data record;
  inventory_row public.product_store_inventory%rowtype;
  effect_row public.pos_inventory_order_effects%rowtype;
  desired_delta integer;
  delta_to_apply integer;
  next_revision integer;
  affected_product_ids bigint[] := array[]::bigint[];
  results jsonb := '[]'::jsonb;
begin
  if coalesce(btrim(target_order_code), '') = '' then raise exception 'Order code is required'; end if;
  if coalesce(btrim(target_staff_name), '') = '' then raise exception 'Staff name is required'; end if;
  if target_order_created_at is null then raise exception 'Order creation time is required'; end if;
  if jsonb_typeof(target_items) <> 'array' then raise exception 'Order items must be an array'; end if;

  select setting.started_at into sync_started_at
  from public.pos_inventory_sync_settings setting
  where setting.singleton = true;
  if target_order_created_at < sync_started_at then
    return jsonb_build_object('ok', true, 'ignored', true, 'reason', 'Order predates POS inventory synchronization.');
  end if;

  select * into selected_store
  from public.stores store_row
  where store_row.is_active = true
    and store_row.slug = lower(btrim(coalesce(target_store_slug, '')))
  limit 1;
  if not found then raise exception 'Store not found'; end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('pos-inventory:' || selected_store.id || ':' || btrim(target_order_code), 0)
  );

  for row_data in
    select
      coalesce(item->>'product_id', item->>'id')::bigint as product_id,
      sum(coalesce(nullif(item->>'qty', '')::integer, 0))::integer as sold_quantity,
      sum(coalesce(nullif(item->>'refunded_quantity', '')::integer, 0))::integer as returned_quantity
    from jsonb_array_elements(target_items) item
    where coalesce(item->>'product_id', item->>'id', '') ~ '^[0-9]+$'
      and lower(coalesce(item->>'is_repair', 'false')) <> 'true'
      and lower(coalesce(item->>'is_special', 'false')) <> 'true'
      and lower(coalesce(item->>'is_used_device', 'false')) <> 'true'
      and coalesce(item->>'line_type', 'product') not in ('repair', 'special', 'used_device')
    group by coalesce(item->>'product_id', item->>'id')::bigint
    order by coalesce(item->>'product_id', item->>'id')::bigint
  loop
    if row_data.sold_quantity <= 0 then raise exception 'Product quantity must be above zero'; end if;
    if row_data.returned_quantity < 0 or row_data.returned_quantity > row_data.sold_quantity then
      raise exception 'Returned quantity is invalid for product %', row_data.product_id;
    end if;
    if not exists (
      select 1 from public.products product
      where product.id = row_data.product_id and product.is_pos_visible = true
    ) then raise exception 'Product % is unavailable in POS', row_data.product_id; end if;

    insert into public.product_store_inventory (product_id, store_id, quantity, updated_at)
    values (row_data.product_id, selected_store.id, 0, now())
    on conflict (product_id, store_id) do nothing;

    select * into inventory_row
    from public.product_store_inventory inventory
    where inventory.product_id = row_data.product_id
      and inventory.store_id = selected_store.id
    for update;

    select * into effect_row
    from public.pos_inventory_order_effects effect
    where effect.order_code = btrim(target_order_code)
      and effect.store_id = selected_store.id
      and effect.product_id = row_data.product_id
    for update;

    desired_delta := row_data.returned_quantity - row_data.sold_quantity;
    delta_to_apply := desired_delta - coalesce(effect_row.applied_delta, 0);
    next_revision := coalesce(effect_row.revision, 0) + case when delta_to_apply <> 0 then 1 else 0 end;

    if inventory_row.quantity + delta_to_apply < 0 then
      raise exception 'Insufficient stock for product %: requested %, available %',
        row_data.product_id, abs(delta_to_apply), inventory_row.quantity;
    end if;

    if delta_to_apply <> 0 then
      update public.product_store_inventory inventory
      set quantity = inventory.quantity + delta_to_apply,
          updated_at = now()
      where inventory.id = inventory_row.id
      returning * into inventory_row;

      insert into public.pos_inventory_order_movements (
        movement_key, order_code, store_id, product_id, movement_type,
        quantity_delta, quantity_before, quantity_after, actor_staff_name
      ) values (
        'pos:' || btrim(target_order_code) || ':' || row_data.product_id || ':r' || next_revision,
        btrim(target_order_code), selected_store.id, row_data.product_id,
        case
          when delta_to_apply < 0 then 'pos_sale'
          when effect_row.order_code is null then 'pos_reconcile'
          else 'pos_refund_return'
        end,
        delta_to_apply,
        inventory_row.quantity - delta_to_apply,
        inventory_row.quantity,
        btrim(target_staff_name)
      );
    end if;

    insert into public.pos_inventory_order_effects (
      order_code, store_id, product_id, sold_quantity, returned_quantity,
      applied_delta, revision, actor_staff_name, order_created_at, updated_at
    ) values (
      btrim(target_order_code), selected_store.id, row_data.product_id,
      row_data.sold_quantity, row_data.returned_quantity,
      desired_delta, next_revision, btrim(target_staff_name), target_order_created_at, now()
    )
    on conflict (order_code, store_id, product_id) do update set
      sold_quantity = excluded.sold_quantity,
      returned_quantity = excluded.returned_quantity,
      applied_delta = excluded.applied_delta,
      revision = excluded.revision,
      actor_staff_name = excluded.actor_staff_name,
      updated_at = now();

    affected_product_ids := array_append(affected_product_ids, row_data.product_id);
    results := results || jsonb_build_array(jsonb_build_object(
      'product_id', row_data.product_id,
      'quantity', inventory_row.quantity,
      'applied_delta', desired_delta,
      'changed_by', delta_to_apply
    ));
  end loop;

  if coalesce(array_length(affected_product_ids, 1), 0) > 0 then
    perform public.refresh_product_stock_totals(affected_product_ids);
  end if;

  return jsonb_build_object(
    'ok', true,
    'ignored', false,
    'order_code', btrim(target_order_code),
    'store_slug', selected_store.slug,
    'inventory', results
  );
end;
$$;

revoke all on function public.validate_pos_inventory_sale(text, jsonb) from public, anon, authenticated;
revoke all on function public.apply_pos_inventory_order_effect(text, text, text, timestamptz, jsonb) from public, anon, authenticated;
grant execute on function public.validate_pos_inventory_sale(text, jsonb) to service_role;
grant execute on function public.apply_pos_inventory_order_effect(text, text, text, timestamptz, jsonb) to service_role;
