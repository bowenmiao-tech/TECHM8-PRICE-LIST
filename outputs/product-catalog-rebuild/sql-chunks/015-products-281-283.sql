begin;

with input as (
  select * from jsonb_to_recordset($catalog$[{"sku":"TM8-TAB-6367","slug":"tm8-tab-6367","name":"Hard Case for iPad 9.7-inch (Gen 5/6 and Air 1/2) - Blue","brand":"Apple","model":"iPad 9.7-inch (Gen 5/6 and Air 1/2)","short_description":"Hard Case in Blue.","condition_label":"Brand New","compatibility":"iPad 5th Gen 9.7; iPad 6th Gen 9.7; iPad Air 1 9.7; iPad Air 2 9.7","cost_price":15,"retail_price":49.95,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1643162293.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":false,"upc":"2999000063673","product_group_code":"TM8-GRP-IPAD-97-LEGACY-HDC","variant_name":"Blue","variant_color":"Blue","source_system":"repairdesk_tablet_cases","source_external_id":"6367","source_category_path":"iPad 9.7 Inch","import_status":"review","source_metadata":{"original_name":"iPad Hard Case 9.7 Inch Blue","source_stock":1,"proposed_stock":0,"inventory_assignment":"none","repairdesk_product_id":"42456077","inventory_index_id":"50748713","variant_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1643162293.jpg","group_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1643162474.jpg","cost_rule":"Confirmed: Hard Case"}},{"sku":"TM8-TAB-6366","slug":"tm8-tab-6366","name":"Hard Case for iPad 9.7-inch (Gen 5/6 and Air 1/2) - Green","brand":"Apple","model":"iPad 9.7-inch (Gen 5/6 and Air 1/2)","short_description":"Hard Case in Green.","condition_label":"Brand New","compatibility":"iPad 5th Gen 9.7; iPad 6th Gen 9.7; iPad Air 1 9.7; iPad Air 2 9.7","cost_price":15,"retail_price":49.95,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1643162232.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":false,"upc":"2999000063666","product_group_code":"TM8-GRP-IPAD-97-LEGACY-HDC","variant_name":"Green","variant_color":"Green","source_system":"repairdesk_tablet_cases","source_external_id":"6366","source_category_path":"iPad 9.7 Inch","import_status":"review","source_metadata":{"original_name":"iPad Hard Case 9.7 Inch Green","source_stock":0,"proposed_stock":0,"inventory_assignment":"none","repairdesk_product_id":"42456076","inventory_index_id":"50748712","variant_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1643162232.jpg","group_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1643162474.jpg","cost_rule":"Confirmed: Hard Case"}},{"sku":"TM8-TAB-6365","slug":"tm8-tab-6365","name":"Hard Case for iPad 9.7-inch (Gen 5/6 and Air 1/2) - Purple","brand":"Apple","model":"iPad 9.7-inch (Gen 5/6 and Air 1/2)","short_description":"Hard Case in Purple.","condition_label":"Brand New","compatibility":"iPad 5th Gen 9.7; iPad 6th Gen 9.7; iPad Air 1 9.7; iPad Air 2 9.7","cost_price":15,"retail_price":49.95,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1643162134.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":false,"upc":"2999000063659","product_group_code":"TM8-GRP-IPAD-97-LEGACY-HDC","variant_name":"Purple","variant_color":"Purple","source_system":"repairdesk_tablet_cases","source_external_id":"6365","source_category_path":"iPad 9.7 Inch","import_status":"review","source_metadata":{"original_name":"iPad Hard Case 9.7 Inch Purple","source_stock":0,"proposed_stock":0,"inventory_assignment":"none","repairdesk_product_id":"42456075","inventory_index_id":"50748711","variant_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1643162134.jpg","group_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1643162474.jpg","cost_rule":"Confirmed: Hard Case"}}]$catalog$::jsonb) as x(
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
  input.sku,
  input.slug,
  input.name,
  input.brand,
  input.model,
  category.id,
  input.short_description,
  input.condition_label,
  nullif(input.compatibility, ''),
  input.cost_price,
  input.retail_price,
  nullif(input.image_url, ''),
  0,
  false,
  false,
  input.upc,
  product_group.id,
  input.variant_name,
  input.variant_color,
  input.source_system,
  input.source_external_id,
  input.source_category_path,
  input.import_status,
  input.source_metadata
from input
join public.categories category on category.slug = 'ipad-tablet-cases'
join public.product_groups product_group on product_group.code = input.product_group_code
on conflict (sku) do update
set name = excluded.name,
    brand = excluded.brand,
    model = excluded.model,
    category_id = excluded.category_id,
    short_description = excluded.short_description,
    condition_label = excluded.condition_label,
    compatibility = excluded.compatibility,
    cost_price = excluded.cost_price,
    retail_price = excluded.retail_price,
    image_url = excluded.image_url,
    upc = excluded.upc,
    product_group_id = excluded.product_group_id,
    variant_name = excluded.variant_name,
    variant_color = excluded.variant_color,
    source_system = excluded.source_system,
    source_external_id = excluded.source_external_id,
    source_category_path = excluded.source_category_path,
    import_status = case when products.import_status = 'active' then products.import_status else excluded.import_status end,
    is_visible = case when products.import_status = 'active' then products.is_visible else false end,
    is_pos_visible = case when products.import_status = 'active' then products.is_pos_visible else false end,
    source_metadata = excluded.source_metadata,
    updated_at = timezone('utc'::text, now());

commit;
