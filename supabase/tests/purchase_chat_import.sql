-- Run in the PRODUCT project. All fixtures roll back.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '25s';
do $test$
declare
  supplier bigint;
  forwarder bigint;
  other bigint;
  result jsonb;
  order_id bigint;
  snapshot jsonb;
  rejected boolean;
  stamp text := to_char(clock_timestamp(), 'HH24MISSUS');
begin
  supplier := (public.purchase_admin_save_supplier(jsonb_build_object('name', 'Chat test supplier ' || stamp), 'Chat test')->>'id')::bigint;
  forwarder := (public.purchase_admin_save_forwarder(jsonb_build_object(
    'name', 'Chat test forwarder ' || stamp, 'warehouse_address', '深圳宝安', 'ship_threshold_kg', 25
  ), 'Chat test')->>'id')::bigint;

  snapshot := public.purchase_admin_snapshot();
  if not exists (
    select 1 from jsonb_array_elements(snapshot->'forwarders') entry
    where (entry->>'id')::bigint = forwarder and (entry->>'ship_threshold_kg')::numeric = 25
  ) then
    raise exception 'Snapshot must expose the forwarder ship threshold';
  end if;

  -- A new order with two lines; the second parcel repeats the first number.
  result := public.purchase_admin_import_chat(jsonb_build_object(
    'supplier_id', supplier,
    'forwarder_id', forwarder,
    'items', jsonb_build_array(
      jsonb_build_object('description', 'iPhone 13 屏幕', 'quantity', 20, 'unit_cost', 35),
      jsonb_build_object('description', 'iPhone 12 电池', 'quantity', 10, 'unit_cost', 18.5)
    ),
    'parcels', jsonb_build_array(
      jsonb_build_object('tracking_no', 'SF1234 5678 9012' || stamp, 'courier', '顺丰', 'contents', '屏幕 ×20', 'weight_kg', 2.5, 'has_battery', false),
      jsonb_build_object('tracking_no', 'sf123456789012' || stamp, 'courier', '顺丰', 'contents', '重复')
    )
  ), 'Chat test');
  order_id := (result->>'order_id')::bigint;
  if order_id is null or result->>'po_number' is null then raise exception 'Import must create an order: %', result; end if;
  if jsonb_array_length(result->'parcel_ids') <> 1 or jsonb_array_length(result->'skipped') <> 1 then
    raise exception 'Duplicate numbers inside one paste must be skipped: %', result;
  end if;
  if not exists (
    select 1 from public.purchase_orders o
    where o.id = order_id and o.source = 'chat' and o.forwarder_id = forwarder and o.supplier_id = supplier
  ) then
    raise exception 'Imported order must keep supplier, forwarder and source';
  end if;
  if (select count(*) from public.purchase_order_items i where i.purchase_order_id = order_id) <> 2 then
    raise exception 'Imported order must have two lines';
  end if;
  if not exists (
    select 1 from public.purchase_parcels p
    where p.purchase_order_id = order_id and p.tracking_no = 'SF123456789012' || stamp
      and p.forwarder_id = forwarder and p.supplier_id = supplier and p.weight_kg = 2.5
      and p.shipped_at is not null and p.source = 'chat'
  ) then
    raise exception 'Imported parcel must be linked, de-spaced and dated';
  end if;

  -- Later paste for the same order: one new number, one already on file, one extra line.
  result := public.purchase_admin_import_chat(jsonb_build_object(
    'order_id', order_id,
    'items', jsonb_build_array(jsonb_build_object('description', '补货 尾插', 'quantity', 5)),
    'parcels', jsonb_build_array(
      jsonb_build_object('tracking_no', 'SF123456789012' || stamp),
      jsonb_build_object('tracking_no', 'YT9988776655' || stamp, 'courier', '圆通', 'contents', '电池 ×10', 'has_battery', true)
    )
  ), 'Chat test');
  if (result->>'order_id')::bigint <> order_id or jsonb_array_length(result->'parcel_ids') <> 1
    or result->'skipped'->>0 <> 'SF123456789012' || stamp then
    raise exception 'A repeated paste must only add new parcels: %', result;
  end if;
  if (select max(line_no) from public.purchase_order_items i where i.purchase_order_id = order_id) <> 3 then
    raise exception 'Appended lines must continue the numbering';
  end if;
  if not exists (
    select 1 from public.purchase_parcels p
    where p.tracking_no = 'YT9988776655' || stamp and p.forwarder_id = forwarder and p.supplier_id = supplier and p.has_battery
  ) then
    raise exception 'Parcels added to an existing order must inherit its supplier and forwarder';
  end if;

  -- A forwarder picked on the page wins for the new parcels; the order keeps its own.
  other := (public.purchase_admin_save_forwarder(jsonb_build_object('name', 'Chat test other ' || stamp), 'Chat test')->>'id')::bigint;
  perform public.purchase_admin_import_chat(jsonb_build_object(
    'order_id', order_id, 'forwarder_id', other,
    'parcels', jsonb_build_array(jsonb_build_object('tracking_no', 'JT5566' || stamp, 'contents', '尾插'))
  ), 'Chat test');
  if not exists (select 1 from public.purchase_parcels p where p.tracking_no = 'JT5566' || stamp and p.forwarder_id = other) then
    raise exception 'The forwarder chosen on the page must be used for new parcels';
  end if;
  if (select o.forwarder_id from public.purchase_orders o where o.id = order_id) <> forwarder then
    raise exception 'Attaching parcels must not change the order forwarder';
  end if;

  rejected := false;
  begin
    perform public.purchase_admin_import_chat('{}'::jsonb, 'Chat test');
  exception when others then rejected := sqlerrm like '%required%';
  end;
  if not rejected then raise exception 'An empty import must be rejected'; end if;

  -- Older pages do not send forwarder_id or ship_threshold_kg; saving must keep them.
  perform public.purchase_admin_save_order(jsonb_build_object('id', order_id, 'supplier_id', supplier, 'items',
    (select jsonb_agg(jsonb_build_object('id', i.id, 'description', i.description, 'quantity', i.quantity) order by i.line_no)
     from public.purchase_order_items i where i.purchase_order_id = order_id)), 'Chat test');
  if (select o.forwarder_id from public.purchase_orders o where o.id = order_id) is distinct from forwarder then
    raise exception 'Saving an order without forwarder_id must keep it';
  end if;
  perform public.purchase_admin_save_order(jsonb_build_object('id', order_id, 'supplier_id', supplier, 'forwarder_id', null, 'items',
    (select jsonb_agg(jsonb_build_object('id', i.id, 'description', i.description, 'quantity', i.quantity) order by i.line_no)
     from public.purchase_order_items i where i.purchase_order_id = order_id)), 'Chat test');
  if (select o.forwarder_id from public.purchase_orders o where o.id = order_id) is not null then
    raise exception 'Saving an order with forwarder_id null must clear it';
  end if;

  perform public.purchase_admin_save_forwarder(jsonb_build_object('id', forwarder, 'name', 'Chat test forwarder ' || stamp), 'Chat test');
  if (select f.ship_threshold_kg from public.purchase_forwarders f where f.id = forwarder) <> 25 then
    raise exception 'Saving a forwarder without a threshold must keep it';
  end if;
  perform public.purchase_admin_save_forwarder(jsonb_build_object('id', forwarder, 'name', 'Chat test forwarder ' || stamp, 'ship_threshold_kg', 0), 'Chat test');
  if (select f.ship_threshold_kg from public.purchase_forwarders f where f.id = forwarder) is not null then
    raise exception 'A zero threshold must fall back to the default';
  end if;
end;
$test$;
rollback;
