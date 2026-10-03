-- Run in the PRODUCT project. All purchase/inventory fixtures roll back.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '25s';
do $test$
declare
  p bigint;
  ff bigint := (select id from public.stores where slug = 'fairfield');
  pr bigint := (select id from public.stores where slug = 'park-ridge');
  category bigint := (select id from public.pos_category_taxonomy where active order by id limit 1);
  supplier bigint;
  forwarder bigint;
  order_id bigint;
  item1 bigint;
  item2 bigint;
  parcel bigint;
  shipment bigint;
  receipt uuid := gen_random_uuid();
  ff_before integer;
  pr_before integer;
  stock_before integer;
  created jsonb;
  snapshot jsonb;
  rejected boolean;
begin
  select id into p from public.products where is_pos_visible order by id limit 1;
  if p is null or ff is null or pr is null or category is null then
    raise exception 'Missing test product/store/category';
  end if;
  ff_before := coalesce((select quantity from public.product_store_inventory where product_id = p and store_id = ff), 0);
  pr_before := coalesce((select quantity from public.product_store_inventory where product_id = p and store_id = pr), 0);
  select stock_quantity into stock_before from public.products where id = p;

  supplier := (public.purchase_admin_save_supplier(
    jsonb_build_object('name', 'Rollback supplier', 'wechat', 'wx-test'), 'Purchase test')->>'id')::bigint;
  forwarder := (public.purchase_admin_save_forwarder(
    jsonb_build_object('name', 'Rollback forwarder', 'channels', jsonb_build_array('海运普货', ' '),
      'tracking_prefixes', jsonb_build_array('rb')), 'Purchase test')->>'id')::bigint;
  if (select tracking_prefixes from public.purchase_forwarders where id = forwarder) <> array['RB'] then
    raise exception 'Forwarder prefixes must be trimmed and upper-cased';
  end if;

  order_id := (public.purchase_admin_save_order(jsonb_build_object(
    'supplier_id', supplier,
    'goods_amount', 300,
    'items', jsonb_build_array(
      jsonb_build_object('description', 'Test case', 'quantity', 30, 'unit_cost', 5),
      jsonb_build_object('description', 'Test cable', 'quantity', 10, 'unit_cost', 2)
    )
  ), 'Purchase test')->>'id')::bigint;
  select id into item1 from public.purchase_order_items where purchase_order_id = order_id and line_no = 1;
  select id into item2 from public.purchase_order_items where purchase_order_id = order_id and line_no = 2;
  if item1 is null or item2 is null then raise exception 'Order items were not saved in order'; end if;

  rejected := false;
  begin
    perform public.purchase_admin_save_order(jsonb_build_object('id', order_id,
      'items', jsonb_build_array(jsonb_build_object('description', 'No qty'))), 'Purchase test');
  exception when others then rejected := sqlerrm like '%quantity above zero%';
  end;
  if not rejected then raise exception 'An order line without a quantity must be rejected'; end if;

  parcel := (public.purchase_admin_save_parcel(jsonb_build_object(
    'purchase_order_id', order_id, 'contents', 'Test case x30, cable x10',
    'courier', '顺丰', 'tracking_no', 'SF-ROLLBACK-1', 'forwarder_id', forwarder
  ), 'Purchase test')->>'id')::bigint;
  if (select supplier_id from public.purchase_parcels where id = parcel) <> supplier then
    raise exception 'Parcel must inherit the order supplier';
  end if;

  shipment := (public.purchase_admin_save_shipment(jsonb_build_object(
    'forwarder_id', forwarder, 'channel', '海运普货', 'status', 'declared',
    'parcel_ids', jsonb_build_array(parcel)
  ), 'Purchase test')->>'id')::bigint;
  if (select status from public.purchase_shipments where id = shipment) <> 'declared' then
    raise exception 'A batch without an international number stays declared';
  end if;
  if (select declared_at from public.purchase_shipments where id = shipment) is null then
    raise exception 'Declaring a batch must stamp declared_at';
  end if;

  rejected := false;
  begin
    perform public.purchase_admin_post_receipt(jsonb_build_object(
      'shipment_id', shipment, 'receipt_key', gen_random_uuid(),
      'lines', jsonb_build_array(jsonb_build_object('product_id', p, 'store_id', ff, 'quantity', 1))
    ), 'Purchase test');
  exception when others then rejected := sqlerrm like '%shipped or arrived%';
  end;
  if not rejected then raise exception 'A batch still at the forwarder must not be counted into stock'; end if;

  perform public.purchase_admin_save_shipment(jsonb_build_object(
    'id', shipment, 'forwarder_id', forwarder, 'channel', '海运普货', 'status', 'declared',
    'tracking_numbers', jsonb_build_array('RB2', ' ', 'RB1', 'RB2')
  ), 'Purchase test');
  if (select tracking_numbers from public.purchase_shipments where id = shipment) <> array['RB2', 'RB1'] then
    raise exception 'Tracking numbers must keep entry order without blanks or duplicates';
  end if;
  if (select status from public.purchase_shipments where id = shipment) <> 'shipped'
    or (select shipped_at from public.purchase_shipments where id = shipment) is null then
    raise exception 'An international number means the batch has shipped';
  end if;

  perform public.purchase_admin_save_shipment(jsonb_build_object(
    'id', shipment, 'forwarder_id', forwarder, 'channel', '海运普货', 'status', 'arrived',
    'tracking_numbers', jsonb_build_array('RB2', 'RB1')
  ), 'Purchase test');
  if (select shipment_id from public.purchase_parcels where id = parcel) <> shipment then
    raise exception 'Saving a batch without parcel_ids must keep its parcels';
  end if;

  perform public.purchase_admin_post_receipt(jsonb_build_object(
    'shipment_id', shipment, 'receipt_key', receipt, 'update_cost', false,
    'lines', jsonb_build_array(
      jsonb_build_object('parcel_id', parcel, 'purchase_order_item_id', item1, 'product_id', p, 'store_id', ff, 'quantity', 20),
      jsonb_build_object('parcel_id', parcel, 'purchase_order_item_id', item1, 'product_id', p, 'store_id', pr, 'quantity', 8, 'damaged_quantity', 2)
    )
  ), 'Purchase test');

  if (select quantity from public.product_store_inventory where product_id = p and store_id = ff) <> ff_before + 20 then
    raise exception 'Fairfield stock was not credited';
  end if;
  if (select quantity from public.product_store_inventory where product_id = p and store_id = pr) <> pr_before + 8 then
    raise exception 'Damaged units must not be credited to stock';
  end if;
  if (select stock_quantity from public.products where id = p) <> stock_before + 28 then
    raise exception 'Product stock total was not refreshed';
  end if;
  if (select status from public.purchase_shipments where id = shipment) <> 'received' then
    raise exception 'Counting an arrived batch must mark it received';
  end if;
  if (select product_id from public.purchase_order_items where id = item1) <> p then
    raise exception 'The counted SKU must be remembered on the order line';
  end if;
  if not exists (select 1 from public.purchase_receipt_lines where receipt_key = receipt and line_no = 1
      and quantity_before = ff_before and quantity_after = ff_before + 20) then
    raise exception 'Receipt line audit is missing';
  end if;

  perform public.purchase_admin_post_receipt(jsonb_build_object(
    'shipment_id', shipment, 'receipt_key', receipt,
    'lines', jsonb_build_array(jsonb_build_object('product_id', p, 'store_id', ff, 'quantity', 20))
  ), 'Purchase test');
  if (select quantity from public.product_store_inventory where product_id = p and store_id = ff) <> ff_before + 20 then
    raise exception 'A retried receipt credited stock twice';
  end if;

  snapshot := public.purchase_admin_snapshot();
  if not exists (
    select 1 from jsonb_array_elements(snapshot->'orders') o, jsonb_array_elements(o->'items') i
    where (i->>'id')::bigint = item1 and (i->>'received_quantity')::integer = 30
  ) then
    raise exception 'Snapshot must report received quantity per order line';
  end if;

  rejected := false;
  begin
    perform public.purchase_admin_delete_parcel(parcel, 'Purchase test');
  exception when others then rejected := sqlerrm like '%already been counted%';
  end;
  if not rejected then raise exception 'A counted parcel must not be deletable'; end if;

  rejected := false;
  begin
    perform public.purchase_admin_save_shipment(jsonb_build_object(
      'id', shipment, 'status', 'received', 'parcel_ids', '[]'::jsonb), 'Purchase test');
  exception when others then rejected := sqlerrm like '%cannot be removed%';
  end;
  if not rejected then raise exception 'A counted parcel must not leave its batch'; end if;

  rejected := false;
  begin
    perform public.purchase_admin_save_order(jsonb_build_object('id', order_id, 'supplier_id', supplier,
      'items', jsonb_build_array(jsonb_build_object('id', item2, 'description', 'Test cable', 'quantity', 10))
    ), 'Purchase test');
  exception when others then rejected := sqlerrm like '%already been received%';
  end;
  if not rejected then raise exception 'A received order line must not be removable'; end if;

  perform public.purchase_admin_post_receipt(jsonb_build_object(
    'shipment_id', shipment, 'receipt_key', gen_random_uuid(), 'mark_stocked', true, 'lines', '[]'::jsonb
  ), 'Purchase test');
  if (select status from public.purchase_shipments where id = shipment) <> 'stocked' then
    raise exception 'Finishing a count must mark the batch stocked';
  end if;

  created := public.purchase_admin_create_product(jsonb_build_object(
    'name', 'Rollback purchase SKU', 'pos_category_id', category, 'retail_price', 19.95,
    'cost_price', 3.2, 'supplier_id', supplier
  ), 'Purchase test');
  if (created->'product'->>'sku') !~ '^TM8-CN-[0-9]{6}-[0-9A-F]{4}$' then
    raise exception 'Generated SKU has the wrong shape: %', created->'product'->>'sku';
  end if;
  if not exists (select 1 from public.products where id = (created->'product'->>'id')::bigint
      and not is_visible and is_pos_visible and pos_category_id = category and source_system = 'china_purchase') then
    raise exception 'New purchase SKU must be POS-visible and hidden online';
  end if;
  if (public.purchase_admin_search_products('rollback purchase sku', 5)->0->>'id')::bigint
      <> (created->'product'->>'id')::bigint then
    raise exception 'Product search must find the new SKU';
  end if;

  rejected := false;
  begin
    perform public.purchase_admin_create_product(jsonb_build_object(
      'name', 'Duplicate', 'sku', created->'product'->>'sku', 'pos_category_id', category, 'retail_price', 1
    ), 'Purchase test');
  exception when others then rejected := sqlerrm like '%already used%';
  end;
  if not rejected then raise exception 'Duplicate SKUs must be rejected'; end if;

  rejected := false;
  begin
    perform public.purchase_admin_delete_order(order_id, 'Purchase test');
  exception when others then rejected := sqlerrm like '%parcels first%';
  end;
  if not rejected then raise exception 'An order with parcels must not be deletable'; end if;
end;
$test$;
rollback;
