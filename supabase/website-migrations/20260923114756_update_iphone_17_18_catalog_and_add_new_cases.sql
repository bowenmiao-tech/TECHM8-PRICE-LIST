begin;

-- The owner confirmed that iPhone 17 Pro cases also fit iPhone 18 Pro,
-- and iPhone 17 Pro Max cases also fit iPhone 18 Pro Max. Keep the existing
-- group codes, SKUs, stock, and sales history; only broaden their catalogue
-- labels and fit-profile mappings.

do $$
declare
  target_image_names constant text[] := array[
    'products/phone-cases/iphone-17-pro-18-pro/silicone-magsafe-hard-case-red.jpg',
    'products/phone-cases/iphone-17-pro-18-pro/silicone-magsafe-hard-case-blue.jpg',
    'products/phone-cases/iphone-duo/clear-magsafe-case.png',
    'products/phone-cases/samsung-galaxy-z-fold-8-ultra/clear-magsafe-case.png'
  ];
  target_group_codes constant text[] := array[
    'TM8-GRP-PC-IPHONE-DUO-41FAF4CDA',
    'TM8-GRP-PC-SAMSUNG-Z-FOLD8-ULTRA-41FAF4CDA'
  ];
  target_group_slugs constant text[] := array[
    'tm8-grp-pc-iphone-duo-41faf4cda',
    'tm8-grp-pc-samsung-z-fold8-ultra-41faf4cda'
  ];
  target_skus constant text[] := array[
    'TM8-PC-IP17P18P-SMH-BLUE',
    'TM8-PC-IP17P18P-SMH-RED',
    'TM8-PC-IP17PM18PM-SMH-BLUE',
    'TM8-PC-IP17PM18PM-SMH-RED',
    'TM8-PC-IPHONE-DUO-MAGSAFE-CLEAR',
    'TM8-PC-ZFOLD8-ULTRA-MAGSAFE-CLEAR'
  ];
begin
  if not exists (
    select 1 from public.categories where slug = 'phone-cases'
  ) or not exists (
    select 1
    from public.pos_category_taxonomy
    where category_name = 'Phone Cases'
      and subcategory_name = 'Apple iPhone'
      and active
  ) or not exists (
    select 1
    from public.pos_category_taxonomy
    where category_name = 'Phone Cases'
      and subcategory_name = 'Samsung Galaxy'
      and active
  ) then
    raise exception 'Required phone-case category or POS taxonomy is missing.';
  end if;

  if not exists (
    select 1 from public.product_fit_profiles where code = 'PHONE-IPHONE-17-PRO'
  ) or not exists (
    select 1 from public.product_fit_profiles where code = 'PHONE-IPHONE-17-PRO-MAX'
  ) then
    raise exception 'Existing iPhone 17 Pro fit profiles are missing.';
  end if;

  if (
    select count(*)
    from public.products product
    join public.product_groups product_group on product_group.id = product.product_group_id
    join public.product_fit_profiles profile on profile.id = product_group.fit_profile_id
    where profile.code in ('PHONE-IPHONE-17-PRO', 'PHONE-IPHONE-17-PRO-MAX')
  ) not in (83, 87) then
    raise exception 'Expected 83 existing products, or 87 products after a repeat run, across the two iPhone Pro fit profiles.';
  end if;

  if (
    select count(*)
    from storage.objects
    where bucket_id = 'product-images'
      and name = any(target_image_names)
  ) <> 4 then
    raise exception 'One or more owner-supplied product images are missing from product-images storage.';
  end if;

  if exists (
    select 1
    from public.product_groups product_group
    where product_group.code = any(target_group_codes)
      and product_group.product_family <> 'MagSafe Case'
  ) or exists (
    select 1
    from public.product_groups product_group
    where product_group.slug = any(target_group_slugs)
      and product_group.code <> all(target_group_codes)
  ) then
    raise exception 'A requested product-group code or slug belongs to an unrelated group.';
  end if;

  if exists (
    select 1
    from public.products product
    where product.sku = any(target_skus)
      and product.source_system is distinct from 'techm8_manual_catalog'
  ) then
    raise exception 'A requested SKU belongs to another product source.';
  end if;
end
$$;

-- Freeze the commercial fields of every pre-existing iPhone Pro product. The
-- migration is allowed to broaden catalogue wording only; it must not change
-- identity, inventory, price, or group membership.
create temporary table iphone_pro_catalog_snapshot on commit drop as
select
  product.id as product_id,
  product.sku,
  product.slug,
  product.stock_quantity,
  product.cost_price,
  product.retail_price,
  product.product_group_id,
  profile.code as profile_code
from public.products product
join public.product_groups product_group on product_group.id = product.product_group_id
join public.product_fit_profiles profile on profile.id = product_group.fit_profile_id
where profile.code in ('PHONE-IPHONE-17-PRO', 'PHONE-IPHONE-17-PRO-MAX')
  and product.sku not in (
    'TM8-PC-IP17P18P-SMH-BLUE',
    'TM8-PC-IP17P18P-SMH-RED',
    'TM8-PC-IP17PM18PM-SMH-BLUE',
    'TM8-PC-IP17PM18PM-SMH-RED'
  );

do $$
begin
  if (select count(*) from iphone_pro_catalog_snapshot) <> 83 then
    raise exception 'The pre-existing iPhone Pro catalogue no longer contains the expected 83 products.';
  end if;
end
$$;

insert into public.device_models (
  code,
  brand,
  display_name,
  model_family,
  generation,
  release_year
)
values
  ('DEVICE-IPHONE-18-PRO', 'Apple', 'iPhone 18 Pro', 'iPhone 18', '18', null),
  ('DEVICE-IPHONE-18-PRO-MAX', 'Apple', 'iPhone 18 Pro Max', 'iPhone 18', '18', null),
  ('DEVICE-IPHONE-DUO', 'Apple', 'iPhone Duo', 'iPhone Duo', 'Duo', null),
  ('DEVICE-SAMSUNG-Z-FOLD8-ULTRA', 'Samsung', 'Samsung Galaxy Z Fold 8 Ultra', 'Samsung Galaxy Z Fold 8', '8 Ultra', null)
on conflict (code) do update
set brand = excluded.brand,
    display_name = excluded.display_name,
    model_family = excluded.model_family,
    generation = excluded.generation,
    release_year = excluded.release_year,
    updated_at = timezone('utc'::text, now());

update public.product_fit_profiles
set display_name = 'iPhone 17 Pro / 18 Pro',
    notes = concat_ws(' ', nullif(notes, ''), 'iPhone 18 Pro compatibility confirmed by the catalogue owner on 2026-09-23.'),
    review_status = 'approved',
    updated_at = timezone('utc'::text, now())
where code = 'PHONE-IPHONE-17-PRO'
  and display_name <> 'iPhone 17 Pro / 18 Pro';

update public.product_fit_profiles
set display_name = 'iPhone 17 Pro Max / 18 Pro Max',
    notes = concat_ws(' ', nullif(notes, ''), 'iPhone 18 Pro Max compatibility confirmed by the catalogue owner on 2026-09-23.'),
    review_status = 'approved',
    updated_at = timezone('utc'::text, now())
where code = 'PHONE-IPHONE-17-PRO-MAX'
  and display_name <> 'iPhone 17 Pro Max / 18 Pro Max';

insert into public.product_fit_profiles (
  code,
  display_name,
  source_category,
  notes,
  review_status
)
values
  (
    'PHONE-IPHONE-DUO',
    'iPhone Duo',
    '5. Phone Cases > iPhone Duo',
    'Owner-requested phone-case model added on 2026-09-23.',
    'approved'
  ),
  (
    'PHONE-SAMSUNG-Z-FOLD8-ULTRA',
    'Samsung Galaxy Z Fold 8 Ultra',
    '5. Phone Cases > Samsung Z Fold 8 Ultra',
    'Owner-requested phone-case model added on 2026-09-23.',
    'approved'
  )
on conflict (code) do update
set display_name = excluded.display_name,
    source_category = excluded.source_category,
    notes = excluded.notes,
    review_status = 'approved',
    updated_at = timezone('utc'::text, now());

insert into public.product_fit_profile_devices (fit_profile_id, device_model_id)
select profile.id, device.id
from (
  values
    ('PHONE-IPHONE-17-PRO', 'DEVICE-IPHONE-18-PRO'),
    ('PHONE-IPHONE-17-PRO-MAX', 'DEVICE-IPHONE-18-PRO-MAX'),
    ('PHONE-IPHONE-DUO', 'DEVICE-IPHONE-DUO'),
    ('PHONE-SAMSUNG-Z-FOLD8-ULTRA', 'DEVICE-SAMSUNG-Z-FOLD8-ULTRA')
) as input(profile_code, device_code)
join public.product_fit_profiles profile on profile.code = input.profile_code
join public.device_models device on device.code = input.device_code
on conflict (fit_profile_id, device_model_id) do nothing;

update public.product_groups product_group
set name = replace(product_group.name, 'iPhone 17 Pro Max', 'iPhone 17 Pro Max / 18 Pro Max'),
    updated_at = timezone('utc'::text, now())
from public.product_fit_profiles profile
where profile.id = product_group.fit_profile_id
  and profile.code = 'PHONE-IPHONE-17-PRO-MAX'
  and product_group.name not like '%18 Pro Max%';

update public.product_groups product_group
set name = replace(product_group.name, 'iPhone 17 Pro', 'iPhone 17 Pro / 18 Pro'),
    updated_at = timezone('utc'::text, now())
from public.product_fit_profiles profile
where profile.id = product_group.fit_profile_id
  and profile.code = 'PHONE-IPHONE-17-PRO'
  and product_group.name not like '%18 Pro%';

update public.products product
set name = case
      when product.name like '%18 Pro Max%' then product.name
      else replace(product.name, 'iPhone 17 Pro Max', 'iPhone 17 Pro Max / 18 Pro Max')
    end,
    model = 'iPhone 17 Pro Max / 18 Pro Max',
    compatibility = 'iPhone 17 Pro Max / 18 Pro Max',
    short_description = case
      when product.short_description is null or product.short_description like '%18 Pro Max%' then product.short_description
      else replace(product.short_description, 'iPhone 17 Pro Max', 'iPhone 17 Pro Max / 18 Pro Max')
    end,
    description = case
      when product.description is null or product.description like '%18 Pro Max%' then product.description
      else replace(product.description, 'iPhone 17 Pro Max', 'iPhone 17 Pro Max / 18 Pro Max')
    end,
    seo_title = case
      when product.seo_title is null or product.seo_title like '%18 Pro Max%' then product.seo_title
      else replace(product.seo_title, 'iPhone 17 Pro Max', 'iPhone 17 Pro Max / 18 Pro Max')
    end,
    seo_description = case
      when product.seo_description is null or product.seo_description like '%18 Pro Max%' then product.seo_description
      else replace(product.seo_description, 'iPhone 17 Pro Max', 'iPhone 17 Pro Max / 18 Pro Max')
    end,
    source_metadata = product.source_metadata || jsonb_build_object(
      'catalog_compatibility_update', 'iPhone 17 Pro Max / 18 Pro Max',
      'catalog_compatibility_confirmed_at', '2026-09-23'
    ),
    updated_at = timezone('utc'::text, now())
from public.product_groups product_group
join public.product_fit_profiles profile on profile.id = product_group.fit_profile_id
where product.product_group_id = product_group.id
  and profile.code = 'PHONE-IPHONE-17-PRO-MAX';

update public.products product
set name = case
      when product.name like '%18 Pro%' then product.name
      else replace(product.name, 'iPhone 17 Pro', 'iPhone 17 Pro / 18 Pro')
    end,
    model = 'iPhone 17 Pro / 18 Pro',
    compatibility = 'iPhone 17 Pro / 18 Pro',
    short_description = case
      when product.short_description is null or product.short_description like '%18 Pro%' then product.short_description
      else replace(product.short_description, 'iPhone 17 Pro', 'iPhone 17 Pro / 18 Pro')
    end,
    description = case
      when product.description is null or product.description like '%18 Pro%' then product.description
      else replace(product.description, 'iPhone 17 Pro', 'iPhone 17 Pro / 18 Pro')
    end,
    seo_title = case
      when product.seo_title is null or product.seo_title like '%18 Pro%' then product.seo_title
      else replace(product.seo_title, 'iPhone 17 Pro', 'iPhone 17 Pro / 18 Pro')
    end,
    seo_description = case
      when product.seo_description is null or product.seo_description like '%18 Pro%' then product.seo_description
      else replace(product.seo_description, 'iPhone 17 Pro', 'iPhone 17 Pro / 18 Pro')
    end,
    source_metadata = product.source_metadata || jsonb_build_object(
      'catalog_compatibility_update', 'iPhone 17 Pro / 18 Pro',
      'catalog_compatibility_confirmed_at', '2026-09-23'
    ),
    updated_at = timezone('utc'::text, now())
from public.product_groups product_group
join public.product_fit_profiles profile on profile.id = product_group.fit_profile_id
where product.product_group_id = product_group.id
  and profile.code = 'PHONE-IPHONE-17-PRO';

insert into public.product_groups (
  code,
  slug,
  name,
  category_id,
  product_family,
  fit_profile_id,
  main_image_url,
  status,
  is_pos_visible,
  is_visible,
  pos_category_id,
  pos_sort_order
)
select
  input.code,
  input.slug,
  input.name,
  category.id,
  'MagSafe Case',
  profile.id,
  input.image_url,
  'active',
  true,
  false,
  taxonomy.id,
  input.pos_sort_order
from (
  values
    (
      'TM8-GRP-PC-IPHONE-DUO-41FAF4CDA',
      'tm8-grp-pc-iphone-duo-41faf4cda',
      'MagSafe Case for iPhone Duo',
      'PHONE-IPHONE-DUO',
      'Apple iPhone',
      'https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/product-images/products/phone-cases/iphone-duo/clear-magsafe-case.png',
      4110
    ),
    (
      'TM8-GRP-PC-SAMSUNG-Z-FOLD8-ULTRA-41FAF4CDA',
      'tm8-grp-pc-samsung-z-fold8-ultra-41faf4cda',
      'MagSafe Case for Samsung Galaxy Z Fold 8 Ultra',
      'PHONE-SAMSUNG-Z-FOLD8-ULTRA',
      'Samsung Galaxy',
      'https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/product-images/products/phone-cases/samsung-galaxy-z-fold-8-ultra/clear-magsafe-case.png',
      9020
    )
) as input(code, slug, name, fit_profile_code, subcategory_name, image_url, pos_sort_order)
join public.categories category on category.slug = 'phone-cases'
join public.product_fit_profiles profile on profile.code = input.fit_profile_code
join public.pos_category_taxonomy taxonomy
  on taxonomy.category_name = 'Phone Cases'
 and taxonomy.subcategory_name = input.subcategory_name
 and taxonomy.active
on conflict (code) do update
set slug = excluded.slug,
    name = excluded.name,
    category_id = excluded.category_id,
    product_family = excluded.product_family,
    fit_profile_id = excluded.fit_profile_id,
    main_image_url = excluded.main_image_url,
    status = 'active',
    is_pos_visible = true,
    is_visible = false,
    pos_category_id = excluded.pos_category_id,
    pos_sort_order = excluded.pos_sort_order,
    updated_at = timezone('utc'::text, now())
where public.product_groups.product_family = 'MagSafe Case';

create temporary table requested_phone_case_input on commit drop as
select *
from jsonb_to_recordset($cases$[
  {
    "sku": "TM8-PC-IP17P18P-SMH-BLUE",
    "slug": "tm8-pc-ip17p18p-smh-blue",
    "name": "Silicone MagSafe Hard Case for iPhone 17 Pro / 18 Pro - Blue",
    "model": "iPhone 17 Pro / 18 Pro",
    "short_description": "Silicone MagSafe Hard Case. Fits iPhone 17 Pro / 18 Pro.",
    "compatibility": "iPhone 17 Pro / 18 Pro",
    "cost_price": 4,
    "retail_price": 49.95,
    "image_url": "https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/product-images/products/phone-cases/iphone-17-pro-18-pro/silicone-magsafe-hard-case-blue.jpg",
    "variant_name": "Blue",
    "variant_color": "Blue",
    "source_external_id": "20260923-silicone-magsafe-hard-iphone-17-pro-18-pro-blue",
    "source_category_path": "5. Phone Cases > iPhone 17 Pro / 18 Pro",
    "product_group_code": "TM8-GRP-PC-IPHONE-17-PRO-4CD285521",
    "pos_sort_order": 3910,
    "source_metadata": {"catalog_action":"owner_requested_colour","requested_at":"2026-09-23","image_source":"owner_supplied","inventory_assignment":"none","proposed_stock":0}
  },
  {
    "sku": "TM8-PC-IP17P18P-SMH-RED",
    "slug": "tm8-pc-ip17p18p-smh-red",
    "name": "Silicone MagSafe Hard Case for iPhone 17 Pro / 18 Pro - Red",
    "model": "iPhone 17 Pro / 18 Pro",
    "short_description": "Silicone MagSafe Hard Case. Fits iPhone 17 Pro / 18 Pro.",
    "compatibility": "iPhone 17 Pro / 18 Pro",
    "cost_price": 4,
    "retail_price": 49.95,
    "image_url": "https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/product-images/products/phone-cases/iphone-17-pro-18-pro/silicone-magsafe-hard-case-red.jpg",
    "variant_name": "Red",
    "variant_color": "Red",
    "source_external_id": "20260923-silicone-magsafe-hard-iphone-17-pro-18-pro-red",
    "source_category_path": "5. Phone Cases > iPhone 17 Pro / 18 Pro",
    "product_group_code": "TM8-GRP-PC-IPHONE-17-PRO-4CD285521",
    "pos_sort_order": 3910,
    "source_metadata": {"catalog_action":"owner_requested_colour","requested_at":"2026-09-23","image_source":"owner_supplied","inventory_assignment":"none","proposed_stock":0}
  },
  {
    "sku": "TM8-PC-IP17PM18PM-SMH-BLUE",
    "slug": "tm8-pc-ip17pm18pm-smh-blue",
    "name": "Silicone MagSafe Hard Case for iPhone 17 Pro Max / 18 Pro Max - Blue",
    "model": "iPhone 17 Pro Max / 18 Pro Max",
    "short_description": "Silicone MagSafe Hard Case. Fits iPhone 17 Pro Max / 18 Pro Max.",
    "compatibility": "iPhone 17 Pro Max / 18 Pro Max",
    "cost_price": 4,
    "retail_price": 49.95,
    "image_url": "https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/product-images/products/phone-cases/iphone-17-pro-18-pro/silicone-magsafe-hard-case-blue.jpg",
    "variant_name": "Blue",
    "variant_color": "Blue",
    "source_external_id": "20260923-silicone-magsafe-hard-iphone-17-pro-max-18-pro-max-blue",
    "source_category_path": "5. Phone Cases > iPhone 17 Pro Max / 18 Pro Max",
    "product_group_code": "TM8-GRP-PC-IPHONE-17-PRO-MAX-4CD285521",
    "pos_sort_order": 4010,
    "source_metadata": {"catalog_action":"owner_requested_colour","requested_at":"2026-09-23","image_source":"owner_supplied","inventory_assignment":"none","proposed_stock":0}
  },
  {
    "sku": "TM8-PC-IP17PM18PM-SMH-RED",
    "slug": "tm8-pc-ip17pm18pm-smh-red",
    "name": "Silicone MagSafe Hard Case for iPhone 17 Pro Max / 18 Pro Max - Red",
    "model": "iPhone 17 Pro Max / 18 Pro Max",
    "short_description": "Silicone MagSafe Hard Case. Fits iPhone 17 Pro Max / 18 Pro Max.",
    "compatibility": "iPhone 17 Pro Max / 18 Pro Max",
    "cost_price": 4,
    "retail_price": 49.95,
    "image_url": "https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/product-images/products/phone-cases/iphone-17-pro-18-pro/silicone-magsafe-hard-case-red.jpg",
    "variant_name": "Red",
    "variant_color": "Red",
    "source_external_id": "20260923-silicone-magsafe-hard-iphone-17-pro-max-18-pro-max-red",
    "source_category_path": "5. Phone Cases > iPhone 17 Pro Max / 18 Pro Max",
    "product_group_code": "TM8-GRP-PC-IPHONE-17-PRO-MAX-4CD285521",
    "pos_sort_order": 4010,
    "source_metadata": {"catalog_action":"owner_requested_colour","requested_at":"2026-09-23","image_source":"owner_supplied","inventory_assignment":"none","proposed_stock":0}
  },
  {
    "sku": "TM8-PC-IPHONE-DUO-MAGSAFE-CLEAR",
    "slug": "tm8-pc-iphone-duo-magsafe-clear",
    "name": "MagSafe Case for iPhone Duo - Clear",
    "model": "iPhone Duo",
    "short_description": "Clear MagSafe Case. Fits iPhone Duo.",
    "compatibility": "iPhone Duo",
    "cost_price": 3,
    "retail_price": 45,
    "image_url": "https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/product-images/products/phone-cases/iphone-duo/clear-magsafe-case.png",
    "variant_name": "Clear",
    "variant_color": "Clear",
    "source_external_id": "20260923-iphone-duo-magsafe-clear",
    "source_category_path": "5. Phone Cases > iPhone Duo",
    "product_group_code": "TM8-GRP-PC-IPHONE-DUO-41FAF4CDA",
    "pos_sort_order": 4110,
    "source_metadata": {"catalog_action":"owner_requested_new_model_and_case","requested_at":"2026-09-23","image_source":"owner_supplied","price_reference_sku":"TM8-PC-10790","cost_reference_sku":"TM8-PC-10790","inventory_assignment":"none","proposed_stock":0}
  },
  {
    "sku": "TM8-PC-ZFOLD8-ULTRA-MAGSAFE-CLEAR",
    "slug": "tm8-pc-zfold8-ultra-magsafe-clear",
    "name": "MagSafe Case for Samsung Galaxy Z Fold 8 Ultra - Clear",
    "model": "Samsung Galaxy Z Fold 8 Ultra",
    "short_description": "Clear MagSafe Case. Fits Samsung Galaxy Z Fold 8 Ultra.",
    "compatibility": "Samsung Galaxy Z Fold 8 Ultra",
    "cost_price": 10,
    "retail_price": 49.95,
    "image_url": "https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/product-images/products/phone-cases/samsung-galaxy-z-fold-8-ultra/clear-magsafe-case.png",
    "variant_name": "Clear",
    "variant_color": "Clear",
    "source_external_id": "20260923-zfold8-ultra-magsafe-clear",
    "source_category_path": "5. Phone Cases > Samsung Z Fold 8 Ultra",
    "product_group_code": "TM8-GRP-PC-SAMSUNG-Z-FOLD8-ULTRA-41FAF4CDA",
    "pos_sort_order": 9020,
    "source_metadata": {"catalog_action":"owner_requested_new_model_and_case","requested_at":"2026-09-23","image_source":"owner_supplied","price_reference_sku":"TM8-PC-11283","cost_reference_sku":"TM8-PC-11283","inventory_assignment":"none","proposed_stock":0}
  }
]$cases$::jsonb) as input(
  sku text,
  slug text,
  name text,
  model text,
  short_description text,
  compatibility text,
  cost_price numeric,
  retail_price numeric,
  image_url text,
  variant_name text,
  variant_color text,
  source_external_id text,
  source_category_path text,
  product_group_code text,
  pos_sort_order integer,
  source_metadata jsonb
);

do $$
begin
  if (select count(*) from requested_phone_case_input) <> 6 then
    raise exception 'Expected six requested phone-case products.';
  end if;

  if exists (
    select 1
    from requested_phone_case_input input
    where input.cost_price <= 0
       or input.retail_price <= 0
       or coalesce(btrim(input.image_url), '') = ''
       or coalesce(btrim(input.variant_color), '') = ''
  ) then
    raise exception 'Requested phone-case input contains an invalid price, image, or colour.';
  end if;

  if exists (
    select 1
    from requested_phone_case_input input
    join public.products existing
      on existing.source_system = 'techm8_manual_catalog'
     and existing.source_external_id = input.source_external_id
    where existing.sku <> input.sku
  ) then
    raise exception 'A manual source identity is already assigned to another SKU.';
  end if;

  if exists (
    select 1
    from requested_phone_case_input input
    join public.products existing on existing.slug = input.slug
    where existing.sku <> input.sku
  ) then
    raise exception 'A requested product slug is already assigned to another SKU.';
  end if;
end
$$;

insert into public.products (
  sku,
  slug,
  name,
  brand,
  model,
  category_id,
  pos_category_id,
  short_description,
  condition_label,
  compatibility,
  cost_price,
  retail_price,
  image_url,
  stock_quantity,
  is_visible,
  is_pos_visible,
  product_group_id,
  variant_name,
  variant_color,
  source_system,
  source_external_id,
  source_category_path,
  import_status,
  source_metadata,
  pos_sort_order
)
select
  input.sku,
  input.slug,
  input.name,
  'OZTECHM8',
  input.model,
  category.id,
  product_group.pos_category_id,
  input.short_description,
  'Brand New',
  input.compatibility,
  input.cost_price,
  input.retail_price,
  input.image_url,
  0,
  false,
  true,
  product_group.id,
  input.variant_name,
  input.variant_color,
  'techm8_manual_catalog',
  input.source_external_id,
  input.source_category_path,
  'active',
  input.source_metadata,
  input.pos_sort_order
from requested_phone_case_input input
join public.categories category on category.slug = 'phone-cases'
join public.product_groups product_group on product_group.code = input.product_group_code
on conflict (sku) do update
set slug = excluded.slug,
    name = excluded.name,
    brand = excluded.brand,
    model = excluded.model,
    category_id = excluded.category_id,
    pos_category_id = excluded.pos_category_id,
    short_description = excluded.short_description,
    condition_label = excluded.condition_label,
    compatibility = excluded.compatibility,
    cost_price = excluded.cost_price,
    retail_price = excluded.retail_price,
    image_url = excluded.image_url,
    is_visible = false,
    is_pos_visible = true,
    product_group_id = excluded.product_group_id,
    variant_name = excluded.variant_name,
    variant_color = excluded.variant_color,
    source_category_path = excluded.source_category_path,
    import_status = 'active',
    source_metadata = excluded.source_metadata,
    pos_sort_order = excluded.pos_sort_order,
    updated_at = timezone('utc'::text, now())
where public.products.source_system = excluded.source_system
  and public.products.source_external_id = excluded.source_external_id;

do $$
declare
  pro_profile_id bigint;
  pro_max_profile_id bigint;
begin
  select id into strict pro_profile_id
  from public.product_fit_profiles
  where code = 'PHONE-IPHONE-17-PRO';

  select id into strict pro_max_profile_id
  from public.product_fit_profiles
  where code = 'PHONE-IPHONE-17-PRO-MAX';

  if (
    select count(*)
    from public.products product
    join public.product_groups product_group on product_group.id = product.product_group_id
    where product_group.fit_profile_id = pro_profile_id
      and product.model = 'iPhone 17 Pro / 18 Pro'
      and product.compatibility = 'iPhone 17 Pro / 18 Pro'
      and product.name like '%iPhone 17 Pro / 18 Pro%'
  ) <> (
    select count(*) + 2
    from iphone_pro_catalog_snapshot
    where profile_code = 'PHONE-IPHONE-17-PRO'
  ) then
    raise exception 'iPhone 17 Pro / 18 Pro product-name or compatibility update failed.';
  end if;

  if (
    select count(*)
    from public.products product
    join public.product_groups product_group on product_group.id = product.product_group_id
    where product_group.fit_profile_id = pro_max_profile_id
      and product.model = 'iPhone 17 Pro Max / 18 Pro Max'
      and product.compatibility = 'iPhone 17 Pro Max / 18 Pro Max'
      and product.name like '%iPhone 17 Pro Max / 18 Pro Max%'
  ) <> (
    select count(*) + 2
    from iphone_pro_catalog_snapshot
    where profile_code = 'PHONE-IPHONE-17-PRO-MAX'
  ) then
    raise exception 'iPhone 17 Pro Max / 18 Pro Max product-name or compatibility update failed.';
  end if;

  if exists (
    select 1
    from public.product_groups
    where fit_profile_id = pro_profile_id
      and name not like '%iPhone 17 Pro / 18 Pro%'
  ) or exists (
    select 1
    from public.product_groups
    where fit_profile_id = pro_max_profile_id
      and name not like '%iPhone 17 Pro Max / 18 Pro Max%'
  ) then
    raise exception 'One or more iPhone Pro product-group names were not updated.';
  end if;

  if exists (
    select 1
    from iphone_pro_catalog_snapshot snapshot
    left join public.products product on product.id = snapshot.product_id
    where product.id is null
       or product.sku is distinct from snapshot.sku
       or product.slug is distinct from snapshot.slug
       or product.stock_quantity is distinct from snapshot.stock_quantity
       or product.cost_price is distinct from snapshot.cost_price
       or product.retail_price is distinct from snapshot.retail_price
       or product.product_group_id is distinct from snapshot.product_group_id
  ) then
    raise exception 'A pre-existing product identity, inventory, price, or group assignment changed unexpectedly.';
  end if;

  if (
    select count(*)
    from public.product_fit_profile_devices mapping
    join public.device_models device on device.id = mapping.device_model_id
    where mapping.fit_profile_id = pro_profile_id
      and device.code in ('DEVICE-IPHONE-17-PRO', 'DEVICE-IPHONE-18-PRO')
  ) <> 2 or (
    select count(*)
    from public.product_fit_profile_devices mapping
    join public.device_models device on device.id = mapping.device_model_id
    where mapping.fit_profile_id = pro_max_profile_id
      and device.code in ('DEVICE-IPHONE-17-PRO-MAX', 'DEVICE-IPHONE-18-PRO-MAX')
  ) <> 2 then
    raise exception 'iPhone 17/18 fit-profile device mappings are incomplete.';
  end if;

  if (
    select count(*)
    from public.products product
    join public.product_groups product_group on product_group.id = product.product_group_id
    where product.sku in (
      'TM8-PC-IP17P18P-SMH-BLUE',
      'TM8-PC-IP17P18P-SMH-RED',
      'TM8-PC-IP17PM18PM-SMH-BLUE',
      'TM8-PC-IP17PM18PM-SMH-RED',
      'TM8-PC-IPHONE-DUO-MAGSAFE-CLEAR',
      'TM8-PC-ZFOLD8-ULTRA-MAGSAFE-CLEAR'
    )
      and product.stock_quantity = 0
      and product.cost_price > 0
      and product.retail_price > 0
      and product.import_status = 'active'
      and product.is_pos_visible
      and not product.is_visible
      and coalesce(btrim(product.image_url), '') <> ''
      and product_group.status = 'active'
      and product_group.is_pos_visible
      and not product_group.is_visible
  ) <> 6 then
    raise exception 'Requested phone-case product validation failed.';
  end if;

  if (
    select count(*)
    from public.product_fit_profiles profile
    join public.product_fit_profile_devices mapping on mapping.fit_profile_id = profile.id
    join public.device_models device on device.id = mapping.device_model_id
    where (profile.code = 'PHONE-IPHONE-DUO' and device.code = 'DEVICE-IPHONE-DUO')
       or (profile.code = 'PHONE-SAMSUNG-Z-FOLD8-ULTRA' and device.code = 'DEVICE-SAMSUNG-Z-FOLD8-ULTRA')
  ) <> 2 then
    raise exception 'New phone-model fit profiles are incomplete.';
  end if;
end
$$;

commit;
