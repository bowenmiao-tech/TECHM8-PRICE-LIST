begin;

with input_groups as (
  select * from jsonb_to_recordset($catalog$[{"code":"TM8-GRP-CCH-K28","slug":"tm8-grp-cch-k28","name":"K28 USB-A + USB-C Car Charger","product_family":"USB-A + USB-C Car Charger","main_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.20039600%201725522934.jpg","status":"active","is_pos_visible":true,"is_visible":false},{"code":"TM8-GRP-CCH-35W-3PORT","slug":"tm8-grp-cch-35w-3port","name":"35W USB-C + Dual USB-A Car Charger","product_family":"35W 3-Port Car Charger","main_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/166988044542457305.jpg","status":"active","is_pos_visible":true,"is_visible":false},{"code":"TM8-GRP-CCH-DUAL-SOCKET","slug":"tm8-grp-cch-dual-socket","name":"Dual Socket + USB Car Charger","product_family":"Dual Socket Car Charger","main_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663976296.jpg","status":"active","is_pos_visible":true,"is_visible":false},{"code":"TM8-GRP-CCH-45W-2C","slug":"tm8-grp-cch-45w-2c","name":"45W Dual USB-C Car Charger","product_family":"45W Dual USB-C Car Charger","main_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663976196.jpg","status":"active","is_pos_visible":true,"is_visible":false}]$catalog$::jsonb) as x(
    code text,
    slug text,
    name text,
    product_family text,
    main_image_url text,
    status text,
    is_pos_visible boolean,
    is_visible boolean
  )
)
insert into public.product_groups (
  code, slug, name, category_id, product_family, fit_profile_id,
  main_image_url, status, is_pos_visible, is_visible
)
select
  input_groups.code,
  input_groups.slug,
  input_groups.name,
  category.id,
  input_groups.product_family,
  null,
  input_groups.main_image_url,
  input_groups.status,
  input_groups.is_pos_visible,
  input_groups.is_visible
from input_groups
join public.categories category on category.slug = 'car-chargers'
on conflict (code) do update
set slug = excluded.slug,
    name = excluded.name,
    category_id = excluded.category_id,
    product_family = excluded.product_family,
    main_image_url = excluded.main_image_url,
    status = excluded.status,
    is_pos_visible = excluded.is_pos_visible,
    is_visible = excluded.is_visible,
    updated_at = timezone('utc'::text, now());

with input_products as (
  select * from jsonb_to_recordset($catalog$[{"sku":"TM8-CCH-9322","slug":"tm8-cch-9322","name":"K28 USB-A + USB-C Car Charger","brand":"Generic","model":"K28","short_description":"USB-A + USB-C Car Charger. For standard 12V/24V vehicle power sockets.","condition_label":"Brand New","compatibility":"Standard 12V/24V vehicle power sockets","cost_price":5,"retail_price":35,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.20039600%201725522934.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2986000093229","product_group_code":"TM8-GRP-CCH-K28","variant_name":null,"variant_color":null,"source_system":"repairdesk_car_chargers","source_external_id":"9322","source_category_path":"2. Charger > Car Charger","import_status":"active","source_metadata":{"original_name":"K28 one USB one Type C Car charger","original_sku":"9322003924","original_upc":"77","source_stock":1,"proposed_stock":0,"inventory_assignment":"none","source_pos_visible":true,"cost_source":"repairdesk_source","image_source":"repairdesk_pos"}},{"sku":"TM8-CCH-7588","slug":"tm8-cch-7588","name":"35W USB-C + Dual USB-A Car Charger - White","brand":"Generic","model":"35W 3-Port","short_description":"35W 3-Port Car Charger. For standard 12V/24V vehicle power sockets.","condition_label":"Brand New","compatibility":"Standard 12V/24V vehicle power sockets","cost_price":5,"retail_price":35,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/166988044542457305.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2986000075881","product_group_code":"TM8-GRP-CCH-35W-3PORT","variant_name":"White","variant_color":"White","source_system":"repairdesk_car_chargers","source_external_id":"7588","source_category_path":"2. Charger > Car Charger","import_status":"active","source_metadata":{"original_name":"1TYPE-C 2USB 35W CAR CHARGER White","original_sku":"7588430","original_upc":"77","source_stock":1,"proposed_stock":0,"inventory_assignment":"none","source_pos_visible":true,"cost_source":"repairdesk_source","image_source":"repairdesk_pos"}},{"sku":"TM8-CCH-7152","slug":"tm8-cch-7152","name":"Dual Socket + USB Car Charger","brand":"Generic","model":"Dual Socket + USB","short_description":"Dual Socket Car Charger. For standard 12V/24V vehicle power sockets.","condition_label":"Brand New","compatibility":"Standard 12V/24V vehicle power sockets","cost_price":5,"retail_price":35,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663976296.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2986000071524","product_group_code":"TM8-GRP-CCH-DUAL-SOCKET","variant_name":null,"variant_color":null,"source_system":"repairdesk_car_chargers","source_external_id":"7152","source_category_path":"2. Charger > Car Charger","import_status":"active","source_metadata":{"original_name":"2 cigarette lighter and USB Car Charger","original_sku":"7152187","original_upc":"77","source_stock":1,"proposed_stock":0,"inventory_assignment":"none","source_pos_visible":true,"cost_source":"repairdesk_source","image_source":"repairdesk_pos"}},{"sku":"TM8-CCH-7151","slug":"tm8-cch-7151","name":"45W Dual USB-C Car Charger - Black","brand":"Generic","model":"45W Dual USB-C","short_description":"45W Dual USB-C Car Charger. For standard 12V/24V vehicle power sockets.","condition_label":"Brand New","compatibility":"Standard 12V/24V vehicle power sockets","cost_price":5,"retail_price":35,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663976196.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2986000071517","product_group_code":"TM8-GRP-CCH-45W-2C","variant_name":"Black","variant_color":"Black","source_system":"repairdesk_car_chargers","source_external_id":"7151","source_category_path":"2. Charger > Car Charger","import_status":"active","source_metadata":{"original_name":"2 Type C 45W Car Charger Black","original_sku":"7151186","original_upc":"77","source_stock":1,"proposed_stock":0,"inventory_assignment":"none","source_pos_visible":true,"cost_source":"repairdesk_source","image_source":"repairdesk_pos"}},{"sku":"TM8-CCH-7150","slug":"tm8-cch-7150","name":"45W Dual USB-C Car Charger - White","brand":"Generic","model":"45W Dual USB-C","short_description":"45W Dual USB-C Car Charger. For standard 12V/24V vehicle power sockets.","condition_label":"Brand New","compatibility":"Standard 12V/24V vehicle power sockets","cost_price":5,"retail_price":35,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663976176.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2986000071500","product_group_code":"TM8-GRP-CCH-45W-2C","variant_name":"White","variant_color":"White","source_system":"repairdesk_car_chargers","source_external_id":"7150","source_category_path":"2. Charger > Car Charger","import_status":"active","source_metadata":{"original_name":"2 Type C 45W Car Charger White","original_sku":"7150185","original_upc":"77","source_stock":0,"proposed_stock":0,"inventory_assignment":"none","source_pos_visible":true,"cost_source":"repairdesk_source","image_source":"repairdesk_pos"}},{"sku":"TM8-CCH-6575","slug":"tm8-cch-6575","name":"35W USB-C + Dual USB-A Car Charger - Black","brand":"Generic","model":"35W 3-Port","short_description":"35W 3-Port Car Charger. For standard 12V/24V vehicle power sockets.","condition_label":"Brand New","compatibility":"Standard 12V/24V vehicle power sockets","cost_price":5,"retail_price":35,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/166988051142456286.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2986000065752","product_group_code":"TM8-GRP-CCH-35W-3PORT","variant_name":"Black","variant_color":"Black","source_system":"repairdesk_car_chargers","source_external_id":"6575","source_category_path":"2. Charger > Car Charger","import_status":"active","source_metadata":{"original_name":"1TYPE-C 2USB 35W CAR CHARGER Black","original_sku":"65755","original_upc":"77","source_stock":1,"proposed_stock":0,"inventory_assignment":"none","source_pos_visible":true,"cost_source":"repairdesk_source","image_source":"repairdesk_pos"}}]$catalog$::jsonb) as x(
    sku text,
    slug text,
    name text,
    brand text,
    model text,
    short_description text,
    condition_label text,
    compatibility text,
    cost_price numeric,
    retail_price numeric,
    image_url text,
    stock_quantity integer,
    is_visible boolean,
    is_pos_visible boolean,
    upc text,
    product_group_code text,
    variant_name text,
    variant_color text,
    source_system text,
    source_external_id text,
    source_category_path text,
    import_status text,
    source_metadata jsonb
  )
)
insert into public.products (
  sku, slug, name, brand, model, category_id, short_description,
  condition_label, compatibility, cost_price, retail_price, image_url,
  stock_quantity, is_visible, is_pos_visible, upc, product_group_id,
  variant_name, variant_color, source_system, source_external_id,
  source_category_path, import_status, source_metadata
)
select
  input_products.sku,
  input_products.slug,
  input_products.name,
  input_products.brand,
  input_products.model,
  category.id,
  input_products.short_description,
  input_products.condition_label,
  input_products.compatibility,
  input_products.cost_price,
  input_products.retail_price,
  input_products.image_url,
  0,
  false,
  true,
  input_products.upc,
  product_group.id,
  input_products.variant_name,
  input_products.variant_color,
  input_products.source_system,
  input_products.source_external_id,
  input_products.source_category_path,
  input_products.import_status,
  input_products.source_metadata
from input_products
join public.categories category on category.slug = 'car-chargers'
join public.product_groups product_group on product_group.code = input_products.product_group_code
on conflict (sku) do update
set slug = excluded.slug,
    name = excluded.name,
    brand = excluded.brand,
    model = excluded.model,
    category_id = excluded.category_id,
    short_description = excluded.short_description,
    condition_label = excluded.condition_label,
    compatibility = excluded.compatibility,
    cost_price = excluded.cost_price,
    retail_price = excluded.retail_price,
    image_url = excluded.image_url,
    is_visible = false,
    is_pos_visible = true,
    upc = excluded.upc,
    product_group_id = excluded.product_group_id,
    variant_name = excluded.variant_name,
    variant_color = excluded.variant_color,
    source_category_path = excluded.source_category_path,
    import_status = excluded.import_status,
    source_metadata = excluded.source_metadata,
    updated_at = timezone('utc'::text, now())
where public.products.source_system = 'repairdesk_car_chargers'
  and public.products.source_external_id = excluded.source_external_id;

commit;

select
  count(*) as imported_products,
  count(distinct product_group_id) as imported_groups,
  count(*) filter (where stock_quantity <> 0) as products_with_stock,
  count(*) filter (where is_visible) as website_visible_products,
  count(*) filter (where is_pos_visible and import_status = 'active') as active_pos_products
from public.products
where source_system = 'repairdesk_car_chargers';
