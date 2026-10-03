-- Product project: record orders straight from pasted supplier-group chats.
-- The admin page sends the chat to Claude (admin-purchasing parse_chat), the
-- admin checks the result, and purchase_admin_import_chat saves the order, its
-- lines and the domestic parcels in one transaction. Each order remembers which
-- forwarder it was sent to, and each forwarder has a weight at which a batch is
-- worth shipping.

alter table public.purchase_orders
  add column if not exists forwarder_id bigint references public.purchase_forwarders(id) on delete set null;

alter table public.purchase_forwarders
  add column if not exists ship_threshold_kg numeric(10,2)
    check (ship_threshold_kg is null or ship_threshold_kg > 0);

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
    ), '[]'::jsonb)
  );
$$;

create or replace function public.purchase_admin_save_forwarder(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  target_id bigint := public.purchase_bigint(payload->'id');
  forwarder_name text := public.purchase_text(payload->'name');
  threshold numeric := nullif(public.purchase_numeric(payload->'ship_threshold_kg'), 0);
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
      ship_threshold_kg, notes, is_active, sort_order
    )
    values (
      forwarder_name,
      public.purchase_text(payload->'tracking_url'),
      public.purchase_text(payload->'website_url'),
      public.purchase_text(payload->'warehouse_address'),
      public.purchase_text(payload->'contact'),
      channel_list,
      prefix_list,
      threshold,
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
      ship_threshold_kg = case when payload ? 'ship_threshold_kg' then threshold else forwarder.ship_threshold_kg end,
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
  forwarder bigint := public.purchase_bigint(payload->'forwarder_id');
  item jsonb;
  item_id bigint;
  item_index integer := 0;
  kept_ids bigint[] := '{}';
  saved_id bigint;
begin
  if supplier is not null and not exists (select 1 from public.suppliers where id = supplier) then
    raise exception 'Supplier not found.';
  end if;
  if forwarder is not null and not exists (select 1 from public.purchase_forwarders where id = forwarder) then
    raise exception 'Forwarder not found.';
  end if;
  if jsonb_typeof(coalesce(payload->'items', '[]'::jsonb)) <> 'array' then
    raise exception 'Order items must be a list.';
  end if;

  if target_id is null then
    insert into public.purchase_orders (
      supplier_id, forwarder_id, supplier_order_ref, order_date, currency, goods_amount, domestic_shipping_amount,
      invoice_received_at, paid_amount, paid_at, payment_method, payment_ref, cancelled_at, notes, created_by
    )
    values (
      supplier,
      forwarder,
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
      forwarder_id = case when payload ? 'forwarder_id' then forwarder else purchase_order.forwarder_id end,
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

-- One pasted chat -> a new order (or lines appended to an existing one) plus its
-- domestic parcels. A tracking number that is already on file is skipped, so
-- pasting the same chat twice never creates duplicate parcels. Parcels go to the
-- forwarder chosen on the page, else the order's forwarder.
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
      'chat',
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
      'chat',
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

revoke execute on function public.purchase_admin_import_chat(jsonb, text) from public, anon, authenticated;
grant execute on function public.purchase_admin_import_chat(jsonb, text) to service_role;
