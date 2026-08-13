begin;

insert into public.pos_category_taxonomy (
  category_name, subcategory_name, category_sort, subcategory_sort, active
)
values ('Mounts & Holders', 'Wallets, Card Holders & Grips', 50, 40, true)
on conflict (category_name, subcategory_name) do update
set active = true,
    updated_at = timezone('utc'::text, now());

insert into public.product_groups (
  code, slug, name, category_id, product_family, main_image_url,
  status, is_pos_visible, is_visible, pos_category_id
)
select
  'TM8-GRP-MISC-ADHESIVE-CARD-HOLDER',
  'tm8-grp-misc-adhesive-card-holder',
  'Adhesive Silicone Card Holder',
  category.id,
  'phone_accessory',
  'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663820866.jpg',
  'active',
  true,
  false,
  taxonomy.id
from public.categories category
join public.pos_category_taxonomy taxonomy
  on taxonomy.category_name = 'Mounts & Holders'
 and taxonomy.subcategory_name = 'Wallets, Card Holders & Grips'
 and taxonomy.active
where category.slug = 'holder-car-play-charger'
on conflict (code) do update
set slug = excluded.slug,
    name = excluded.name,
    category_id = excluded.category_id,
    main_image_url = excluded.main_image_url,
    status = 'active',
    is_pos_visible = true,
    is_visible = false,
    pos_category_id = excluded.pos_category_id,
    updated_at = timezone('utc'::text, now())
where public.product_groups.product_family = 'phone_accessory';

create temporary table missing_card_holder_color_input (
  sku text primary key,
  slug text not null,
  name text not null,
  source_external_id text unique not null,
  upc text unique not null,
  variant_color text not null,
  image_url text not null,
  source_stock integer not null
) on commit drop;

insert into missing_card_holder_color_input (
  sku, slug, name, source_external_id, upc, variant_color, image_url, source_stock
)
values
  ('7145328', 'repairdesk-misc-7145-adhesive-silicone-card-holder-blue',
   'Adhesive Silicone Card Holder - Blue', '7145', '2996000071455', 'Blue',
   'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663820692.jpg', 0),
  ('7144327', 'repairdesk-misc-7144-adhesive-silicone-card-holder-pink',
   'Adhesive Silicone Card Holder - Pink', '7144', '2996000071448', 'Pink',
   'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663820625.jpg', -1);

do $$
begin
  if (select count(*) from missing_card_holder_color_input) <> 2 then
    raise exception 'Expected two missing card-holder colours.';
  end if;

  if exists (
    select 1
    from missing_card_holder_color_input input
    join public.products existing
      on existing.sku = input.sku
      or existing.upc = input.upc
      or (existing.source_system = 'repairdesk_misc_accessories'
          and existing.source_external_id = input.source_external_id)
    where existing.source_system is distinct from 'repairdesk_misc_accessories'
       or existing.source_external_id is distinct from input.source_external_id
       or existing.sku is distinct from input.sku
  ) then
    raise exception 'A missing card-holder identity belongs to another product.';
  end if;

  if not exists (
    select 1
    from public.product_groups
    where code = 'TM8-GRP-MISC-ADHESIVE-CARD-HOLDER'
      and product_family = 'phone_accessory'
  ) then
    raise exception 'The adhesive card-holder product group is unavailable.';
  end if;
end
$$;

insert into public.products (
  sku, slug, name, brand, model, category_id, pos_category_id,
  short_description, condition_label, compatibility,
  cost_price, retail_price, image_url, stock_quantity,
  is_visible, is_pos_visible, upc,
  product_group_id, variant_name, variant_color,
  source_system, source_external_id, source_category_path,
  import_status, source_metadata
)
select
  input.sku,
  input.slug,
  input.name,
  'OZTECHM8',
  'Adhesive Silicone Card Holder',
  category.id,
  taxonomy.id,
  'Wallets, Card Holders & Grips',
  'Brand New',
  null,
  2,
  10,
  input.image_url,
  0,
  false,
  true,
  input.upc,
  product_group.id,
  input.variant_color,
  input.variant_color,
  'repairdesk_misc_accessories',
  input.source_external_id,
  'Card Holder & Pop Scoket > Sticker Card Holder',
  'active',
  jsonb_build_object(
    'original_name', 'Silicone Card Holder ' || input.variant_color,
    'original_sku', input.sku,
    'original_upc', '77',
    'source_stock', input.source_stock,
    'proposed_stock', 0,
    'inventory_assignment', 'none',
    'owner_confirmed_cost', 2,
    'owner_confirmed_retail', 10,
    'owner_confirmed_at', '2026-08-14',
    'image_source', 'repairdesk_inventory',
    'pos_main_category', 'Mounts & Holders',
    'pos_subcategory', 'Wallets, Card Holders & Grips'
  )
from missing_card_holder_color_input input
join public.categories category on category.slug = 'holder-car-play-charger'
join public.pos_category_taxonomy taxonomy
  on taxonomy.category_name = 'Mounts & Holders'
 and taxonomy.subcategory_name = 'Wallets, Card Holders & Grips'
 and taxonomy.active
join public.product_groups product_group
  on product_group.code = 'TM8-GRP-MISC-ADHESIVE-CARD-HOLDER'
 and product_group.product_family = 'phone_accessory'
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
    stock_quantity = 0,
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
where public.products.source_system = excluded.source_system
  and public.products.source_external_id = excluded.source_external_id;

do $$
begin
  if (
    select count(*)
    from public.products product
    join public.product_groups product_group on product_group.id = product.product_group_id
    join public.pos_category_taxonomy taxonomy on taxonomy.id = product.pos_category_id
    where product.source_system = 'repairdesk_misc_accessories'
      and product.source_external_id in ('7144', '7145')
      and product.cost_price = 2
      and product.retail_price = 10
      and product.stock_quantity = 0
      and product.is_pos_visible
      and not product.is_visible
      and product_group.code = 'TM8-GRP-MISC-ADHESIVE-CARD-HOLDER'
      and taxonomy.category_name = 'Mounts & Holders'
      and taxonomy.subcategory_name = 'Wallets, Card Holders & Grips'
  ) <> 2 then
    raise exception 'The missing card-holder colours were not imported correctly.';
  end if;

  if exists (
    select 1
    from public.product_store_inventory inventory
    join public.products product on product.id = inventory.product_id
    where product.source_system = 'repairdesk_misc_accessories'
      and product.source_external_id in ('7144', '7145')
  ) then
    raise exception 'Missing card-holder colours must not receive store inventory automatically.';
  end if;
end
$$;

commit;
