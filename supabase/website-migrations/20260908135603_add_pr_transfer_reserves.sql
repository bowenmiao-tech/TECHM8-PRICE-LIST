-- PR transfer reserves are virtual dispatch allowances, never sellable store stock.
-- Existing transfers retain physical stock accounting, including their returns.
create table public.pos_pr_transfer_reserves (
  product_id bigint primary key references public.products(id),
  quantity integer not null default 999 check (quantity between 0 and 999),
  updated_at timestamptz not null default now()
);
alter table public.pos_pr_transfer_reserves enable row level security;
revoke all on public.pos_pr_transfer_reserves from public, anon, authenticated;
grant select, insert, update on public.pos_pr_transfer_reserves to service_role;
insert into public.pos_pr_transfer_reserves(product_id)
  select id from public.products where is_pos_visible = true;
alter table public.stock_transfers add column source_stock_mode text not null default 'physical'
  check (source_stock_mode in ('physical', 'reserve'));
comment on column public.stock_transfers.source_stock_mode is
  'reserve consumes PR virtual transfer allowance; physical consumes actual store inventory. Never infer mode from store for legacy transfers.';

create or replace function public.get_pos_pr_transfer_reserves()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_object_agg(p.id::text, coalesce(r.quantity, 999)), '{}'::jsonb)
  from public.products p left join public.pos_pr_transfer_reserves r on r.product_id = p.id
  where p.is_pos_visible = true;
$$;
revoke all on function public.get_pos_pr_transfer_reserves() from public, anon, authenticated;
grant execute on function public.get_pos_pr_transfer_reserves() to service_role;

CREATE OR REPLACE FUNCTION public.receive_pos_stock_transfer(target_transfer_id bigint, target_receipt_key uuid, target_lines jsonb, target_finalize boolean, target_actor_staff_name text, target_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  selected_transfer public.stock_transfers%rowtype;
  saved_receipt public.stock_transfer_receipts%rowtype;
  submitted_count integer;
  distinct_count integer;
  matched_count integer;
  remaining_total integer;
  issue_total integer;
  good_total integer;
  returned_total integer;
  product_ids bigint[];
  returned_product_ids bigint[];
  request_fingerprint text;
begin
  if coalesce(btrim(target_actor_staff_name), '') = '' then
    raise exception 'Staff name is required';
  end if;
  if target_receipt_key is null then
    raise exception 'Receipt key is required';
  end if;
  if jsonb_typeof(target_lines) <> 'array' or jsonb_array_length(target_lines) > 500 then
    raise exception 'Receipt lines must be an array with no more than 500 products';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(target_lines) entry
    where jsonb_typeof(entry -> 'transfer_item_id') <> 'number'
      or (entry ->> 'transfer_item_id')::numeric <> trunc((entry ->> 'transfer_item_id')::numeric)
      or (
        entry ? 'good_quantity'
        and entry -> 'good_quantity' <> 'null'::jsonb
        and (
          jsonb_typeof(entry -> 'good_quantity') <> 'number'
          or (entry ->> 'good_quantity')::numeric <> trunc((entry ->> 'good_quantity')::numeric)
        )
      )
      or (
        entry ? 'damaged_quantity'
        and entry -> 'damaged_quantity' <> 'null'::jsonb
        and (
          jsonb_typeof(entry -> 'damaged_quantity') <> 'number'
          or (entry ->> 'damaged_quantity')::numeric <> trunc((entry ->> 'damaged_quantity')::numeric)
        )
      )
      or (
        entry ? 'missing_quantity'
        and entry -> 'missing_quantity' <> 'null'::jsonb
        and (
          jsonb_typeof(entry -> 'missing_quantity') <> 'number'
          or (entry ->> 'missing_quantity')::numeric <> trunc((entry ->> 'missing_quantity')::numeric)
        )
      )
  ) then
    raise exception 'Receipt product IDs and quantities must be whole numbers';
  end if;

  select pg_catalog.md5(
    concat_ws(
      '|',
      target_transfer_id::text,
      coalesce(target_finalize, false)::text,
      btrim(target_actor_staff_name),
      coalesce(nullif(btrim(target_note), ''), ''),
      coalesce(jsonb_agg(
        jsonb_build_object(
          'transfer_item_id', parsed.transfer_item_id,
          'good_quantity', coalesce(parsed.good_quantity, 0),
          'damaged_quantity', coalesce(parsed.damaged_quantity, 0),
          'missing_quantity', coalesce(parsed.missing_quantity, 0)
        )
        order by parsed.transfer_item_id
      ), '[]'::jsonb)::text
    )
  )
  into request_fingerprint
  from jsonb_to_recordset(target_lines) as parsed(
    transfer_item_id bigint,
    good_quantity integer,
    damaged_quantity integer,
    missing_quantity integer
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('stock-transfer-receipt:' || target_receipt_key::text, 0)
  );

  select receipt.*
  into saved_receipt
  from public.stock_transfer_receipts receipt
  where receipt.receipt_key = target_receipt_key;

  if saved_receipt.id is not null then
    if saved_receipt.transfer_id <> target_transfer_id then
      raise exception 'Receipt key belongs to another transfer';
    end if;
    if saved_receipt.receipt_type <> 'receive'
      or saved_receipt.request_fingerprint <> request_fingerprint then
      raise exception 'Receipt key was already used for a different operation';
    end if;
    return public.pos_stock_transfer_payload(target_transfer_id);
  end if;

  select transfer.*
  into selected_transfer
  from public.stock_transfers transfer
  where transfer.id = target_transfer_id
  for update;

  if selected_transfer.id is null then
    raise exception 'Transfer not found';
  end if;
  if selected_transfer.status not in ('in_transit', 'partially_received') then
    raise exception 'Transfer is not available to receive';
  end if;

  if not exists (
    select 1
    from public.stock_transfer_photos photo
    where photo.transfer_id = selected_transfer.id
      and photo.receipt_key = target_receipt_key
  ) then
    raise exception 'At least one receipt photo must be uploaded before receiving';
  end if;

  perform item.id
  from public.stock_transfer_items item
  where item.transfer_id = selected_transfer.id
  order by item.id
  for update;

  select
    count(*),
    count(distinct parsed.transfer_item_id)
  into submitted_count, distinct_count
  from jsonb_to_recordset(target_lines) as parsed(
    transfer_item_id bigint,
    good_quantity integer,
    damaged_quantity integer,
    missing_quantity integer
  )
  where parsed.transfer_item_id is not null
    and coalesce(parsed.good_quantity, 0) >= 0
    and coalesce(parsed.damaged_quantity, 0) >= 0
    and coalesce(parsed.missing_quantity, 0) >= 0
    and coalesce(parsed.good_quantity, 0) + coalesce(parsed.damaged_quantity, 0)
      + coalesce(parsed.missing_quantity, 0) > 0;

  if submitted_count <> jsonb_array_length(target_lines)
    or distinct_count <> submitted_count then
    raise exception 'Receipt lines must be unique and contain a positive good, damaged or missing quantity';
  end if;
  if not coalesce(target_finalize, false) and submitted_count = 0 then
    raise exception 'A partial receipt must contain at least one received product';
  end if;

  select count(*)
  into matched_count
  from jsonb_to_recordset(target_lines) as parsed(
    transfer_item_id bigint,
    good_quantity integer,
    damaged_quantity integer,
    missing_quantity integer
  )
  join public.stock_transfer_items item
    on item.id = parsed.transfer_item_id
    and item.transfer_id = selected_transfer.id;

  if matched_count <> submitted_count then
    raise exception 'One or more receipt products do not belong to this transfer';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(target_lines) as parsed(
      transfer_item_id bigint,
      good_quantity integer,
      damaged_quantity integer,
      missing_quantity integer
    )
    join public.stock_transfer_items item on item.id = parsed.transfer_item_id
    where coalesce(parsed.good_quantity, 0) + coalesce(parsed.damaged_quantity, 0)
      + coalesce(parsed.missing_quantity, 0)
      > item.dispatched_quantity - item.received_good_quantity
        - item.received_damaged_quantity - item.missing_quantity - item.returned_quantity
  ) then
    raise exception 'Received quantity exceeds the remaining transfer quantity';
  end if;

  insert into public.stock_transfer_receipts (
    transfer_id,
    receipt_key,
    request_fingerprint,
    receipt_type,
    received_by,
    note
  )
  values (
    selected_transfer.id,
    target_receipt_key,
    request_fingerprint,
    'receive',
    btrim(target_actor_staff_name),
    nullif(btrim(target_note), '')
  )
  returning * into saved_receipt;

  insert into public.stock_transfer_receipt_items (
    receipt_id,
    transfer_item_id,
    good_quantity,
    damaged_quantity,
    missing_quantity,
    returned_quantity
  )
  select
    saved_receipt.id,
    item.id,
    coalesce(parsed.good_quantity, 0),
    coalesce(parsed.damaged_quantity, 0),
    coalesce(parsed.missing_quantity, 0),
    case
      when coalesce(target_finalize, false) then greatest(
        item.dispatched_quantity - item.received_good_quantity
          - item.received_damaged_quantity - item.missing_quantity - item.returned_quantity
          - coalesce(parsed.good_quantity, 0) - coalesce(parsed.damaged_quantity, 0)
          - coalesce(parsed.missing_quantity, 0),
        0
      )
      else 0
    end
  from public.stock_transfer_items item
  left join jsonb_to_recordset(target_lines) as parsed(
    transfer_item_id bigint,
    good_quantity integer,
    damaged_quantity integer,
    missing_quantity integer
  ) on parsed.transfer_item_id = item.id
  where item.transfer_id = selected_transfer.id
    and (
      coalesce(parsed.good_quantity, 0) + coalesce(parsed.damaged_quantity, 0)
      + coalesce(parsed.missing_quantity, 0) > 0
      or (
        coalesce(target_finalize, false)
        and item.dispatched_quantity - item.received_good_quantity
          - item.received_damaged_quantity - item.missing_quantity - item.returned_quantity > 0
      )
    )
  order by item.id;

  update public.stock_transfer_items item
  set
    received_good_quantity = item.received_good_quantity + receipt_item.good_quantity,
    received_damaged_quantity = item.received_damaged_quantity + receipt_item.damaged_quantity,
    missing_quantity = item.missing_quantity + receipt_item.missing_quantity,
    returned_quantity = item.returned_quantity + receipt_item.returned_quantity,
    updated_at = now()
  from public.stock_transfer_receipt_items receipt_item
  where receipt_item.receipt_id = saved_receipt.id
    and receipt_item.transfer_item_id = item.id;

  select
    coalesce(sum(receipt_item.good_quantity), 0)::integer,
    array_agg(distinct item.product_id order by item.product_id)
      filter (where receipt_item.good_quantity > 0)
  into good_total, product_ids
  from public.stock_transfer_receipt_items receipt_item
  join public.stock_transfer_items item on item.id = receipt_item.transfer_item_id
  where receipt_item.receipt_id = saved_receipt.id;

  select
    coalesce(sum(receipt_item.returned_quantity), 0)::integer,
    array_agg(distinct item.product_id order by item.product_id)
      filter (where receipt_item.returned_quantity > 0)
  into returned_total, returned_product_ids
  from public.stock_transfer_receipt_items receipt_item
  join public.stock_transfer_items item on item.id = receipt_item.transfer_item_id
  where receipt_item.receipt_id = saved_receipt.id;

  if good_total > 0 then
    insert into public.product_store_inventory (product_id, store_id, quantity, updated_at)
    select product_row.product_id, selected_transfer.destination_store_id, 0, now()
    from unnest(product_ids) as product_row(product_id)
    on conflict (product_id, store_id) do nothing;

    perform inventory.id
    from public.product_store_inventory inventory
    where inventory.product_id = any(product_ids)
      and inventory.store_id = selected_transfer.destination_store_id
    order by inventory.product_id
    for update;

    update public.product_store_inventory inventory
    set
      quantity = inventory.quantity + totals.good_quantity,
      updated_at = now()
    from (
      select item.product_id, sum(receipt_item.good_quantity)::integer as good_quantity
      from public.stock_transfer_receipt_items receipt_item
      join public.stock_transfer_items item on item.id = receipt_item.transfer_item_id
      where receipt_item.receipt_id = saved_receipt.id
        and receipt_item.good_quantity > 0
      group by item.product_id
    ) totals
    where inventory.product_id = totals.product_id
      and inventory.store_id = selected_transfer.destination_store_id;

    insert into public.inventory_movements (
      movement_key,
      movement_type,
      product_id,
      store_id,
      quantity_delta,
      quantity_before,
      quantity_after,
      transfer_id,
      transfer_item_id,
      receipt_id,
      actor_staff_name
    )
    select
      'transfer:' || selected_transfer.id || ':receipt:' || saved_receipt.id || ':in:' || item.id,
      'transfer_in',
      item.product_id,
      selected_transfer.destination_store_id,
      receipt_item.good_quantity,
      inventory.quantity - receipt_item.good_quantity,
      inventory.quantity,
      selected_transfer.id,
      item.id,
      saved_receipt.id,
      btrim(target_actor_staff_name)
    from public.stock_transfer_receipt_items receipt_item
    join public.stock_transfer_items item on item.id = receipt_item.transfer_item_id
    join public.product_store_inventory inventory
      on inventory.product_id = item.product_id
      and inventory.store_id = selected_transfer.destination_store_id
    where receipt_item.receipt_id = saved_receipt.id
      and receipt_item.good_quantity > 0;

    perform public.refresh_product_stock_totals(product_ids);
  end if;

  if returned_total > 0 and selected_transfer.source_stock_mode = 'reserve' then
    perform r.product_id from public.pos_pr_transfer_reserves r
      where r.product_id = any(returned_product_ids) order by r.product_id for update;
    update public.pos_pr_transfer_reserves reserve
      set quantity = reserve.quantity + totals.returned_quantity, updated_at = now()
      from (
        select item.product_id, sum(receipt_item.returned_quantity)::integer as returned_quantity
        from public.stock_transfer_receipt_items receipt_item
        join public.stock_transfer_items item on item.id = receipt_item.transfer_item_id
        where receipt_item.receipt_id = saved_receipt.id group by item.product_id
      ) totals where reserve.product_id = totals.product_id;
  elsif returned_total > 0 then
    insert into public.product_store_inventory (product_id, store_id, quantity, updated_at)
    select product_row.product_id, selected_transfer.source_store_id, 0, now()
    from unnest(returned_product_ids) as product_row(product_id)
    on conflict (product_id, store_id) do nothing;

    perform inventory.id
    from public.product_store_inventory inventory
    where inventory.product_id = any(returned_product_ids)
      and inventory.store_id = selected_transfer.source_store_id
    order by inventory.product_id
    for update;

    update public.product_store_inventory inventory
    set
      quantity = inventory.quantity + totals.returned_quantity,
      updated_at = now()
    from (
      select item.product_id, sum(receipt_item.returned_quantity)::integer as returned_quantity
      from public.stock_transfer_receipt_items receipt_item
      join public.stock_transfer_items item on item.id = receipt_item.transfer_item_id
      where receipt_item.receipt_id = saved_receipt.id
        and receipt_item.returned_quantity > 0
      group by item.product_id
    ) totals
    where inventory.product_id = totals.product_id
      and inventory.store_id = selected_transfer.source_store_id;

    insert into public.inventory_movements (
      movement_key,
      movement_type,
      product_id,
      store_id,
      quantity_delta,
      quantity_before,
      quantity_after,
      transfer_id,
      transfer_item_id,
      receipt_id,
      actor_staff_name
    )
    select
      'transfer:' || selected_transfer.id || ':receipt:' || saved_receipt.id || ':auto-return:' || item.id,
      'transfer_return',
      item.product_id,
      selected_transfer.source_store_id,
      receipt_item.returned_quantity,
      inventory.quantity - receipt_item.returned_quantity,
      inventory.quantity,
      selected_transfer.id,
      item.id,
      saved_receipt.id,
      btrim(target_actor_staff_name)
    from public.stock_transfer_receipt_items receipt_item
    join public.stock_transfer_items item on item.id = receipt_item.transfer_item_id
    join public.product_store_inventory inventory
      on inventory.product_id = item.product_id
      and inventory.store_id = selected_transfer.source_store_id
    where receipt_item.receipt_id = saved_receipt.id
      and receipt_item.returned_quantity > 0;

    perform public.refresh_product_stock_totals(returned_product_ids);
  end if;

  update public.stock_transfer_photos photo
  set receipt_id = saved_receipt.id
  where photo.transfer_id = selected_transfer.id
    and photo.receipt_key = target_receipt_key
    and photo.receipt_id is null;

  select
    coalesce(sum(
      item.dispatched_quantity - item.received_good_quantity
        - item.received_damaged_quantity - item.missing_quantity - item.returned_quantity
    ), 0)::integer,
    coalesce(sum(
      item.received_damaged_quantity + item.missing_quantity + item.returned_quantity
    ), 0)::integer
  into remaining_total, issue_total
  from public.stock_transfer_items item
  where item.transfer_id = selected_transfer.id;

  update public.stock_transfers transfer
  set
    status = case
      when remaining_total > 0 then 'partially_received'
      when issue_total > 0 then 'completed_with_issues'
      else 'completed'
    end,
    completed_at = case when remaining_total = 0 then now() else null end,
    updated_at = now()
  where transfer.id = selected_transfer.id;

  return public.pos_stock_transfer_payload(selected_transfer.id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.pos_stock_transfer_payload(target_transfer_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', transfer.id,
    'transfer_number', transfer.transfer_number,
    'status', transfer.status,
    'source_stock_mode', transfer.source_stock_mode,
    'source_store', jsonb_build_object(
      'id', source_store.id,
      'slug', source_store.slug,
      'name', source_store.name
    ),
    'destination_store', jsonb_build_object(
      'id', destination_store.id,
      'slug', destination_store.slug,
      'name', destination_store.name
    ),
    'dispatched_by', transfer.dispatched_by,
    'dispatch_note', transfer.dispatch_note,
    'dispatched_at', transfer.dispatched_at,
    'completed_at', transfer.completed_at,
    'updated_at', transfer.updated_at,
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', item.id,
          'product_id', item.product_id,
          'sku', item.sku_snapshot,
          'name', item.name_snapshot,
          'barcode', item.barcode_snapshot,
          'variant', item.variant_snapshot,
          'dispatched_quantity', item.dispatched_quantity,
          'received_good_quantity', item.received_good_quantity,
          'received_damaged_quantity', item.received_damaged_quantity,
          'missing_quantity', item.missing_quantity,
          'returned_quantity', item.returned_quantity,
          'remaining_quantity', greatest(
            item.dispatched_quantity - item.received_good_quantity
              - item.received_damaged_quantity - item.missing_quantity - item.returned_quantity,
            0
          ),
          'source_quantity_before', item.source_quantity_before,
          'image_url', product.image_url
        )
        order by item.id
      )
      from public.stock_transfer_items item
      join public.products product on product.id = item.product_id
      where item.transfer_id = transfer.id
    ), '[]'::jsonb),
    'receipts', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', receipt.id,
          'receipt_key', receipt.receipt_key,
          'receipt_type', receipt.receipt_type,
          'received_by', receipt.received_by,
          'note', receipt.note,
          'created_at', receipt.created_at,
          'items', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'transfer_item_id', receipt_item.transfer_item_id,
                'good_quantity', receipt_item.good_quantity,
                'damaged_quantity', receipt_item.damaged_quantity,
                'missing_quantity', receipt_item.missing_quantity,
                'returned_quantity', receipt_item.returned_quantity
              )
              order by receipt_item.transfer_item_id
            )
            from public.stock_transfer_receipt_items receipt_item
            where receipt_item.receipt_id = receipt.id
          ), '[]'::jsonb)
        )
        order by receipt.created_at
      )
      from public.stock_transfer_receipts receipt
      where receipt.transfer_id = transfer.id
    ), '[]'::jsonb),
    'photos', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', photo.id,
          'receipt_key', photo.receipt_key,
          'receipt_id', photo.receipt_id,
          'category', photo.category,
          'storage_path', photo.storage_path,
          'mime_type', photo.mime_type,
          'file_size', photo.file_size,
          'uploaded_by', photo.uploaded_by,
          'created_at', photo.created_at
        )
        order by photo.created_at
      )
      from public.stock_transfer_photos photo
      where photo.transfer_id = transfer.id
    ), '[]'::jsonb)
  )
  from public.stock_transfers transfer
  join public.stores source_store on source_store.id = transfer.source_store_id
  join public.stores destination_store on destination_store.id = transfer.destination_store_id
  where transfer.id = target_transfer_id;
$function$;

CREATE OR REPLACE FUNCTION public.create_pos_stock_transfer(target_source_store_slug text, target_destination_store_slug text, target_items jsonb, target_actor_staff_name text, target_dispatch_note text, target_client_request_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  selected_source public.stores%rowtype;
  selected_destination public.stores%rowtype;
  saved_transfer public.stock_transfers%rowtype;
  product_ids bigint[];
  item_count integer;
  product_count integer;
  request_fingerprint text;
  use_reserve boolean;
begin
  if coalesce(btrim(target_actor_staff_name), '') = '' then
    raise exception 'Staff name is required';
  end if;
  if target_client_request_key is null then
    raise exception 'Client request key is required';
  end if;
  if jsonb_typeof(target_items) <> 'array'
    or jsonb_array_length(target_items) < 1
    or jsonb_array_length(target_items) > 500 then
    raise exception 'Transfer must contain between 1 and 500 products';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(target_items) entry
    where jsonb_typeof(entry -> 'product_id') <> 'number'
      or jsonb_typeof(entry -> 'quantity') <> 'number'
      or (entry ->> 'product_id')::numeric <> trunc((entry ->> 'product_id')::numeric)
      or (entry ->> 'quantity')::numeric <> trunc((entry ->> 'quantity')::numeric)
  ) then
    raise exception 'Product IDs and transfer quantities must be whole numbers';
  end if;

  select pg_catalog.md5(
    concat_ws(
      '|',
      btrim(target_source_store_slug),
      btrim(target_destination_store_slug),
      btrim(target_actor_staff_name),
      coalesce(nullif(btrim(target_dispatch_note), ''), ''),
      coalesce(jsonb_agg(
        jsonb_build_object('product_id', parsed.product_id, 'quantity', parsed.quantity)
        order by parsed.product_id
      ), '[]'::jsonb)::text
    )
  )
  into request_fingerprint
  from jsonb_to_recordset(target_items) as parsed(product_id bigint, quantity integer);

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('stock-transfer:' || target_client_request_key::text, 0)
  );

  select transfer.*
  into saved_transfer
  from public.stock_transfers transfer
  where transfer.client_request_key = target_client_request_key;

  if saved_transfer.id is not null then
    if saved_transfer.request_fingerprint <> request_fingerprint then
      raise exception 'Client request key was already used for a different transfer';
    end if;
    return public.pos_stock_transfer_payload(saved_transfer.id);
  end if;

  select store.*
  into selected_source
  from public.stores store
  where store.slug = btrim(target_source_store_slug)
    and store.is_active = true
    and store.slug = any(array['park-ridge', 'fairfield', 'north-lakes', 'toowong']);

  select store.*
  into selected_destination
  from public.stores store
  where store.slug = btrim(target_destination_store_slug)
    and store.is_active = true
    and store.slug = any(array['park-ridge', 'fairfield', 'north-lakes', 'toowong']);

  if selected_source.id is null or selected_destination.id is null then
    raise exception 'A valid POS source and destination store are required';
  end if;
  if selected_source.id = selected_destination.id then
    raise exception 'Source and destination stores must be different';
  end if;

  select
    count(*),
    count(distinct parsed.product_id),
    array_agg(parsed.product_id order by parsed.product_id)
  into item_count, product_count, product_ids
  from jsonb_to_recordset(target_items) as parsed(product_id bigint, quantity integer)
  where parsed.product_id is not null
    and parsed.quantity is not null
    and parsed.quantity > 0
    and parsed.quantity <= 1000000;

  if item_count <> jsonb_array_length(target_items)
    or product_count <> item_count then
    raise exception 'Every transfer product must be unique and have a positive whole quantity';
  end if;

  perform product.id
  from public.products product
  where product.id = any(product_ids)
    and product.is_pos_visible = true;

  get diagnostics product_count = row_count;
  if product_count <> item_count then
    raise exception 'One or more transfer products are unavailable in POS';
  end if;

  use_reserve := selected_source.slug = 'park-ridge';
  if use_reserve then
    insert into public.pos_pr_transfer_reserves(product_id, quantity)
    select unnest(product_ids), 999 on conflict (product_id) do nothing;
    perform r.product_id from public.pos_pr_transfer_reserves r
      where r.product_id = any(product_ids) order by r.product_id for update;
    if exists (
      select 1 from jsonb_to_recordset(target_items) as parsed(product_id bigint, quantity integer)
      join public.pos_pr_transfer_reserves r on r.product_id = parsed.product_id
      where r.quantity < parsed.quantity
    ) then raise exception 'One or more products exceed the PR transfer reserve'; end if;
  end if;

  if not use_reserve then
  insert into public.product_store_inventory (product_id, store_id, quantity, updated_at)
  select product_row.product_id, store_row.store_id, 0, now()
  from unnest(product_ids) as product_row(product_id)
  cross join unnest(array[selected_source.id, selected_destination.id]) as store_row(store_id)
  where not use_reserve or store_row.store_id <> selected_source.id
  on conflict (product_id, store_id) do nothing;

  perform inventory.id
  from public.product_store_inventory inventory
  where inventory.product_id = any(product_ids)
    and inventory.store_id = any(array[selected_source.id, selected_destination.id])
  order by inventory.product_id, inventory.store_id
  for update;

  if exists (
    select 1
    from jsonb_to_recordset(target_items) as parsed(product_id bigint, quantity integer)
    join public.product_store_inventory inventory
      on inventory.product_id = parsed.product_id
      and inventory.store_id = selected_source.id
    where not use_reserve and inventory.quantity < parsed.quantity
  ) then
    raise exception 'One or more products do not have enough source-store inventory';
  end if;

  end if;

  insert into public.stock_transfers (
    client_request_key,
    request_fingerprint,
    source_store_id,
    source_stock_mode,
    destination_store_id,
    status,
    dispatched_by,
    dispatch_note,
    dispatched_at,
    updated_at
  )
  values (
    target_client_request_key,
    request_fingerprint,
    selected_source.id,
    case when use_reserve then 'reserve' else 'physical' end,
    selected_destination.id,
    'in_transit',
    btrim(target_actor_staff_name),
    nullif(btrim(target_dispatch_note), ''),
    now(),
    now()
  )
  returning * into saved_transfer;

  insert into public.stock_transfer_items (
    transfer_id,
    product_id,
    sku_snapshot,
    name_snapshot,
    barcode_snapshot,
    variant_snapshot,
    dispatched_quantity,
    source_quantity_before
  )
  select
    saved_transfer.id,
    product.id,
    product.sku,
    product.name,
    product.upc,
    nullif(concat_ws(' / ', product.variant_name, product.variant_color), ''),
    parsed.quantity,
    case when use_reserve then reserve.quantity else inventory.quantity end
  from jsonb_to_recordset(target_items) as parsed(product_id bigint, quantity integer)
  join public.products product on product.id = parsed.product_id
  left join public.product_store_inventory inventory
    on inventory.product_id = product.id
    and inventory.store_id = selected_source.id
  left join public.pos_pr_transfer_reserves reserve on reserve.product_id = product.id
  order by product.id;

  if use_reserve then
    update public.pos_pr_transfer_reserves reserve
      set quantity = reserve.quantity - parsed.quantity, updated_at = now()
      from jsonb_to_recordset(target_items) as parsed(product_id bigint, quantity integer)
      where reserve.product_id = parsed.product_id;
  end if;

  update public.product_store_inventory inventory
  set
    quantity = inventory.quantity - parsed.quantity,
    updated_at = now()
  from jsonb_to_recordset(target_items) as parsed(product_id bigint, quantity integer)
  where inventory.product_id = parsed.product_id
    and inventory.store_id = selected_source.id
    and not use_reserve;

  insert into public.inventory_movements (
    movement_key,
    movement_type,
    product_id,
    store_id,
    quantity_delta,
    quantity_before,
    quantity_after,
    transfer_id,
    transfer_item_id,
    actor_staff_name
  )
  select
    'transfer:' || saved_transfer.id || ':out:' || item.id,
    'transfer_out',
    item.product_id,
    selected_source.id,
    -item.dispatched_quantity,
    item.source_quantity_before,
    inventory.quantity,
    saved_transfer.id,
    item.id,
    btrim(target_actor_staff_name)
  from public.stock_transfer_items item
  join public.product_store_inventory inventory
    on inventory.product_id = item.product_id
    and inventory.store_id = selected_source.id
  where item.transfer_id = saved_transfer.id and not use_reserve;

  if not use_reserve then perform public.refresh_product_stock_totals(product_ids); end if;

  return public.pos_stock_transfer_payload(saved_transfer.id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.return_pos_stock_transfer(target_transfer_id bigint, target_receipt_key uuid, target_actor_staff_name text, target_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  selected_transfer public.stock_transfers%rowtype;
  saved_receipt public.stock_transfer_receipts%rowtype;
  remaining_total integer;
  product_ids bigint[];
  request_fingerprint text;
begin
  if coalesce(btrim(target_actor_staff_name), '') = '' then
    raise exception 'Staff name is required';
  end if;
  if coalesce(btrim(target_reason), '') = '' then
    raise exception 'Return reason is required';
  end if;
  if target_receipt_key is null then
    raise exception 'Receipt key is required';
  end if;

  request_fingerprint := pg_catalog.md5(
    concat_ws(
      '|',
      target_transfer_id::text,
      btrim(target_actor_staff_name),
      btrim(target_reason)
    )
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('stock-transfer-return:' || target_receipt_key::text, 0)
  );

  select receipt.*
  into saved_receipt
  from public.stock_transfer_receipts receipt
  where receipt.receipt_key = target_receipt_key;

  if saved_receipt.id is not null then
    if saved_receipt.transfer_id <> target_transfer_id then
      raise exception 'Receipt key belongs to another transfer';
    end if;
    if saved_receipt.receipt_type <> 'return'
      or saved_receipt.request_fingerprint <> request_fingerprint then
      raise exception 'Receipt key was already used for a different operation';
    end if;
    return public.pos_stock_transfer_payload(target_transfer_id);
  end if;

  select transfer.*
  into selected_transfer
  from public.stock_transfers transfer
  where transfer.id = target_transfer_id
  for update;

  if selected_transfer.id is null then
    raise exception 'Transfer not found';
  end if;
  if selected_transfer.status not in ('in_transit', 'partially_received') then
    raise exception 'Transfer has no stock available to return';
  end if;

  if not exists (
    select 1
    from public.stock_transfer_photos photo
    where photo.transfer_id = selected_transfer.id
      and photo.receipt_key = target_receipt_key
  ) then
    raise exception 'At least one return photo must be uploaded before returning stock';
  end if;

  perform item.id
  from public.stock_transfer_items item
  where item.transfer_id = selected_transfer.id
  order by item.id
  for update;

  select
    coalesce(sum(
      item.dispatched_quantity - item.received_good_quantity
        - item.received_damaged_quantity - item.missing_quantity - item.returned_quantity
    ), 0)::integer,
    array_agg(distinct item.product_id order by item.product_id)
  into remaining_total, product_ids
  from public.stock_transfer_items item
  where item.transfer_id = selected_transfer.id
    and item.dispatched_quantity - item.received_good_quantity
      - item.received_damaged_quantity - item.missing_quantity - item.returned_quantity > 0;

  if remaining_total <= 0 then
    raise exception 'Transfer has no remaining stock to return';
  end if;

  insert into public.stock_transfer_receipts (
    transfer_id,
    receipt_key,
    request_fingerprint,
    receipt_type,
    received_by,
    note
  )
  values (
    selected_transfer.id,
    target_receipt_key,
    request_fingerprint,
    'return',
    btrim(target_actor_staff_name),
    btrim(target_reason)
  )
  returning * into saved_receipt;

  insert into public.stock_transfer_receipt_items (
    receipt_id,
    transfer_item_id,
    returned_quantity
  )
  select
    saved_receipt.id,
    item.id,
    item.dispatched_quantity - item.received_good_quantity
      - item.received_damaged_quantity - item.missing_quantity - item.returned_quantity
  from public.stock_transfer_items item
  where item.transfer_id = selected_transfer.id
    and item.dispatched_quantity - item.received_good_quantity
      - item.received_damaged_quantity - item.missing_quantity - item.returned_quantity > 0
  order by item.id;

  update public.stock_transfer_items item
  set
    returned_quantity = item.returned_quantity + receipt_item.returned_quantity,
    updated_at = now()
  from public.stock_transfer_receipt_items receipt_item
  where receipt_item.receipt_id = saved_receipt.id
    and receipt_item.transfer_item_id = item.id;

  if selected_transfer.source_stock_mode = 'reserve' then
    perform r.product_id from public.pos_pr_transfer_reserves r
      where r.product_id = any(product_ids) order by r.product_id for update;
    update public.pos_pr_transfer_reserves reserve
      set quantity = reserve.quantity + totals.returned_quantity, updated_at = now()
      from (
        select item.product_id, sum(receipt_item.returned_quantity)::integer as returned_quantity
        from public.stock_transfer_receipt_items receipt_item
        join public.stock_transfer_items item on item.id = receipt_item.transfer_item_id
        where receipt_item.receipt_id = saved_receipt.id group by item.product_id
      ) totals where reserve.product_id = totals.product_id;
  else
  insert into public.product_store_inventory (product_id, store_id, quantity, updated_at)
  select product_row.product_id, selected_transfer.source_store_id, 0, now()
  from unnest(product_ids) as product_row(product_id)
  on conflict (product_id, store_id) do nothing;

  perform inventory.id
  from public.product_store_inventory inventory
  where inventory.product_id = any(product_ids)
    and inventory.store_id = selected_transfer.source_store_id
  order by inventory.product_id
  for update;

  update public.product_store_inventory inventory
  set
    quantity = inventory.quantity + totals.returned_quantity,
    updated_at = now()
  from (
    select item.product_id, sum(receipt_item.returned_quantity)::integer as returned_quantity
    from public.stock_transfer_receipt_items receipt_item
    join public.stock_transfer_items item on item.id = receipt_item.transfer_item_id
    where receipt_item.receipt_id = saved_receipt.id
      and receipt_item.returned_quantity > 0
    group by item.product_id
  ) totals
  where inventory.product_id = totals.product_id
    and inventory.store_id = selected_transfer.source_store_id;

  insert into public.inventory_movements (
    movement_key,
    movement_type,
    product_id,
    store_id,
    quantity_delta,
    quantity_before,
    quantity_after,
    transfer_id,
    transfer_item_id,
    receipt_id,
    actor_staff_name
  )
  select
    'transfer:' || selected_transfer.id || ':receipt:' || saved_receipt.id || ':return:' || item.id,
    'transfer_return',
    item.product_id,
    selected_transfer.source_store_id,
    receipt_item.returned_quantity,
    inventory.quantity - receipt_item.returned_quantity,
    inventory.quantity,
    selected_transfer.id,
    item.id,
    saved_receipt.id,
    btrim(target_actor_staff_name)
  from public.stock_transfer_receipt_items receipt_item
  join public.stock_transfer_items item on item.id = receipt_item.transfer_item_id
  join public.product_store_inventory inventory
    on inventory.product_id = item.product_id
    and inventory.store_id = selected_transfer.source_store_id
  where receipt_item.receipt_id = saved_receipt.id
    and receipt_item.returned_quantity > 0;

  end if;

  update public.stock_transfer_photos photo
  set receipt_id = saved_receipt.id
  where photo.transfer_id = selected_transfer.id
    and photo.receipt_key = target_receipt_key
    and photo.receipt_id is null;

  update public.stock_transfers transfer
  set
    status = 'returned',
    completed_at = now(),
    updated_at = now()
  where transfer.id = selected_transfer.id;

  if selected_transfer.source_stock_mode = 'physical' then
    perform public.refresh_product_stock_totals(product_ids);
  end if;

  return public.pos_stock_transfer_payload(selected_transfer.id);
end;
$function$;
