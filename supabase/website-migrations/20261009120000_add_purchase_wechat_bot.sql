-- Product project: a WeChat helper on a shop PC reads the supplier groups and
-- sends new messages to admin-purchasing, which records the domestic parcels.
-- The helper signs in with a token (only its SHA-256 hash is stored), reports
-- the chats it can see, and gets back the groups the admin chose to watch.

create table if not exists public.purchase_wechat_groups (
  id bigint generated always as identity primary key,
  group_name text not null,
  supplier_id bigint references public.suppliers(id) on delete set null,
  watch boolean not null default false,
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint purchase_wechat_groups_name_present check (btrim(group_name) <> '')
);
create unique index if not exists purchase_wechat_groups_name_key on public.purchase_wechat_groups (group_name);

create table if not exists public.purchase_bot_tokens (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  label text not null default 'WeChat helper',
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);

create table if not exists public.purchase_bot_status (
  id integer primary key default 1 check (id = 1),
  last_seen_at timestamptz,
  state text,
  version text,
  detail jsonb not null default '{}'::jsonb
);

create table if not exists public.purchase_bot_events (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  group_name text not null,
  supplier_id bigint references public.suppliers(id) on delete set null,
  status text not null check (status in ('saved', 'nothing_new', 'not_watched', 'error')),
  messages jsonb not null default '[]'::jsonb,
  result jsonb not null default '{}'::jsonb,
  error text
);
create index if not exists purchase_bot_events_created_idx on public.purchase_bot_events (created_at desc);

drop trigger if exists set_updated_at_purchase_wechat_groups on public.purchase_wechat_groups;
create trigger set_updated_at_purchase_wechat_groups before update on public.purchase_wechat_groups
  for each row execute function public.set_updated_at();

alter table public.purchase_wechat_groups enable row level security;
alter table public.purchase_bot_tokens enable row level security;
alter table public.purchase_bot_status enable row level security;
alter table public.purchase_bot_events enable row level security;
revoke all on table public.purchase_wechat_groups from public, anon, authenticated;
revoke all on table public.purchase_bot_tokens from public, anon, authenticated;
revoke all on table public.purchase_bot_status from public, anon, authenticated;
revoke all on table public.purchase_bot_events from public, anon, authenticated;
grant all on table public.purchase_wechat_groups to service_role;
grant all on table public.purchase_bot_tokens to service_role;
grant all on table public.purchase_bot_status to service_role;
grant all on table public.purchase_bot_events to service_role;

create or replace function public.purchase_bot_token_valid(token_hash text)
returns boolean
language plpgsql
set search_path = ''
as $$
begin
  update public.purchase_bot_tokens token
  set last_used_at = now()
  where token.token_hash = purchase_bot_token_valid.token_hash and token.revoked_at is null;
  return found;
end;
$$;

-- The helper reports the chat names it can see (names only, no message text)
-- and gets back the groups to watch.
create or replace function public.purchase_bot_heartbeat(payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  insert into public.purchase_bot_status (id, last_seen_at, state, version, detail)
  values (
    1,
    now(),
    left(public.purchase_text(payload->'state'), 40),
    left(public.purchase_text(payload->'version'), 40),
    case when jsonb_typeof(payload->'detail') = 'object' then payload->'detail' else '{}'::jsonb end
  )
  on conflict (id) do update
  set last_seen_at = excluded.last_seen_at, state = excluded.state, version = excluded.version, detail = excluded.detail;

  if jsonb_typeof(payload->'groups') = 'array' then
    insert into public.purchase_wechat_groups (group_name, last_seen_at)
    select distinct left(btrim(name), 120), now()
    from (
      select value as name
      from jsonb_array_elements_text(payload->'groups')
      limit 200
    ) seen
    where btrim(name) <> ''
    on conflict (group_name) do update set last_seen_at = excluded.last_seen_at;
  end if;

  return jsonb_build_object(
    'ok', true,
    'watch', coalesce((
      select jsonb_agg(chat.group_name order by chat.group_name)
      from public.purchase_wechat_groups chat
      where chat.watch
    ), '[]'::jsonb)
  );
end;
$$;

-- Where a message from this group belongs: its supplier and that supplier's
-- newest order whose goods have not all been counted into stock.
create or replace function public.purchase_bot_group_target(group_name text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object(
      'watch', chat.watch,
      'supplier_id', chat.supplier_id,
      'supplier_name', supplier.name,
      'order_id', open_order.id,
      'po_number', open_order.po_number
    )
    from public.purchase_wechat_groups chat
    left join public.suppliers supplier on supplier.id = chat.supplier_id
    left join lateral (
      select purchase_order.id, purchase_order.po_number
      from public.purchase_orders purchase_order
      where purchase_order.supplier_id = chat.supplier_id
        and purchase_order.cancelled_at is null
        and purchase_order.created_at > now() - interval '90 days'
        and (
          not exists (select 1 from public.purchase_parcels parcel where parcel.purchase_order_id = purchase_order.id)
          or exists (
            select 1
            from public.purchase_parcels parcel
            left join public.purchase_shipments shipment on shipment.id = parcel.shipment_id
            where parcel.purchase_order_id = purchase_order.id
              and (shipment.id is null or shipment.status not in ('stocked', 'closed'))
          )
        )
      order by purchase_order.id desc
      limit 1
    ) open_order on true
    where chat.group_name = purchase_bot_group_target.group_name
  ), jsonb_build_object('watch', false));
$$;

create or replace function public.purchase_bot_log_event(payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  saved_id bigint;
begin
  insert into public.purchase_bot_events (group_name, supplier_id, status, messages, result, error)
  values (
    coalesce(left(public.purchase_text(payload->'group_name'), 120), '(unknown)'),
    public.purchase_bigint(payload->'supplier_id'),
    public.purchase_text(payload->'status'),
    case when jsonb_typeof(payload->'messages') = 'array' then payload->'messages' else '[]'::jsonb end,
    case when jsonb_typeof(payload->'result') = 'object' then payload->'result' else '{}'::jsonb end,
    left(public.purchase_text(payload->'error'), 1000)
  )
  returning id into saved_id;

  delete from public.purchase_bot_events event where event.created_at < now() - interval '120 days';
  return jsonb_build_object('ok', true, 'id', saved_id);
end;
$$;

create or replace function public.purchase_admin_save_wechat_group(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  target_id bigint := public.purchase_bigint(payload->'id');
  supplier bigint := public.purchase_bigint(payload->'supplier_id');
  chat public.purchase_wechat_groups%rowtype;
begin
  perform public.purchase_actor(actor);
  select * into chat from public.purchase_wechat_groups where id = target_id for update;
  if not found then raise exception 'WeChat group not found.'; end if;

  if coalesce((payload->>'create_supplier')::boolean, false) and supplier is null then
    insert into public.suppliers (name, wechat, platform, is_active)
    values (chat.group_name, chat.group_name, '微信', true)
    returning id into supplier;
  elsif supplier is not null and not exists (select 1 from public.suppliers where id = supplier) then
    raise exception 'Supplier not found.';
  end if;

  update public.purchase_wechat_groups
  set
    supplier_id = supplier,
    watch = coalesce((payload->>'watch')::boolean, watch)
  where id = target_id;

  return jsonb_build_object('ok', true, 'id', target_id, 'supplier_id', supplier);
end;
$$;

-- The helper prints a fingerprint (SHA-256 of its token) on first run; the admin
-- pastes it on the page to let that PC in, and can turn a PC off again.
create or replace function public.purchase_admin_register_bot_token(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  fingerprint text := lower(btrim(coalesce(public.purchase_text(payload->'token_hash'), '')));
  pc_label text := left(public.purchase_text(payload->'label'), 60);
begin
  perform public.purchase_actor(actor);
  if fingerprint !~ '^[0-9a-f]{64}$' then
    raise exception 'The helper fingerprint must be 64 letters and digits.';
  end if;
  insert into public.purchase_bot_tokens as token (token_hash, label)
  values (fingerprint, coalesce(pc_label, 'WeChat helper'))
  on conflict (token_hash) do update set label = coalesce(pc_label, token.label), revoked_at = null;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.purchase_admin_revoke_bot_token(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform public.purchase_actor(actor);
  update public.purchase_bot_tokens token
  set revoked_at = now()
  where token.token_hash = lower(btrim(coalesce(public.purchase_text(payload->'token_hash'), '')))
    and token.revoked_at is null;
  if not found then raise exception 'Helper PC not found.'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.purchase_admin_snapshot()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'suppliers', coalesce((
      select jsonb_agg(to_jsonb(supplier) order by supplier.is_active desc, lower(supplier.name))
      from (
        select id, name, contact_name, email, phone, wechat, platform, website_url, notes, is_active
        from public.suppliers
      ) supplier
    ), '[]'::jsonb),
    'forwarders', coalesce((
      select jsonb_agg(to_jsonb(forwarder) order by forwarder.sort_order, forwarder.id)
      from (
        select id, name, tracking_url, website_url, warehouse_address, contact, channels,
          tracking_prefixes, ship_threshold_kg, notes, is_active, sort_order
        from public.purchase_forwarders
      ) forwarder
    ), '[]'::jsonb),
    'stores', coalesce((
      select jsonb_agg(jsonb_build_object('id', store.id, 'slug', store.slug, 'name', store.name) order by store.id)
      from public.stores store
      where store.is_active
    ), '[]'::jsonb),
    'pos_categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', taxonomy.id,
        'category_name', taxonomy.category_name,
        'subcategory_name', taxonomy.subcategory_name
      ) order by taxonomy.category_sort, taxonomy.subcategory_sort, taxonomy.id)
      from public.pos_category_taxonomy taxonomy
      where taxonomy.active
    ), '[]'::jsonb),
    'orders', coalesce((
      select jsonb_agg(to_jsonb(purchase_order) || jsonb_build_object('items', coalesce((
        select jsonb_agg(to_jsonb(item) || jsonb_build_object(
          'product_sku', product.sku,
          'product_name', product.name,
          'received_quantity', coalesce((
            select sum(line.quantity + line.damaged_quantity)
            from public.purchase_receipt_lines line
            where line.purchase_order_item_id = item.id
          ), 0)
        ) order by item.line_no, item.id)
        from public.purchase_order_items item
        left join public.products product on product.id = item.product_id
        where item.purchase_order_id = purchase_order.id
      ), '[]'::jsonb)) order by purchase_order.id desc)
      from public.purchase_orders purchase_order
    ), '[]'::jsonb),
    'parcels', coalesce((
      select jsonb_agg(to_jsonb(parcel) order by parcel.id desc)
      from public.purchase_parcels parcel
    ), '[]'::jsonb),
    'shipments', coalesce((
      select jsonb_agg(to_jsonb(shipment) order by shipment.id desc)
      from public.purchase_shipments shipment
    ), '[]'::jsonb),
    'receipt_lines', coalesce((
      select jsonb_agg(to_jsonb(line) || jsonb_build_object(
        'product_sku', product.sku,
        'product_name', product.name,
        'store_name', store.name
      ) order by line.id)
      from public.purchase_receipt_lines line
      join public.products product on product.id = line.product_id
      join public.stores store on store.id = line.store_id
    ), '[]'::jsonb),
    'wechat_groups', coalesce((
      select jsonb_agg(to_jsonb(chat) order by chat.watch desc, chat.last_seen_at desc nulls last, chat.group_name)
      from (
        select id, group_name, supplier_id, watch, last_seen_at
        from public.purchase_wechat_groups
      ) chat
    ), '[]'::jsonb),
    'bot_status', (
      select to_jsonb(status) - 'id'
      from public.purchase_bot_status status
      where status.id = 1
    ),
    'bot_tokens', coalesce((
      select jsonb_agg(to_jsonb(token) order by token.revoked_at nulls first, token.created_at desc)
      from (
        select token_hash, label, created_at, last_used_at, revoked_at
        from public.purchase_bot_tokens
      ) token
    ), '[]'::jsonb),
    'bot_events', coalesce((
      select jsonb_agg(to_jsonb(event) order by event.id desc)
      from (
        select id, created_at, group_name, supplier_id, status, result, error,
          jsonb_array_length(messages) as message_count
        from public.purchase_bot_events
        order by id desc
        limit 30
      ) event
    ), '[]'::jsonb)
  );
$$;

-- Same as before, plus `source` so the helper's parcels are marked wechat_bot.
create or replace function public.purchase_admin_import_chat(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  actor_name text := public.purchase_actor(actor);
  order_id bigint := public.purchase_bigint(payload->'order_id');
  supplier bigint := public.purchase_bigint(payload->'supplier_id');
  forwarder bigint := public.purchase_bigint(payload->'forwarder_id');
  order_forwarder bigint;
  record_source text := coalesce(public.purchase_text(payload->'source'), 'chat');
  items jsonb := coalesce(payload->'items', '[]'::jsonb);
  parcels jsonb := coalesce(payload->'parcels', '[]'::jsonb);
  today date := (timezone('Australia/Brisbane', now()))::date;
  item jsonb;
  parcel jsonb;
  item_index integer := 0;
  next_line integer;
  tracking text;
  seen text[] := '{}';
  skipped text[] := '{}';
  created bigint[] := '{}';
  new_parcel bigint;
  order_number text;
begin
  if record_source not in ('chat', 'wechat_bot') then
    raise exception 'Invalid import source.';
  end if;
  if jsonb_typeof(items) <> 'array' or jsonb_typeof(parcels) <> 'array' then
    raise exception 'Order items must be a list.';
  end if;
  if order_id is null and jsonb_array_length(items) = 0 and jsonb_array_length(parcels) = 0 then
    raise exception 'Order lines or tracking numbers are required.';
  end if;
  if supplier is not null and not exists (select 1 from public.suppliers where id = supplier) then
    raise exception 'Supplier not found.';
  end if;
  if forwarder is not null and not exists (select 1 from public.purchase_forwarders where id = forwarder) then
    raise exception 'Forwarder not found.';
  end if;

  for item in select value from jsonb_array_elements(items)
  loop
    item_index := item_index + 1;
    if public.purchase_text(item->'description') is null then
      raise exception 'Order line % needs a description.', item_index;
    end if;
    if coalesce(public.purchase_bigint(item->'quantity'), 0) <= 0 then
      raise exception 'Order line % needs a quantity above zero.', item_index;
    end if;
  end loop;

  if order_id is not null then
    update public.purchase_orders purchase_order
    set
      supplier_id = coalesce(purchase_order.supplier_id, supplier),
      forwarder_id = coalesce(purchase_order.forwarder_id, forwarder)
    where purchase_order.id = order_id
    returning purchase_order.supplier_id, purchase_order.forwarder_id into supplier, order_forwarder;
    if not found then raise exception 'Purchase order not found.'; end if;
  elsif jsonb_array_length(items) > 0 then
    insert into public.purchase_orders (
      supplier_id, forwarder_id, supplier_order_ref, order_date, currency, goods_amount,
      domestic_shipping_amount, notes, source, created_by
    )
    values (
      supplier,
      forwarder,
      public.purchase_text(payload->'supplier_order_ref'),
      coalesce(public.purchase_date(payload->'order_date'), today),
      coalesce(public.purchase_text(payload->'currency'), 'CNY'),
      public.purchase_numeric(payload->'goods_amount'),
      coalesce(public.purchase_numeric(payload->'domestic_shipping_amount'), 0),
      public.purchase_text(payload->'notes'),
      record_source,
      actor_name
    )
    returning id into order_id;
  end if;

  if order_id is not null and jsonb_array_length(items) > 0 then
    select coalesce(max(order_item.line_no), 0) into next_line
    from public.purchase_order_items order_item
    where order_item.purchase_order_id = order_id;

    for item in select value from jsonb_array_elements(items)
    loop
      next_line := next_line + 1;
      insert into public.purchase_order_items (purchase_order_id, line_no, description, quantity, unit_cost, notes)
      values (
        order_id,
        next_line,
        public.purchase_text(item->'description'),
        public.purchase_bigint(item->'quantity')::integer,
        public.purchase_numeric(item->'unit_cost'),
        public.purchase_text(item->'notes')
      );
    end loop;
  end if;

  for parcel in select value from jsonb_array_elements(parcels)
  loop
    tracking := nullif(regexp_replace(coalesce(public.purchase_text(parcel->'tracking_no'), ''), '\s+', '', 'g'), '');
    if tracking is null and public.purchase_text(parcel->'contents') is null then
      continue;
    end if;
    if tracking is not null and (
      lower(tracking) = any(seen)
      or exists (select 1 from public.purchase_parcels existing where lower(existing.tracking_no) = lower(tracking))
    ) then
      skipped := skipped || tracking;
      continue;
    end if;
    if tracking is not null then seen := seen || lower(tracking); end if;

    insert into public.purchase_parcels (
      purchase_order_id, supplier_id, contents, courier, tracking_no, carton_count, shipped_at,
      forwarder_id, declared_value, has_battery, has_magnet, weight_kg, notes, source, created_by
    )
    values (
      order_id,
      supplier,
      coalesce(public.purchase_text(parcel->'contents'), ''),
      public.purchase_text(parcel->'courier'),
      tracking,
      coalesce(public.purchase_bigint(parcel->'carton_count')::integer, 1),
      coalesce(public.purchase_date(parcel->'shipped_at'), today),
      coalesce(forwarder, order_forwarder),
      public.purchase_numeric(parcel->'declared_value'),
      coalesce((parcel->>'has_battery')::boolean, false),
      coalesce((parcel->>'has_magnet')::boolean, false),
      public.purchase_numeric(parcel->'weight_kg'),
      public.purchase_text(parcel->'notes'),
      record_source,
      actor_name
    )
    returning id into new_parcel;
    created := created || new_parcel;
  end loop;

  select purchase_order.po_number into order_number
  from public.purchase_orders purchase_order
  where purchase_order.id = order_id;

  return jsonb_build_object(
    'ok', true,
    'order_id', order_id,
    'po_number', order_number,
    'parcel_ids', to_jsonb(created),
    'skipped', to_jsonb(skipped)
  );
end;
$$;

revoke execute on function public.purchase_bot_token_valid(text) from public, anon, authenticated;
revoke execute on function public.purchase_bot_heartbeat(jsonb) from public, anon, authenticated;
revoke execute on function public.purchase_bot_group_target(text) from public, anon, authenticated;
revoke execute on function public.purchase_bot_log_event(jsonb) from public, anon, authenticated;
revoke execute on function public.purchase_admin_save_wechat_group(jsonb, text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_register_bot_token(jsonb, text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_revoke_bot_token(jsonb, text) from public, anon, authenticated;
grant execute on function public.purchase_admin_register_bot_token(jsonb, text) to service_role;
grant execute on function public.purchase_admin_revoke_bot_token(jsonb, text) to service_role;
grant execute on function public.purchase_bot_token_valid(text) to service_role;
grant execute on function public.purchase_bot_heartbeat(jsonb) to service_role;
grant execute on function public.purchase_bot_group_target(text) to service_role;
grant execute on function public.purchase_bot_log_event(jsonb) to service_role;
grant execute on function public.purchase_admin_save_wechat_group(jsonb, text) to service_role;
