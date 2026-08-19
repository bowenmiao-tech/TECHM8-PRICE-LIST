create or replace function public.receive_pos_stock_transfer(
  target_transfer_id bigint,
  target_receipt_key uuid,
  target_lines jsonb,
  target_finalize boolean,
  target_actor_staff_name text,
  target_note text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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

  if returned_total > 0 then
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
$$;

create or replace function public.list_pos_stock_transfers(
  target_status text,
  target_store_slug text,
  target_search_query text,
  target_limit integer
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(listed) order by listed.dispatched_at desc), '[]'::jsonb)
  from (
    select
      transfer.id,
      transfer.transfer_number,
      transfer.status,
      source_store.slug as source_store_slug,
      source_store.name as source_store_name,
      destination_store.slug as destination_store_slug,
      destination_store.name as destination_store_name,
      transfer.dispatched_by,
      transfer.dispatch_note,
      transfer.dispatched_at,
      transfer.completed_at,
      item_totals.product_count,
      item_totals.dispatched_quantity,
      item_totals.received_good_quantity,
      item_totals.issue_quantity,
      item_totals.remaining_quantity,
      photo_totals.photo_count
    from public.stock_transfers transfer
    join public.stores source_store on source_store.id = transfer.source_store_id
    join public.stores destination_store on destination_store.id = transfer.destination_store_id
    cross join lateral (
      select
        count(*)::integer as product_count,
        coalesce(sum(item.dispatched_quantity), 0)::integer as dispatched_quantity,
        coalesce(sum(item.received_good_quantity), 0)::integer as received_good_quantity,
        coalesce(sum(
          item.received_damaged_quantity + item.missing_quantity + item.returned_quantity
        ), 0)::integer as issue_quantity,
        coalesce(sum(
          item.dispatched_quantity - item.received_good_quantity
            - item.received_damaged_quantity - item.missing_quantity - item.returned_quantity
        ), 0)::integer as remaining_quantity
      from public.stock_transfer_items item
      where item.transfer_id = transfer.id
    ) item_totals
    cross join lateral (
      select count(*)::integer as photo_count
      from public.stock_transfer_photos photo
      where photo.transfer_id = transfer.id
    ) photo_totals
    where (
      coalesce(nullif(btrim(target_status), ''), 'all') = 'all'
      or (btrim(target_status) = 'open' and transfer.status in ('in_transit', 'partially_received'))
      or transfer.status = btrim(target_status)
    )
      and (
        source_store.slug = btrim(coalesce(target_store_slug, ''))
        or destination_store.slug = btrim(coalesce(target_store_slug, ''))
      )
      and (
        coalesce(nullif(btrim(target_search_query), ''), '') = ''
        or transfer.transfer_number ilike '%' || btrim(target_search_query) || '%'
        or transfer.dispatched_by ilike '%' || btrim(target_search_query) || '%'
        or exists (
          select 1
          from public.stock_transfer_items search_item
          where search_item.transfer_id = transfer.id
            and (
              search_item.sku_snapshot ilike '%' || btrim(target_search_query) || '%'
              or search_item.name_snapshot ilike '%' || btrim(target_search_query) || '%'
              or coalesce(search_item.barcode_snapshot, '') ilike '%' || btrim(target_search_query) || '%'
            )
        )
      )
    order by transfer.dispatched_at desc
    limit least(greatest(coalesce(target_limit, 100), 1), 200)
  ) listed;
$$;

create or replace function public.pos_stock_transfer_payload_for_store(
  target_transfer_id bigint,
  target_store_slug text
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.pos_stock_transfer_payload(transfer.id)
    || jsonb_build_object(
      'current_store_role',
      case
        when source_store.slug = btrim(coalesce(target_store_slug, '')) then 'source'
        when destination_store.slug = btrim(coalesce(target_store_slug, '')) then 'destination'
      end
    )
  from public.stock_transfers transfer
  join public.stores source_store on source_store.id = transfer.source_store_id
  join public.stores destination_store on destination_store.id = transfer.destination_store_id
  where transfer.id = target_transfer_id
    and (
      source_store.slug = btrim(coalesce(target_store_slug, ''))
      or destination_store.slug = btrim(coalesce(target_store_slug, ''))
    );
$$;

do $correction$
declare
  corrected_item record;
  before_quantity integer;
  corrected_product_ids bigint[] := array[]::bigint[];
begin
  for corrected_item in
    select
      item.id as transfer_item_id,
      item.transfer_id,
      item.product_id,
      item.missing_quantity as quantity_to_restore,
      transfer.source_store_id
    from public.stock_transfer_items item
    join public.stock_transfers transfer on transfer.id = item.transfer_id
    where item.missing_quantity > 0
      and exists (
        select 1
        from public.stock_transfer_receipt_items receipt_item
        join public.stock_transfer_receipts receipt on receipt.id = receipt_item.receipt_id
        where receipt_item.transfer_item_id = item.id
          and receipt.receipt_type = 'receive'
          and receipt_item.missing_quantity > 0
      )
    order by item.transfer_id, item.id
    for update of item
  loop
    insert into public.product_store_inventory (product_id, store_id, quantity, updated_at)
    values (corrected_item.product_id, corrected_item.source_store_id, 0, now())
    on conflict (product_id, store_id) do nothing;

    select inventory.quantity
    into before_quantity
    from public.product_store_inventory inventory
    where inventory.product_id = corrected_item.product_id
      and inventory.store_id = corrected_item.source_store_id
    for update;

    update public.product_store_inventory inventory
    set
      quantity = inventory.quantity + corrected_item.quantity_to_restore,
      updated_at = now()
    where inventory.product_id = corrected_item.product_id
      and inventory.store_id = corrected_item.source_store_id;

    update public.stock_transfer_receipt_items receipt_item
    set
      returned_quantity = receipt_item.returned_quantity + receipt_item.missing_quantity,
      missing_quantity = 0
    from public.stock_transfer_receipts receipt
    where receipt.id = receipt_item.receipt_id
      and receipt.receipt_type = 'receive'
      and receipt_item.transfer_item_id = corrected_item.transfer_item_id
      and receipt_item.missing_quantity > 0;

    update public.stock_transfer_items item
    set
      returned_quantity = item.returned_quantity + item.missing_quantity,
      missing_quantity = 0,
      updated_at = now()
    where item.id = corrected_item.transfer_item_id;

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
    values (
      'transfer:' || corrected_item.transfer_id || ':legacy-unreceived-return:' || corrected_item.transfer_item_id,
      'transfer_return',
      corrected_item.product_id,
      corrected_item.source_store_id,
      corrected_item.quantity_to_restore,
      before_quantity,
      before_quantity + corrected_item.quantity_to_restore,
      corrected_item.transfer_id,
      corrected_item.transfer_item_id,
      'System correction: unreceived stock restored'
    )
    on conflict (movement_key) do nothing;

    corrected_product_ids := array_append(corrected_product_ids, corrected_item.product_id);
  end loop;

  update public.stock_transfers transfer
  set
    status = case
      when totals.remaining_quantity > 0 then 'partially_received'
      when totals.issue_quantity > 0 then 'completed_with_issues'
      else 'completed'
    end,
    completed_at = case
      when totals.remaining_quantity = 0 then coalesce(transfer.completed_at, now())
      else null
    end,
    updated_at = now()
  from (
    select
      item.transfer_id,
      sum(
        item.dispatched_quantity - item.received_good_quantity
          - item.received_damaged_quantity - item.missing_quantity - item.returned_quantity
      )::integer as remaining_quantity,
      sum(
        item.received_damaged_quantity + item.missing_quantity + item.returned_quantity
      )::integer as issue_quantity
    from public.stock_transfer_items item
    group by item.transfer_id
  ) totals
  where transfer.id = totals.transfer_id
    and transfer.id in (
      select movement.transfer_id
      from public.inventory_movements movement
      where movement.movement_key like 'transfer:%:legacy-unreceived-return:%'
    );

  if coalesce(array_length(corrected_product_ids, 1), 0) > 0 then
    perform public.refresh_product_stock_totals(
      array(select distinct product_id from unnest(corrected_product_ids) product_id order by product_id)
    );
  end if;
end;
$correction$;

revoke execute on function public.pos_stock_transfer_payload_for_store(bigint, text) from public, anon, authenticated;
grant execute on function public.pos_stock_transfer_payload_for_store(bigint, text) to service_role;

revoke execute on function public.receive_pos_stock_transfer(bigint, uuid, jsonb, boolean, text, text) from public, anon, authenticated;
grant execute on function public.receive_pos_stock_transfer(bigint, uuid, jsonb, boolean, text, text) to service_role;

revoke execute on function public.list_pos_stock_transfers(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.list_pos_stock_transfers(text, text, text, integer) to service_role;
