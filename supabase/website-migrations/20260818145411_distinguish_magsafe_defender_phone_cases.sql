begin;

with group_input (
  code, slug, name, product_family, fit_profile_code, main_image_url,
  pos_main_category, pos_subcategory, pos_sort_order
) as (
  values
    (
      'TM8-GRP-PC-IPHONE-16-2515BFCE9',
      'tm8-grp-pc-iphone-16-2515bfce9',
      'OtterBox Defender MagSafe Case for iPhone 16',
      'Premium Branded Case',
      'PHONE-IPHONE-16',
      'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.09059500%201729655083.jpg',
      'Phone Cases',
      'Apple iPhone',
      3300
    ),
    (
      'TM8-GRP-PC-IPHONE-16-PLUS-2515BFCE9',
      'tm8-grp-pc-iphone-16-plus-2515bfce9',
      'OtterBox Defender MagSafe Case for iPhone 16 Plus',
      'Premium Branded Case',
      'PHONE-IPHONE-16-PLUS',
      'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.25971200%201729655226.jpg',
      'Phone Cases',
      'Apple iPhone',
      3400
    )
)
insert into public.product_groups (
  code, slug, name, category_id, product_family, fit_profile_id, main_image_url,
  status, is_pos_visible, is_visible, pos_category_id, pos_sort_order
)
select
  input.code,
  input.slug,
  input.name,
  category.id,
  input.product_family,
  profile.id,
  input.main_image_url,
  'active',
  true,
  false,
  taxonomy.id,
  input.pos_sort_order
from group_input input
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

with product_input (sku, name, short_description, product_group_code) as (
  values
    (
      'TM8-PC-9473',
      'OtterBox Defender MagSafe Case for iPhone 16',
      'OtterBox Defender MagSafe Case. Fits iPhone 16.',
      'TM8-GRP-PC-IPHONE-16-2515BFCE9'
    ),
    (
      'TM8-PC-9475',
      'OtterBox Defender MagSafe Case for iPhone 16 Plus',
      'OtterBox Defender MagSafe Case. Fits iPhone 16 Plus.',
      'TM8-GRP-PC-IPHONE-16-PLUS-2515BFCE9'
    )
)
update public.products product
set name = input.name,
    short_description = input.short_description,
    product_group_id = product_group.id,
    cost_price = 51.74,
    is_visible = false,
    is_pos_visible = true,
    import_status = 'active',
    updated_at = timezone('utc'::text, now())
from product_input input
join public.product_groups product_group on product_group.code = input.product_group_code
where product.sku = input.sku
  and product.source_system = 'repairdesk_phone_cases';

do $$
begin
  if (select count(*) from public.products where source_system = 'repairdesk_phone_cases' and import_status = 'active') <> 860 then
    raise exception 'Phone case database count changed while separating MagSafe Defender cases.';
  end if;

  if exists (
    select 1
    from public.products product
    where product.sku in ('TM8-PC-9473', 'TM8-PC-9475')
      and (product.name not like '%MagSafe%' or product.cost_price <> 51.74)
  ) then
    raise exception 'MagSafe Defender correction failed.';
  end if;
end $$;

commit;
