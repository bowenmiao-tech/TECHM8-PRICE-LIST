begin;

insert into public.categories (slug, name, description, sort_order)
values ('phone-cases', 'Phone Cases', 'Phone cases grouped by device, style, and colour.', 330)
on conflict (slug) do update
set name = excluded.name,
    description = excluded.description,
    sort_order = excluded.sort_order,
    updated_at = timezone('utc'::text, now());

insert into public.pos_category_taxonomy (category_name, subcategory_name, category_sort, subcategory_sort, active)
select category_name, subcategory_name, category_sort, subcategory_sort, true
from jsonb_to_recordset($taxonomy$[{"category_name":"Phone Cases","subcategory_name":"Apple iPhone","category_sort":10,"subcategory_sort":10},{"category_name":"Phone Cases","subcategory_name":"Samsung Galaxy","category_sort":10,"subcategory_sort":20},{"category_name":"Phone Cases","subcategory_name":"Google Pixel","category_sort":10,"subcategory_sort":30},{"category_name":"Phone Cases","subcategory_name":"Other & Universal","category_sort":10,"subcategory_sort":40}]$taxonomy$::jsonb) as x(
  category_name text, subcategory_name text, category_sort integer, subcategory_sort integer
)
on conflict (category_name, subcategory_name) do update
set category_sort = excluded.category_sort,
    subcategory_sort = excluded.subcategory_sort,
    active = true,
    updated_at = now();

create temporary table phone_case_profile_input on commit drop as
select * from jsonb_to_recordset($profiles$[{"code":"PHONE-IPHONE-12-12-PRO","display_name":"iPhone 12 / 12 Pro","source_category":"5. Phone Cases > Iphone 12/12Pro","notes":"Directional phone case fit profile for iPhone 12 / 12 Pro.","review_status":"approved"},{"code":"PHONE-SPECIAL-ORDER-CASE","display_name":"Model Recorded in Sale Note","source_category":"5. Phone Cases","notes":"Generic special-order case item. Staff must record the requested phone model and case type in the sale note.","review_status":"approved"}]$profiles$::jsonb) as x(
  code text, display_name text, source_category text, notes text, review_status text
);

create temporary table phone_case_device_input on commit drop as
select * from jsonb_to_recordset($devices$[{"code":"DEVICE-IPHONE-12-12-PRO","brand":"Apple","display_name":"iPhone 12 / 12 Pro","model_family":"iPhone 12 / 12","generation":"12 / 12 Pro","release_year":null},{"code":"DEVICE-SPECIAL-ORDER-CASE","brand":"Universal","display_name":"Model Recorded in Sale Note","model_family":"Model Recorded in Sale Note","generation":"","release_year":null}]$devices$::jsonb) as x(
  code text, brand text, display_name text, model_family text, generation text, release_year integer
);

create temporary table phone_case_mapping_input on commit drop as
select * from jsonb_to_recordset($mappings$[{"fit_profile_code":"PHONE-IPHONE-12-12-PRO","device_model_code":"DEVICE-IPHONE-12-12-PRO"},{"fit_profile_code":"PHONE-SPECIAL-ORDER-CASE","device_model_code":"DEVICE-SPECIAL-ORDER-CASE"}]$mappings$::jsonb) as x(
  fit_profile_code text, device_model_code text
);

create temporary table phone_case_group_input on commit drop as
select * from jsonb_to_recordset($groups$[{"code":"TM8-GRP-PC-IPHONE-12-12-PRO-6EC7F402C","slug":"tm8-grp-pc-iphone-12-12-pro-6ec7f402c","name":"Apple Logo Case for iPhone 12 / 12 Pro","product_family":"Fashion Case","fit_profile_code":"PHONE-IPHONE-12-12-PRO","main_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1642815891.jpg","pos_main_category":"Phone Cases","pos_subcategory":"Apple iPhone","pos_sort_order":1880,"status":"active","is_pos_visible":true,"is_visible":false},{"code":"TM8-GRP-PC-SPECIAL-ORDER-CASE-4D2B90CB1","slug":"tm8-grp-pc-special-order-case-4d2b90cb1","name":"Special Order Phone Case","product_family":"Special Order Case","fit_profile_code":"PHONE-SPECIAL-ORDER-CASE","main_image_url":"https://skylinemobile.com.au/cdn/shop/files/20210103162546.jpg?v=1778040935","pos_main_category":"Phone Cases","pos_subcategory":"Other & Universal","pos_sort_order":10099,"status":"active","is_pos_visible":true,"is_visible":false}]$groups$::jsonb) as x(
  code text, slug text, name text, product_family text, fit_profile_code text,
  main_image_url text, pos_main_category text, pos_subcategory text, pos_sort_order integer,
  status text, is_pos_visible boolean, is_visible boolean
);

create temporary table phone_case_product_input on commit drop as
select * from jsonb_to_recordset($products$[{"sku":"TM8-PC-8365","slug":"tm8-pc-8365","name":"Apple Logo Case for iPhone 12 / 12 Pro - Dark Green","brand":"OZTECHM8","model":"iPhone 12 / 12 Pro","short_description":"Apple Logo Case. Fits iPhone 12 / 12 Pro.","condition_label":"Brand New","compatibility":"iPhone 12 / 12 Pro","cost_price":5.5,"retail_price":49,"image_url":"https://oztechm8.com.au/assets/products/phone-cases/iphone-12-12-pro-apple-logo-dark-green.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2997000083653","product_group_code":"TM8-GRP-PC-IPHONE-12-12-PRO-6EC7F402C","variant_name":"Dark Green","variant_color":"Dark Green","source_system":"repairdesk_phone_cases","source_external_id":"8365","source_category_path":"5. Phone Cases > Iphone 12/12Pro","import_status":"active","pos_main_category":"Phone Cases","pos_subcategory":"Apple iPhone","pos_sort_order":1880,"source_metadata":{"original_name":"iPhone 12/12 Pro Apple Logo Case Dark Green","original_sku":"8089588","original_upc":"77","source_file":"products (case2).xlsx","source_stock":2,"proposed_stock":0,"inventory_assignment":"none","repairdesk_product_id":"","inventory_index_id":"","cost_rule":"Cost confirmed for this product in the phone case review workbook","source_cost":0,"variant_type":"colour","review_notes":"","image_source":"user_provided_asset"}},{"sku":"TM8-PC-7159","slug":"tm8-pc-7159","name":"Special Order Phone Case - Other Cases (Model Require)","brand":"OZTECHM8","model":"Model Recorded in Sale Note","short_description":"Other Cases (Model Require). Record the required phone model in the sale note.","condition_label":"Brand New","compatibility":"Phone model recorded in sale note","cost_price":5,"retail_price":45,"image_url":"https://skylinemobile.com.au/cdn/shop/files/20210103162546.jpg?v=1778040935","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2997000071599","product_group_code":"TM8-GRP-PC-SPECIAL-ORDER-CASE-4D2B90CB1","variant_name":"Other Cases (Model Require)","variant_color":null,"source_system":"repairdesk_phone_cases","source_external_id":"7159","source_category_path":"5. Phone Cases","import_status":"active","pos_main_category":"Phone Cases","pos_subcategory":"Other & Universal","pos_sort_order":10099,"source_metadata":{"original_name":"Other Cases (Model Require)","original_sku":"666389","original_upc":"77","source_file":"products (case2).xlsx","source_stock":283,"proposed_stock":0,"inventory_assignment":"none","repairdesk_product_id":"42456873","inventory_index_id":"50756660","cost_rule":"Normalized to the same case style cost","source_cost":0,"variant_type":"option","review_notes":"","image_source":"skyline_mobile"}}]$products$::jsonb) as x(
  sku text, slug text, name text, brand text, model text, short_description text,
  condition_label text, compatibility text, cost_price numeric, retail_price numeric,
  image_url text, stock_quantity integer, is_visible boolean, is_pos_visible boolean,
  upc text, product_group_code text, variant_name text, variant_color text,
  source_system text, source_external_id text, source_category_path text,
  import_status text, pos_main_category text, pos_subcategory text, pos_sort_order integer,
  source_metadata jsonb
);

do $$
begin
  if (select count(*) from phone_case_product_input) <> 2 then
    raise exception 'Expected 2 phone case products in this migration.';
  end if;
  if exists (
    select 1 from phone_case_product_input
    where cost_price <= 0 or retail_price <= 0 or cost_price >= retail_price or stock_quantity <> 0
       or is_visible or not is_pos_visible or import_status <> 'active'
       or coalesce(btrim(image_url), '') = ''
  ) then
    raise exception 'Phone case input contains an invalid price, stock, visibility, status, or image.';
  end if;
  if exists (select sku from phone_case_product_input group by sku having count(*) > 1)
     or exists (select upc from phone_case_product_input group by upc having count(*) > 1)
     or exists (select source_external_id from phone_case_product_input group by source_external_id having count(*) > 1) then
    raise exception 'Phone case input contains a duplicate SKU, barcode, or source item.';
  end if;
end $$;

insert into public.product_fit_profiles (code, display_name, source_category, notes, review_status)
select code, display_name, source_category, notes, review_status
from phone_case_profile_input
on conflict (code) do update
set display_name = excluded.display_name,
    source_category = excluded.source_category,
    notes = excluded.notes,
    review_status = excluded.review_status,
    updated_at = timezone('utc'::text, now());

insert into public.device_models (code, brand, display_name, model_family, generation, release_year)
select code, brand, display_name, model_family, generation, release_year
from phone_case_device_input
on conflict (code) do update
set brand = excluded.brand,
    display_name = excluded.display_name,
    model_family = excluded.model_family,
    generation = excluded.generation,
    release_year = excluded.release_year,
    updated_at = timezone('utc'::text, now());

insert into public.product_fit_profile_devices (fit_profile_id, device_model_id)
select profile.id, device.id
from phone_case_mapping_input input
join public.product_fit_profiles profile on profile.code = input.fit_profile_code
join public.device_models device on device.code = input.device_model_code
on conflict (fit_profile_id, device_model_id) do nothing;

insert into public.product_groups (
  code, slug, name, category_id, product_family, fit_profile_id, main_image_url,
  status, is_pos_visible, is_visible, pos_category_id, pos_sort_order
)
select
  input.code, input.slug, input.name, category.id, input.product_family, profile.id,
  input.main_image_url, input.status, input.is_pos_visible, input.is_visible,
  taxonomy.id, input.pos_sort_order
from phone_case_group_input input
join public.categories category on category.slug = 'phone-cases'
join public.product_fit_profiles profile on profile.code = input.fit_profile_code
join public.pos_category_taxonomy taxonomy
  on taxonomy.category_name = input.pos_main_category
 and taxonomy.subcategory_name = input.pos_subcategory
 and taxonomy.active
on conflict (code) do update
set slug = excluded.slug,
    name = excluded.name,
    category_id = excluded.category_id,
    product_family = excluded.product_family,
    fit_profile_id = excluded.fit_profile_id,
    main_image_url = excluded.main_image_url,
    status = excluded.status,
    is_pos_visible = excluded.is_pos_visible,
    is_visible = excluded.is_visible,
    pos_category_id = excluded.pos_category_id,
    pos_sort_order = excluded.pos_sort_order,
    updated_at = timezone('utc'::text, now());

insert into public.products (
  sku, slug, name, brand, model, category_id, pos_category_id, pos_sort_order,
  short_description, condition_label, compatibility, cost_price, retail_price,
  image_url, stock_quantity, is_visible, is_pos_visible, upc, product_group_id,
  variant_name, variant_color, source_system, source_external_id,
  source_category_path, import_status, source_metadata
)
select
  input.sku, input.slug, input.name, input.brand, input.model, category.id,
  taxonomy.id, input.pos_sort_order, input.short_description, input.condition_label,
  input.compatibility, input.cost_price, input.retail_price, input.image_url, 0,
  false, true, input.upc, product_group.id, input.variant_name, input.variant_color,
  input.source_system, input.source_external_id, input.source_category_path,
  input.import_status, input.source_metadata
from phone_case_product_input input
join public.categories category on category.slug = 'phone-cases'
join public.product_groups product_group on product_group.code = input.product_group_code
join public.pos_category_taxonomy taxonomy
  on taxonomy.category_name = input.pos_main_category
 and taxonomy.subcategory_name = input.pos_subcategory
 and taxonomy.active
on conflict (sku) do update
set name = excluded.name,
    brand = excluded.brand,
    model = excluded.model,
    category_id = excluded.category_id,
    pos_category_id = excluded.pos_category_id,
    pos_sort_order = excluded.pos_sort_order,
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
    import_status = excluded.import_status,
    is_visible = false,
    is_pos_visible = true,
    source_metadata = excluded.source_metadata,
    updated_at = timezone('utc'::text, now());



do $$
begin
  if (select count(*) from public.products where source_system = 'repairdesk_phone_cases' and import_status = 'active') <> 915 then
    raise exception 'Phone case database count does not match the import.';
  end if;
  if exists (
    select 1 from public.products product
    join phone_case_product_input input on input.sku = product.sku
    left join public.product_groups product_group on product_group.id = product.product_group_id
    left join public.pos_category_taxonomy taxonomy on taxonomy.id = product.pos_category_id
    where product.cost_price <= 0 or product.retail_price <= 0 or product.cost_price >= product.retail_price or product.stock_quantity <> 0
        or not product.is_pos_visible or product.import_status <> 'active'
        or product_group.id is null or taxonomy.category_name <> 'Phone Cases'
  ) then
    raise exception 'Imported phone case verification failed.';
  end if;
end $$;

commit;

select
  count(*) as imported_products,
  count(distinct product_group_id) as product_groups,
  count(*) filter (where is_pos_visible and import_status = 'active') as active_pos_products,
  count(*) filter (where stock_quantity <> 0) as products_with_nonzero_catalog_stock
from public.products
where source_system = 'repairdesk_phone_cases';
