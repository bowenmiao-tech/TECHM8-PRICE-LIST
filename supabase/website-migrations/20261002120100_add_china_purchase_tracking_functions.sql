-- Product project: service-role functions behind the admin-purchasing Edge Function.
-- Tables live in 20261002120000_add_china_purchase_tracking.sql.

create or replace function public.purchase_text(value jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim(case when jsonb_typeof(value) = 'string' then value #>> '{}' else value::text end), '')
  where value is not null and jsonb_typeof(value) <> 'null';
$$;

create or replace function public.purchase_bigint(value jsonb)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim(value #>> '{}'), '')::bigint
  where value is not null and jsonb_typeof(value) in ('number', 'string');
$$;

create or replace function public.purchase_numeric(value jsonb)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim(value #>> '{}'), '')::numeric
  where value is not null and jsonb_typeof(value) in ('number', 'string');
$$;

create or replace function public.purchase_date(value jsonb)
returns date
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim(value #>> '{}'), '')::date
  where value is not null and jsonb_typeof(value) = 'string';
$$;

create or replace function public.purchase_actor(actor text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  if nullif(btrim(coalesce(actor, '')), '') is null then
    raise exception 'Actor is required.';
  end if;
  return left(btrim(actor), 120);
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
          tracking_prefixes, notes, is_active, sort_order
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
    ), '[]'::jsonb)
  );
$$;

create or replace function public.purchase_admin_save_supplier(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  target_id bigint := public.purchase_bigint(payload->'id');
  supplier_name text := public.purchase_text(payload->'name');
  saved public.suppliers%rowtype;
begin
  perform public.purchase_actor(actor);
  if supplier_name is null then raise exception 'Supplier name is required.'; end if;

  if target_id is null then
    insert into public.suppliers (name, contact_name, email, phone, wechat, platform, website_url, notes, is_active)
    values (
      supplier_name,
      public.purchase_text(payload->'contact_name'),
      public.purchase_text(payload->'email'),
      public.purchase_text(payload->'phone'),
      public.purchase_text(payload->'wechat'),
      public.purchase_text(payload->'platform'),
      public.purchase_text(payload->'website_url'),
      public.purchase_text(payload->'notes'),
      coalesce((payload->>'is_active')::boolean, true)
    )
    returning * into saved;
  else
    update public.suppliers supplier
    set
      name = supplier_name,
      contact_name = public.purchase_text(payload->'contact_name'),
      email = public.purchase_text(payload->'email'),
      phone = public.purchase_text(payload->'phone'),
      wechat = public.purchase_text(payload->'wechat'),
      platform = public.purchase_text(payload->'platform'),
      website_url = public.purchase_text(payload->'website_url'),
      notes = public.purchase_text(payload->'notes'),
      is_active = coalesce((payload->>'is_active')::boolean, supplier.is_active)
    where supplier.id = target_id
    returning * into saved;
    if not found then raise exception 'Supplier not found.'; end if;
  end if;

  return jsonb_build_object('ok', true, 'id', saved.id);
end;
$$;

create or replace function public.purchase_admin_save_forwarder(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  target_id bigint := public.purchase_bigint(payload->'id');
  forwarder_name text := public.purchase_text(payload->'name');
  channel_list text[];
  prefix_list text[];
  saved_id bigint;
begin
  perform public.purchase_actor(actor);
  if forwarder_name is null then raise exception 'Forwarder name is required.'; end if;

  select coalesce(array_agg(btrim(value)) filter (where btrim(value) <> ''), '{}')
  into channel_list
  from jsonb_array_elements_text(coalesce(payload->'channels', '[]'::jsonb)) value;

  select coalesce(array_agg(upper(btrim(value))) filter (where btrim(value) <> ''), '{}')
  into prefix_list
  from jsonb_array_elements_text(coalesce(payload->'tracking_prefixes', '[]'::jsonb)) value;

  if target_id is null then
    insert into public.purchase_forwarders (
      name, tracking_url, website_url, warehouse_address, contact, channels, tracking_prefixes,
      notes, is_active, sort_order
    )
    values (
      forwarder_name,
      public.purchase_text(payload->'tracking_url'),
      public.purchase_text(payload->'website_url'),
      public.purchase_text(payload->'warehouse_address'),
      public.purchase_text(payload->'contact'),
      channel_list,
      prefix_list,
      public.purchase_text(payload->'notes'),
      coalesce((payload->>'is_active')::boolean, true),
      coalesce(public.purchase_bigint(payload->'sort_order')::integer,
        (select coalesce(max(sort_order), 0) + 10 from public.purchase_forwarders))
    )
    returning id into saved_id;
  else
    update public.purchase_forwarders forwarder
    set
      name = forwarder_name,
      tracking_url = public.purchase_text(payload->'tracking_url'),
      website_url = public.purchase_text(payload->'website_url'),
      warehouse_address = public.purchase_text(payload->'warehouse_address'),
      contact = public.purchase_text(payload->'contact'),
      channels = channel_list,
      tracking_prefixes = prefix_list,
      notes = public.purchase_text(payload->'notes'),
      is_active = coalesce((payload->>'is_active')::boolean, forwarder.is_active)
    where forwarder.id = target_id
    returning id into saved_id;
    if saved_id is null then raise exception 'Forwarder not found.'; end if;
  end if;

  return jsonb_build_object('ok', true, 'id', saved_id);
end;
$$;

create or replace function public.purchase_admin_save_order(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  actor_name text := public.purchase_actor(actor);
  target_id bigint := public.purchase_bigint(payload->'id');
  supplier bigint := public.purchase_bigint(payload->'supplier_id');
  item jsonb;
  item_id bigint;
  item_index integer := 0;
  kept_ids bigint[] := '{}';
  saved_id bigint;
begin
  if supplier is not null and not exists (select 1 from public.suppliers where id = supplier) then
    raise exception 'Supplier not found.';
  end if;
  if jsonb_typeof(coalesce(payload->'items', '[]'::jsonb)) <> 'array' then
    raise exception 'Order items must be a list.';
  end if;

  if target_id is null then
    insert into public.purchase_orders (
      supplier_id, supplier_order_ref, order_date, currency, goods_amount, domestic_shipping_amount,
      invoice_received_at, paid_amount, paid_at, payment_method, payment_ref, cancelled_at, notes, created_by
    )
    values (
      supplier,
      public.purchase_text(payload->'supplier_order_ref'),
      coalesce(public.purchase_date(payload->'order_date'), (timezone('Australia/Brisbane', now()))::date),
      coalesce(public.purchase_text(payload->'currency'), 'CNY'),
      public.purchase_numeric(payload->'goods_amount'),
      coalesce(public.purchase_numeric(payload->'domestic_shipping_amount'), 0),
      public.purchase_date(payload->'invoice_received_at'),
      public.purchase_numeric(payload->'paid_amount'),
      public.purchase_date(payload->'paid_at'),
      public.purchase_text(payload->'payment_method'),
      public.purchase_text(payload->'payment_ref'),
      case when coalesce((payload->>'cancelled')::boolean, false) then now() end,
      public.purchase_text(payload->'notes'),
      actor_name
    )
    returning id into saved_id;
  else
    update public.purchase_orders purchase_order
    set
      supplier_id = supplier,
      supplier_order_ref = public.purchase_text(payload->'supplier_order_ref'),
      order_date = coalesce(public.purchase_date(payload->'order_date'), purchase_order.order_date),
      currency = coalesce(public.purchase_text(payload->'currency'), purchase_order.currency),
      goods_amount = public.purchase_numeric(payload->'goods_amount'),
      domestic_shipping_amount = coalesce(public.purchase_numeric(payload->'domestic_shipping_amount'), 0),
      invoice_received_at = public.purchase_date(payload->'invoice_received_at'),
      paid_amount = public.purchase_numeric(payload->'paid_amount'),
      paid_at = public.purchase_date(payload->'paid_at'),
      payment_method = public.purchase_text(payload->'payment_method'),
      payment_ref = public.purchase_text(payload->'payment_ref'),
      cancelled_at = case
        when coalesce((payload->>'cancelled')::boolean, false) then coalesce(purchase_order.cancelled_at, now())
        else null
      end,
      notes = public.purchase_text(payload->'notes')
    where purchase_order.id = target_id
    returning id into saved_id;
    if saved_id is null then raise exception 'Purchase order not found.'; end if;
  end if;

  for item in select value from jsonb_array_elements(coalesce(payload->'items', '[]'::jsonb))
  loop
    item_index := item_index + 1;
    item_id := public.purchase_bigint(item->'id');
    if public.purchase_text(item->'description') is null then
      raise exception 'Order line % needs a description.', item_index;
    end if;
    if coalesce(public.purchase_bigint(item->'quantity'), 0) <= 0 then
      raise exception 'Order line % needs a quantity above zero.', item_index;
    end if;
    if public.purchase_bigint(item->'product_id') is not null
      and not exists (select 1 from public.products where id = public.purchase_bigint(item->'product_id')) then
      raise exception 'Linked SKU not found on line %.', item_index;
    end if;

    if item_id is null then
      insert into public.purchase_order_items (
        purchase_order_id, line_no, description, quantity, unit_cost, product_id, declared_name, notes
      )
      values (
        saved_id,
        item_index,
        coalesce(public.purchase_text(item->'description'), ''),
        public.purchase_bigint(item->'quantity')::integer,
        public.purchase_numeric(item->'unit_cost'),
        public.purchase_bigint(item->'product_id'),
        public.purchase_text(item->'declared_name'),
        public.purchase_text(item->'notes')
      )
      returning id into item_id;
    else
      update public.purchase_order_items order_item
      set
        line_no = item_index,
        description = coalesce(public.purchase_text(item->'description'), ''),
        quantity = public.purchase_bigint(item->'quantity')::integer,
        unit_cost = public.purchase_numeric(item->'unit_cost'),
        product_id = public.purchase_bigint(item->'product_id'),
        declared_name = public.purchase_text(item->'declared_name'),
        notes = public.purchase_text(item->'notes')
      where order_item.id = item_id and order_item.purchase_order_id = saved_id;
      if not found then raise exception 'Order line % does not belong to this order.', item_index; end if;
    end if;
    kept_ids := kept_ids || item_id;
  end loop;

  if exists (
    select 1
    from public.purchase_order_items order_item
    join public.purchase_receipt_lines line on line.purchase_order_item_id = order_item.id
    where order_item.purchase_order_id = saved_id
      and not (order_item.id = any(kept_ids))
  ) then
    raise exception 'An order line that has already been received cannot be removed.';
  end if;

  delete from public.purchase_order_items order_item
  where order_item.purchase_order_id = saved_id
    and not (order_item.id = any(kept_ids));

  return jsonb_build_object('ok', true, 'id', saved_id);
end;
$$;

create or replace function public.purchase_admin_delete_order(target_id bigint, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform public.purchase_actor(actor);
  if exists (select 1 from public.purchase_parcels where purchase_order_id = target_id) then
    raise exception 'Delete or move this order''s parcels first, or mark the order cancelled.';
  end if;
  delete from public.purchase_orders where id = target_id;
  if not found then raise exception 'Purchase order not found.'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.purchase_admin_save_parcel(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  actor_name text := public.purchase_actor(actor);
  target_id bigint := public.purchase_bigint(payload->'id');
  order_id bigint := public.purchase_bigint(payload->'purchase_order_id');
  supplier bigint := public.purchase_bigint(payload->'supplier_id');
  forwarder bigint := public.purchase_bigint(payload->'forwarder_id');
  shipment bigint := public.purchase_bigint(payload->'shipment_id');
  current_shipment bigint;
  saved_id bigint;
begin
  if order_id is not null then
    select coalesce(supplier, purchase_order.supplier_id) into supplier
    from public.purchase_orders purchase_order
    where purchase_order.id = order_id;
    if not found then raise exception 'Purchase order not found.'; end if;
  end if;
  if supplier is not null and not exists (select 1 from public.suppliers where id = supplier) then
    raise exception 'Supplier not found.';
  end if;
  if forwarder is not null and not exists (select 1 from public.purchase_forwarders where id = forwarder) then
    raise exception 'Forwarder not found.';
  end if;
  if shipment is not null and not exists (select 1 from public.purchase_shipments where id = shipment) then
    raise exception 'Shipment not found.';
  end if;

  if target_id is null then
    insert into public.purchase_parcels (
      purchase_order_id, supplier_id, contents, courier, tracking_no, carton_count, shipped_at,
      forwarder_id, channel, forwarder_received_at, forwarder_ref, shipment_id, declared_value,
      has_battery, has_magnet, weight_kg, notes, created_by
    )
    values (
      order_id,
      supplier,
      coalesce(public.purchase_text(payload->'contents'), ''),
      public.purchase_text(payload->'courier'),
      public.purchase_text(payload->'tracking_no'),
      coalesce(public.purchase_bigint(payload->'carton_count')::integer, 1),
      public.purchase_date(payload->'shipped_at'),
      forwarder,
      public.purchase_text(payload->'channel'),
      public.purchase_date(payload->'forwarder_received_at'),
      public.purchase_text(payload->'forwarder_ref'),
      shipment,
      public.purchase_numeric(payload->'declared_value'),
      coalesce((payload->>'has_battery')::boolean, false),
      coalesce((payload->>'has_magnet')::boolean, false),
      public.purchase_numeric(payload->'weight_kg'),
      public.purchase_text(payload->'notes'),
      actor_name
    )
    returning id into saved_id;
  else
    select parcel.shipment_id into current_shipment
    from public.purchase_parcels parcel
    where parcel.id = target_id
    for update;
    if not found then raise exception 'Parcel not found.'; end if;

    if current_shipment is distinct from shipment and exists (
      select 1 from public.purchase_receipt_lines where parcel_id = target_id
    ) then
      raise exception 'This parcel has already been counted into stock and cannot change batch.';
    end if;

    update public.purchase_parcels parcel
    set
      purchase_order_id = order_id,
      supplier_id = supplier,
      contents = coalesce(public.purchase_text(payload->'contents'), ''),
      courier = public.purchase_text(payload->'courier'),
      tracking_no = public.purchase_text(payload->'tracking_no'),
      carton_count = coalesce(public.purchase_bigint(payload->'carton_count')::integer, 1),
      shipped_at = public.purchase_date(payload->'shipped_at'),
      forwarder_id = forwarder,
      channel = public.purchase_text(payload->'channel'),
      forwarder_received_at = public.purchase_date(payload->'forwarder_received_at'),
      forwarder_ref = public.purchase_text(payload->'forwarder_ref'),
      shipment_id = shipment,
      declared_value = public.purchase_numeric(payload->'declared_value'),
      has_battery = coalesce((payload->>'has_battery')::boolean, false),
      has_magnet = coalesce((payload->>'has_magnet')::boolean, false),
      weight_kg = public.purchase_numeric(payload->'weight_kg'),
      notes = public.purchase_text(payload->'notes')
    where parcel.id = target_id
    returning id into saved_id;
  end if;

  return jsonb_build_object('ok', true, 'id', saved_id);
end;
$$;

create or replace function public.purchase_admin_delete_parcel(target_id bigint, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform public.purchase_actor(actor);
  if exists (select 1 from public.purchase_receipt_lines where parcel_id = target_id) then
    raise exception 'This parcel has already been counted into stock and cannot be deleted.';
  end if;
  delete from public.purchase_parcels where id = target_id;
  if not found then raise exception 'Parcel not found.'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.purchase_admin_save_shipment(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  actor_name text := public.purchase_actor(actor);
  target_id bigint := public.purchase_bigint(payload->'id');
  forwarder bigint := public.purchase_bigint(payload->'forwarder_id');
  receive_store bigint := public.purchase_bigint(payload->'received_store_id');
  next_status text := coalesce(public.purchase_text(payload->'status'), 'draft');
  today date := (timezone('Australia/Brisbane', now()))::date;
  numbers text[];
  parcel_ids bigint[];
  saved_id bigint;
begin
  if next_status not in ('draft', 'declared', 'shipped', 'arrived', 'received', 'stocked', 'closed') then
    raise exception 'Invalid shipment status.';
  end if;
  if forwarder is not null and not exists (select 1 from public.purchase_forwarders where id = forwarder) then
    raise exception 'Forwarder not found.';
  end if;
  if receive_store is not null and not exists (select 1 from public.stores where id = receive_store) then
    raise exception 'Receiving store not found.';
  end if;

  select coalesce(array_agg(entry.number order by entry.first_seen), '{}')
  into numbers
  from (
    select btrim(value) as number, min(ord) as first_seen
    from jsonb_array_elements_text(coalesce(payload->'tracking_numbers', '[]'::jsonb))
      with ordinality as element(value, ord)
    where btrim(value) <> ''
    group by btrim(value)
  ) entry;

  if target_id is null then
    insert into public.purchase_shipments (forwarder_id, status, created_by)
    values (forwarder, next_status, actor_name)
    returning id into saved_id;
  else
    perform 1 from public.purchase_shipments where id = target_id for update;
    if not found then raise exception 'Shipment not found.'; end if;
    saved_id := target_id;
  end if;

  update public.purchase_shipments shipment
  set
    forwarder_id = forwarder,
    channel = public.purchase_text(payload->'channel'),
    tracking_numbers = numbers,
    status = next_status,
    declared_at = coalesce(public.purchase_date(payload->'declared_at'),
      case when next_status <> 'draft' then coalesce(shipment.declared_at, today) end),
    shipped_at = coalesce(public.purchase_date(payload->'shipped_at'),
      case when next_status in ('shipped', 'arrived', 'received', 'stocked') then coalesce(shipment.shipped_at, today) end),
    eta = public.purchase_date(payload->'eta'),
    arrived_at = coalesce(public.purchase_date(payload->'arrived_at'),
      case when next_status in ('arrived', 'received', 'stocked') then coalesce(shipment.arrived_at, today) end),
    received_at = case
      when next_status in ('received', 'stocked') then coalesce(
        (nullif(payload->>'received_at', ''))::timestamptz, shipment.received_at, now())
      else (nullif(payload->>'received_at', ''))::timestamptz
    end,
    received_by = public.purchase_text(payload->'received_by'),
    received_store_id = receive_store,
    received_cartons = public.purchase_bigint(payload->'received_cartons')::integer,
    stocked_at = case when next_status = 'stocked' then coalesce(shipment.stocked_at, now()) else shipment.stocked_at end,
    stocked_by = case when next_status = 'stocked' then coalesce(shipment.stocked_by, actor_name) else shipment.stocked_by end,
    freight_amount = public.purchase_numeric(payload->'freight_amount'),
    freight_currency = coalesce(public.purchase_text(payload->'freight_currency'), 'CNY'),
    weight_kg = public.purchase_numeric(payload->'weight_kg'),
    notes = public.purchase_text(payload->'notes')
  where shipment.id = saved_id;

  if payload ? 'parcel_ids' then
    select coalesce(array_agg(distinct (value)::bigint), '{}')
    into parcel_ids
    from jsonb_array_elements_text(coalesce(payload->'parcel_ids', '[]'::jsonb)) value;

    if exists (
      select 1 from public.purchase_parcels parcel
      where parcel.shipment_id = saved_id
        and not (parcel.id = any(parcel_ids))
        and exists (select 1 from public.purchase_receipt_lines line where line.parcel_id = parcel.id)
    ) then
      raise exception 'A parcel that has already been counted cannot be removed from its batch.';
    end if;
    if exists (
      select 1 from public.purchase_parcels parcel
      where parcel.id = any(parcel_ids)
        and parcel.shipment_id is distinct from saved_id
        and exists (select 1 from public.purchase_receipt_lines line where line.parcel_id = parcel.id)
    ) then
      raise exception 'A parcel that has already been counted cannot move to another batch.';
    end if;
    if (select count(*) from public.purchase_parcels where id = any(parcel_ids)) <> coalesce(cardinality(parcel_ids), 0) then
      raise exception 'Parcel not found.';
    end if;

    update public.purchase_parcels parcel
    set shipment_id = null
    where parcel.shipment_id = saved_id and not (parcel.id = any(parcel_ids));

    update public.purchase_parcels parcel
    set
      shipment_id = saved_id,
      forwarder_id = coalesce(parcel.forwarder_id, forwarder)
    where parcel.id = any(parcel_ids)
      and parcel.shipment_id is distinct from saved_id;
  end if;

  return jsonb_build_object('ok', true, 'id', saved_id);
end;
$$;

create or replace function public.purchase_admin_delete_shipment(target_id bigint, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform public.purchase_actor(actor);
  if exists (select 1 from public.purchase_receipt_lines where shipment_id = target_id) then
    raise exception 'This batch has already been counted into stock and cannot be deleted.';
  end if;
  update public.purchase_parcels set shipment_id = null where shipment_id = target_id;
  delete from public.purchase_shipments where id = target_id;
  if not found then raise exception 'Shipment not found.'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.purchase_admin_search_products(search_text text, max_rows integer default 30)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with terms as (
    select array_remove(regexp_split_to_array(lower(btrim(coalesce(search_text, ''))), '\s+'), '') as words
  ),
  matches as (
    select
      product.*,
      row_number() over (order by
        (lower(product.sku) = lower(btrim(search_text)) or lower(coalesce(product.upc, '')) = lower(btrim(search_text))) desc,
        product.is_pos_visible desc,
        length(product.name),
        product.id
      ) as match_rank
    from public.products product, terms
    where cardinality(terms.words) > 0
      and product.import_status <> 'archived'
      and not exists (
        select 1 from unnest(terms.words) word
        where position(word in lower(concat_ws(' ', product.sku, product.name, product.upc, product.variant_name, product.model))) = 0
      )
    order by match_rank
    limit greatest(1, least(coalesce(max_rows, 30), 100))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', matches.id,
    'sku', matches.sku,
    'name', matches.name,
    'variant_name', matches.variant_name,
    'upc', matches.upc,
    'cost_price', matches.cost_price,
    'retail_price', matches.retail_price,
    'is_pos_visible', matches.is_pos_visible,
    'stock', coalesce((
      select jsonb_object_agg(store.slug, inventory.quantity)
      from public.product_store_inventory inventory
      join public.stores store on store.id = inventory.store_id
      where inventory.product_id = matches.id
    ), '{}'::jsonb)
  ) order by matches.match_rank), '[]'::jsonb)
  from matches;
$$;

create or replace function public.purchase_admin_create_product(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  actor_name text := public.purchase_actor(actor);
  product_name text := public.purchase_text(payload->'name');
  product_sku text := upper(public.purchase_text(payload->'sku'));
  category bigint := public.purchase_bigint(payload->'pos_category_id');
  supplier bigint := public.purchase_bigint(payload->'supplier_id');
  retail numeric := public.purchase_numeric(payload->'retail_price');
  cost numeric := public.purchase_numeric(payload->'cost_price');
  base_slug text;
  product_slug text;
  suffix integer := 1;
  saved public.products%rowtype;
begin
  if product_name is null then raise exception 'Product name is required.'; end if;
  if retail is null or retail < 0 then raise exception 'Retail price is required.'; end if;
  if cost is not null and cost < 0 then raise exception 'Cost price must not be negative.'; end if;
  if category is null or not exists (
    select 1 from public.pos_category_taxonomy where id = category and active
  ) then
    raise exception 'Choose a valid POS category.';
  end if;
  if supplier is not null and not exists (select 1 from public.suppliers where id = supplier) then
    raise exception 'Supplier not found.';
  end if;

  if product_sku is null then
    loop
      product_sku := 'TM8-CN-' || to_char(timezone('Australia/Brisbane', now()), 'YYMMDD') || '-'
        || upper(substr(md5(gen_random_uuid()::text), 1, 4));
      exit when not exists (select 1 from public.products where upper(sku) = product_sku);
    end loop;
  elsif product_sku !~ '^[A-Z0-9][A-Z0-9._/-]{1,79}$' then
    raise exception 'SKU must be 2-80 letters, numbers, dot, dash, slash or underscore.';
  elsif exists (select 1 from public.products where upper(sku) = product_sku) then
    raise exception 'SKU % is already used.', product_sku;
  end if;

  base_slug := trim(both '-' from regexp_replace(lower(product_sku), '[^a-z0-9]+', '-', 'g'));
  product_slug := base_slug;
  while exists (select 1 from public.products where slug = product_slug) loop
    suffix := suffix + 1;
    product_slug := base_slug || '-' || suffix;
  end loop;

  insert into public.products (
    sku, slug, name, brand, model, supplier_id, cost_price, retail_price, upc,
    pos_category_id, is_visible, is_pos_visible, import_status, source_system, source_metadata
  )
  values (
    product_sku,
    product_slug,
    product_name,
    public.purchase_text(payload->'brand'),
    public.purchase_text(payload->'model'),
    supplier,
    cost,
    retail,
    public.purchase_text(payload->'upc'),
    category,
    false,
    true,
    'active',
    'china_purchase',
    jsonb_build_object('created_by', actor_name, 'created_from', 'purchase_receiving')
  )
  returning * into saved;

  return jsonb_build_object(
    'ok', true,
    'product', jsonb_build_object(
      'id', saved.id, 'sku', saved.sku, 'name', saved.name, 'upc', saved.upc,
      'cost_price', saved.cost_price, 'retail_price', saved.retail_price,
      'is_pos_visible', saved.is_pos_visible, 'stock', '{}'::jsonb
    )
  );
end;
$$;

create or replace function public.purchase_admin_post_receipt(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  actor_name text := public.purchase_actor(actor);
  target_shipment bigint := public.purchase_bigint(payload->'shipment_id');
  target_key uuid := (nullif(payload->>'receipt_key', ''))::uuid;
  update_cost boolean := coalesce((payload->>'update_cost')::boolean, false);
  mark_stocked boolean := coalesce((payload->>'mark_stocked')::boolean, false);
  shipment public.purchase_shipments%rowtype;
  line jsonb;
  line_index integer := 0;
  line_product bigint;
  line_store bigint;
  line_parcel bigint;
  line_item bigint;
  line_quantity integer;
  line_damaged integer;
  line_cost numeric;
  before_quantity integer;
  product_ids bigint[] := '{}';
  stocked_total integer := 0;
begin
  if target_shipment is null then raise exception 'Shipment is required.'; end if;
  if target_key is null then raise exception 'Receipt key is required.'; end if;
  if coalesce(jsonb_typeof(payload->'lines'), 'null') not in ('array', 'null') then
    raise exception 'Counted lines must be a list.';
  end if;
  if jsonb_typeof(payload->'lines') is distinct from 'array' then
    payload := jsonb_set(payload, '{lines}', '[]'::jsonb, true);
  end if;
  if jsonb_array_length(payload->'lines') = 0 and not mark_stocked then
    raise exception 'Add at least one counted line.';
  end if;

  select * into shipment from public.purchase_shipments where id = target_shipment for update;
  if not found then raise exception 'Shipment not found.'; end if;

  if exists (select 1 from public.purchase_receipt_lines where receipt_key = target_key) then
    if exists (
      select 1 from public.purchase_receipt_lines
      where receipt_key = target_key and shipment_id <> target_shipment
    ) then
      raise exception 'Receipt key was already used for a different operation.';
    end if;
    return jsonb_build_object('ok', true, 'replayed', true, 'shipment_id', target_shipment);
  end if;

  if shipment.status not in ('shipped', 'arrived', 'received', 'stocked') then
    raise exception 'Mark the batch as shipped or arrived before counting it into stock.';
  end if;

  for line in select value from jsonb_array_elements(coalesce(payload->'lines', '[]'::jsonb))
  loop
    line_index := line_index + 1;
    line_product := public.purchase_bigint(line->'product_id');
    line_store := public.purchase_bigint(line->'store_id');
    line_parcel := public.purchase_bigint(line->'parcel_id');
    line_item := public.purchase_bigint(line->'purchase_order_item_id');
    line_quantity := coalesce(public.purchase_bigint(line->'quantity')::integer, 0);
    line_damaged := coalesce(public.purchase_bigint(line->'damaged_quantity')::integer, 0);
    line_cost := public.purchase_numeric(line->'unit_cost_aud');

    if line_product is null or not exists (select 1 from public.products where id = line_product) then
      raise exception 'Choose a SKU on line %.', line_index;
    end if;
    if line_store is null or not exists (select 1 from public.stores where id = line_store and is_active) then
      raise exception 'Choose a store on line %.', line_index;
    end if;
    if line_quantity < 0 or line_damaged < 0 or line_quantity + line_damaged = 0 then
      raise exception 'Line % must have a counted quantity.', line_index;
    end if;
    if line_cost is not null and line_cost < 0 then
      raise exception 'Line % cost must not be negative.', line_index;
    end if;
    if line_parcel is not null and not exists (
      select 1 from public.purchase_parcels where id = line_parcel and shipment_id = target_shipment
    ) then
      raise exception 'Line % parcel does not belong to this batch.', line_index;
    end if;
    if line_item is not null and not exists (
      select 1 from public.purchase_order_items where id = line_item
    ) then
      raise exception 'Line % order item not found.', line_index;
    end if;

    insert into public.product_store_inventory (product_id, store_id, quantity, updated_at)
    values (line_product, line_store, 0, now())
    on conflict (product_id, store_id) do nothing;

    select inventory.quantity into before_quantity
    from public.product_store_inventory inventory
    where inventory.product_id = line_product and inventory.store_id = line_store
    for update;

    if line_quantity > 0 then
      update public.product_store_inventory inventory
      set quantity = inventory.quantity + line_quantity, updated_at = now()
      where inventory.product_id = line_product and inventory.store_id = line_store;
    end if;

    insert into public.purchase_receipt_lines (
      receipt_key, line_no, shipment_id, parcel_id, purchase_order_item_id, product_id, store_id,
      quantity, damaged_quantity, unit_cost_aud, quantity_before, quantity_after, note, created_by
    )
    values (
      target_key, line_index, target_shipment, line_parcel, line_item, line_product, line_store,
      line_quantity, line_damaged, line_cost, before_quantity, before_quantity + line_quantity,
      public.purchase_text(line->'note'), actor_name
    );

    if update_cost and line_cost is not null then
      update public.products set cost_price = round(line_cost, 2) where id = line_product;
    end if;

    if line_item is not null then
      update public.purchase_order_items
      set product_id = line_product
      where id = line_item and product_id is null;
    end if;

    product_ids := product_ids || line_product;
    stocked_total := stocked_total + line_quantity;
  end loop;

  if cardinality(product_ids) > 0 then
    perform public.refresh_product_stock_totals(product_ids);
  end if;

  update public.purchase_shipments target
  set
    status = case
      when mark_stocked then 'stocked'
      when target.status in ('shipped', 'arrived') then 'received'
      else target.status
    end,
    arrived_at = coalesce(target.arrived_at, (timezone('Australia/Brisbane', now()))::date),
    received_at = coalesce(target.received_at, now()),
    received_by = coalesce(target.received_by, actor_name),
    stocked_at = case when mark_stocked then coalesce(target.stocked_at, now()) else target.stocked_at end,
    stocked_by = case when mark_stocked then coalesce(target.stocked_by, actor_name) else target.stocked_by end
  where target.id = target_shipment;

  return jsonb_build_object(
    'ok', true,
    'shipment_id', target_shipment,
    'lines', line_index,
    'stocked_quantity', stocked_total
  );
end;
$$;

revoke execute on function public.purchase_text(jsonb) from public, anon, authenticated;
revoke execute on function public.purchase_bigint(jsonb) from public, anon, authenticated;
revoke execute on function public.purchase_numeric(jsonb) from public, anon, authenticated;
revoke execute on function public.purchase_date(jsonb) from public, anon, authenticated;
revoke execute on function public.purchase_actor(text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_snapshot() from public, anon, authenticated;
revoke execute on function public.purchase_admin_save_supplier(jsonb, text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_save_forwarder(jsonb, text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_save_order(jsonb, text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_delete_order(bigint, text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_save_parcel(jsonb, text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_delete_parcel(bigint, text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_save_shipment(jsonb, text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_delete_shipment(bigint, text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_search_products(text, integer) from public, anon, authenticated;
revoke execute on function public.purchase_admin_create_product(jsonb, text) from public, anon, authenticated;
revoke execute on function public.purchase_admin_post_receipt(jsonb, text) from public, anon, authenticated;

grant execute on function public.purchase_text(jsonb) to service_role;
grant execute on function public.purchase_bigint(jsonb) to service_role;
grant execute on function public.purchase_numeric(jsonb) to service_role;
grant execute on function public.purchase_date(jsonb) to service_role;
grant execute on function public.purchase_actor(text) to service_role;
grant execute on function public.purchase_admin_snapshot() to service_role;
grant execute on function public.purchase_admin_save_supplier(jsonb, text) to service_role;
grant execute on function public.purchase_admin_save_forwarder(jsonb, text) to service_role;
grant execute on function public.purchase_admin_save_order(jsonb, text) to service_role;
grant execute on function public.purchase_admin_delete_order(bigint, text) to service_role;
grant execute on function public.purchase_admin_save_parcel(jsonb, text) to service_role;
grant execute on function public.purchase_admin_delete_parcel(bigint, text) to service_role;
grant execute on function public.purchase_admin_save_shipment(jsonb, text) to service_role;
grant execute on function public.purchase_admin_delete_shipment(bigint, text) to service_role;
grant execute on function public.purchase_admin_search_products(text, integer) to service_role;
grant execute on function public.purchase_admin_create_product(jsonb, text) to service_role;
grant execute on function public.purchase_admin_post_receipt(jsonb, text) to service_role;
