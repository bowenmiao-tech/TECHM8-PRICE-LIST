begin;

create or replace function private.catalog_colour_from_product_name(product_name text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  normalized_name text := lower(coalesce(product_name, ''));
begin
  return case
    when normalized_name ~ '(^|[^a-z0-9])rose[ -]?gold([^a-z0-9]|$)' then 'Rose Gold'
    when normalized_name ~ '(^|[^a-z0-9])hot[ -]?pink([^a-z0-9]|$)' then 'Hot Pink'
    when normalized_name ~ '(^|[^a-z0-9])navy[ -]?blue([^a-z0-9]|$)' then 'Navy Blue'
    when normalized_name ~ '(^|[^a-z0-9])dark[ -]?blue([^a-z0-9]|$)' then 'Dark Blue'
    when normalized_name ~ '(^|[^a-z0-9])light[ -]?pink([^a-z0-9]|$)' then 'Light Pink'
    when normalized_name ~ '(^|[^a-z0-9])sky[ -]?blue([^a-z0-9]|$)' then 'Sky Blue'
    when normalized_name ~ '(^|[^a-z0-9])matte[ -]?black([^a-z0-9]|$)' then 'Matte Black'
    when normalized_name ~ '(^|[^a-z0-9])transparent([^a-z0-9]|$)' then 'Transparent'
    when normalized_name ~ '(^|[^a-z0-9])aqua([^a-z0-9]|$)' then 'Aqua'
    when normalized_name ~ '(^|[^a-z0-9])black([^a-z0-9]|$)' then 'Black'
    when normalized_name ~ '(^|[^a-z0-9])brown([^a-z0-9]|$)' then 'Brown'
    when normalized_name ~ '(^|[^a-z0-9])clear([^a-z0-9]|$)' then 'Clear'
    when normalized_name ~ '(^|[^a-z0-9])gold([^a-z0-9]|$)' then 'Gold'
    when normalized_name ~ '(^|[^a-z0-9])green([^a-z0-9]|$)' then 'Green'
    when normalized_name ~ '(^|[^a-z0-9])gr[ae]y([^a-z0-9]|$)' then 'Grey'
    when normalized_name ~ '(^|[^a-z0-9])mercury([^a-z0-9]|$)' then 'Mercury'
    when normalized_name ~ '(^|[^a-z0-9])mint([^a-z0-9]|$)' then 'Mint'
    when normalized_name ~ '(^|[^a-z0-9])orange([^a-z0-9]|$)' then 'Orange'
    when normalized_name ~ '(^|[^a-z0-9])pink([^a-z0-9]|$)' then 'Pink'
    when normalized_name ~ '(^|[^a-z0-9])purple([^a-z0-9]|$)' then 'Purple'
    when normalized_name ~ '(^|[^a-z0-9])red([^a-z0-9]|$)' then 'Red'
    when normalized_name ~ '(^|[^a-z0-9])silver([^a-z0-9]|$)' then 'Silver'
    when normalized_name ~ '(^|[^a-z0-9])teal([^a-z0-9]|$)' then 'Teal'
    when normalized_name ~ '(^|[^a-z0-9])white([^a-z0-9]|$)' then 'White'
    when normalized_name ~ '(^|[^a-z0-9])yellow([^a-z0-9]|$)' then 'Yellow'
    when normalized_name ~ '(^|[^a-z0-9])blue([^a-z0-9]|$)' then 'Blue'
    else null
  end;
end;
$$;

create or replace function private.catalog_clone_name_signature(product_name text, product_model text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  signature text := lower(coalesce(product_name, ''));
  normalized_model text := lower(coalesce(product_model, ''));
begin
  if normalized_model <> '' then
    signature := replace(signature, normalized_model, ' ');
  end if;

  signature := regexp_replace(
    signature,
    '(^|[^a-z0-9])(rose[ -]?gold|hot[ -]?pink|navy[ -]?blue|dark[ -]?blue|light[ -]?pink|sky[ -]?blue|matte[ -]?black|transparent|aqua|black|brown|clear|gold|green|gr[ae]y|mercury|mint|orange|pink|purple|red|silver|teal|white|yellow|blue)([^a-z0-9]|$)',
    ' ',
    'gi'
  );
  signature := regexp_replace(signature, '(^|[^a-z0-9])(for|compatible|with)([^a-z0-9]|$)', ' ', 'gi');
  signature := regexp_replace(signature, '[^a-z0-9]+', ' ', 'g');
  return trim(regexp_replace(signature, '\s+', ' ', 'g'));
end;
$$;

create or replace function private.inherit_cloned_product_catalog_group()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  source_product public.products%rowtype;
  source_group public.product_groups%rowtype;
  source_sku text;
  source_signature text;
  clone_signature text;
  detected_colour text;
  inherited_before boolean := false;
  is_compatible_clone boolean := false;
begin
  if coalesce(new.sku, '') !~* '-COPY$' then
    return new;
  end if;

  source_sku := regexp_replace(new.sku, '(-COPY)+$', '', 'i');

  select product.*
  into source_product
  from public.products product
  where upper(product.sku) = upper(source_sku)
  order by product.id
  limit 1;

  if not found or source_product.product_group_id is null then
    return new;
  end if;

  select product_group.*
  into source_group
  from public.product_groups product_group
  where product_group.id = source_product.product_group_id;

  if not found then
    return new;
  end if;

  inherited_before := coalesce(
    (new.source_metadata #>> '{catalog_clone,group_inherited}')::boolean,
    false
  );
  source_signature := private.catalog_clone_name_signature(source_product.name, source_product.model);
  clone_signature := private.catalog_clone_name_signature(new.name, new.model);
  is_compatible_clone := (
      source_signature = clone_signature
      and lower(coalesce(new.model, '')) = lower(coalesce(source_product.model, ''))
    ) or (
      source_group.product_family = 'Branded Case Collection'
      and lower(coalesce(new.brand, '')) = lower(coalesce(source_product.brand, ''))
      and lower(coalesce(new.model, '')) = lower(coalesce(source_product.model, ''))
    );

  if is_compatible_clone and (new.product_group_id is null or inherited_before) then
    new.product_group_id := source_product.product_group_id;
    new.pos_category_id := coalesce(source_product.pos_category_id, source_group.pos_category_id);
    new.pos_sort_order := coalesce(source_product.pos_sort_order, source_group.pos_sort_order);
    detected_colour := private.catalog_colour_from_product_name(new.name);

    if source_group.product_family = 'Branded Case Collection' then
      new.variant_name := trim(regexp_replace(new.name, '\s+for\s+.*$', '', 'i'));
      new.variant_color := detected_colour;
    elsif detected_colour is not null then
      new.variant_name := detected_colour;
      new.variant_color := detected_colour;
    else
      new.variant_name := coalesce(new.variant_name, source_product.variant_name);
      new.variant_color := coalesce(new.variant_color, source_product.variant_color);
    end if;

    new.source_metadata := jsonb_set(
      coalesce(new.source_metadata, '{}'::jsonb),
      '{catalog_clone}',
      jsonb_build_object(
        'source_product_id', source_product.id,
        'source_sku', source_product.sku,
        'group_inherited', true
      ),
      true
    );
  elsif inherited_before and not is_compatible_clone then
    new.product_group_id := null;
    new.variant_name := null;
    new.variant_color := null;
    new.source_metadata := jsonb_set(
      coalesce(new.source_metadata, '{}'::jsonb),
      '{catalog_clone,group_inherited}',
      'false'::jsonb,
      true
    );
  end if;

  return new;
end;
$$;

revoke all on function private.catalog_colour_from_product_name(text) from public, anon, authenticated;
revoke all on function private.catalog_clone_name_signature(text, text) from public, anon, authenticated;
revoke all on function private.inherit_cloned_product_catalog_group() from public, anon, authenticated;

drop trigger if exists products_inherit_cloned_catalog_group on public.products;
create trigger products_inherit_cloned_catalog_group
before insert or update on public.products
for each row execute function private.inherit_cloned_product_catalog_group();

-- Repair existing colour-only and branded-collection clones without grouping unrelated clone experiments.
with clone_candidates as (
  select
    clone.id as clone_id,
    source.id as source_id,
    source.product_group_id,
    coalesce(source.pos_category_id, product_group.pos_category_id) as pos_category_id,
    coalesce(source.pos_sort_order, product_group.pos_sort_order) as pos_sort_order,
    product_group.product_family,
    private.catalog_colour_from_product_name(clone.name) as detected_colour,
    case
      when product_group.product_family = 'Branded Case Collection'
        then trim(regexp_replace(clone.name, '\s+for\s+.*$', '', 'i'))
      else coalesce(private.catalog_colour_from_product_name(clone.name), source.variant_name)
    end as resolved_variant_name,
    case
      when private.catalog_colour_from_product_name(clone.name) is not null
        then private.catalog_colour_from_product_name(clone.name)
      else source.variant_color
    end as resolved_variant_color,
    source.sku as source_sku
  from public.products clone
  join public.products source
    on upper(source.sku) = upper(regexp_replace(clone.sku, '(-COPY)+$', '', 'i'))
  join public.product_groups product_group on product_group.id = source.product_group_id
  where clone.sku ~* '-COPY$'
    and clone.product_group_id is null
    and (
      (
        private.catalog_clone_name_signature(clone.name, clone.model)
          = private.catalog_clone_name_signature(source.name, source.model)
        and lower(coalesce(clone.model, '')) = lower(coalesce(source.model, ''))
      )
      or (
        product_group.product_family = 'Branded Case Collection'
        and lower(coalesce(clone.brand, '')) = lower(coalesce(source.brand, ''))
        and lower(coalesce(clone.model, '')) = lower(coalesce(source.model, ''))
      )
    )
)
update public.products clone
set product_group_id = candidate.product_group_id,
    pos_category_id = candidate.pos_category_id,
    pos_sort_order = candidate.pos_sort_order,
    variant_name = candidate.resolved_variant_name,
    variant_color = candidate.resolved_variant_color,
    source_metadata = jsonb_set(
      coalesce(clone.source_metadata, '{}'::jsonb),
      '{catalog_clone}',
      jsonb_build_object(
        'source_product_id', candidate.source_id,
        'source_sku', candidate.source_sku,
        'group_inherited', true
      ),
      true
    ),
    updated_at = timezone('utc'::text, now())
from clone_candidates candidate
where clone.id = candidate.clone_id;

-- AirPods cases use their existing RepairDesk images, prices and identities, but begin with zero store stock.
update public.pos_category_taxonomy
set active = true,
    updated_at = now()
where category_name = 'Other Electronics'
  and subcategory_name = 'Earbud Cases';

with accessory_context as (
  select
    (select id from public.categories where slug = 'accessories') as category_id,
    (select id from public.pos_category_taxonomy where category_name = 'Other Electronics' and subcategory_name = 'Earbud Cases') as pos_category_id
), group_input(code, slug, name, product_family, image_url, sort_order) as (
  values
    ('TM8-GRP-ACC-AIRPODS-DESIGN', 'tm8-grp-acc-airpods-design', 'AirPods Design Cases', 'Earbud Case', 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1626099261.jpg', 10),
    ('TM8-GRP-ACC-AIRPODS-CARTOON-3D', 'tm8-grp-acc-airpods-cartoon-3d', 'AirPods 3D Cartoon Silicone Cases', 'Earbud Case', 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1626099375.jpg', 20),
    ('TM8-GRP-ACC-AIRPODS-LEATHER', 'tm8-grp-acc-airpods-leather', 'AirPods Leather Cases', 'Earbud Case', 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1626099054.jpg', 30),
    ('TM8-GRP-ACC-AIRPODS-SILICONE', 'tm8-grp-acc-airpods-silicone', 'AirPods Silicone Cases', 'Earbud Case', 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/162609920641943085.jpg', 40)
)
insert into public.product_groups (
  code, slug, name, category_id, product_family, fit_profile_id, main_image_url,
  status, is_pos_visible, is_visible, pos_category_id, pos_sort_order
)
select
  input.code, input.slug, input.name, context.category_id, input.product_family, null,
  input.image_url, 'active', true, false, context.pos_category_id, input.sort_order
from group_input input
cross join accessory_context context
on conflict (code) do update
set slug = excluded.slug,
    name = excluded.name,
    category_id = excluded.category_id,
    product_family = excluded.product_family,
    main_image_url = excluded.main_image_url,
    status = 'active',
    is_pos_visible = true,
    is_visible = false,
    pos_category_id = excluded.pos_category_id,
    pos_sort_order = excluded.pos_sort_order,
    updated_at = timezone('utc'::text, now());

with product_input(
  sku, slug, name, cost_price, retail_price, image_url, upc,
  group_code, source_external_id, source_product_id, inventory_index_id,
  original_name, original_cost, original_stock
) as (
  values
    ('TM8-ACC-5955', 'tm8-acc-5955', 'AirPods Design Cases', null::numeric, 15::numeric, 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1626099261.jpg', '2997000059559', 'TM8-GRP-ACC-AIRPODS-DESIGN', '5955', '42455665', '50748301', 'Airpod Design Cases', 15::numeric, 94),
    ('TM8-ACC-5956', 'tm8-acc-5956', 'AirPods 3D Cartoon Silicone Cases', 25::numeric, 29::numeric, 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1626099375.jpg', '2997000059566', 'TM8-GRP-ACC-AIRPODS-CARTOON-3D', '5956', '42455666', '50748302', 'Airpods 3D Cartoon Silicone Cases', 25::numeric, 138),
    ('TM8-ACC-5954', 'tm8-acc-5954', 'AirPods Leather Cases', null::numeric, 20::numeric, 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1626099054.jpg', '2997000059542', 'TM8-GRP-ACC-AIRPODS-LEATHER', '5954', '42455664', '50748300', 'Airpods Leather cases', 20::numeric, 15),
    ('TM8-ACC-5916', 'tm8-acc-5916', 'AirPods Silicone Cases', null::numeric, 15::numeric, 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/162609920641943085.jpg', '2997000059160', 'TM8-GRP-ACC-AIRPODS-SILICONE', '5916', '41943085', '50146364', 'Airpods Silicone Cases', 0::numeric, 129)
), product_context as (
  select
    (select id from public.categories where slug = 'accessories') as category_id,
    (select id from public.pos_category_taxonomy where category_name = 'Other Electronics' and subcategory_name = 'Earbud Cases') as pos_category_id
)
insert into public.products (
  sku, slug, name, brand, model, category_id, pos_category_id, pos_sort_order,
  short_description, condition_label, compatibility, cost_price, retail_price,
  image_url, stock_quantity, is_visible, is_pos_visible, upc, product_group_id,
  variant_name, variant_color, source_system, source_external_id,
  source_category_path, import_status, source_metadata
)
select
  input.sku, input.slug, input.name, 'OZTECHM8', 'Apple AirPods', context.category_id,
  context.pos_category_id, product_group.pos_sort_order,
  input.name || '. Select the exact style shown in the product image.',
  'Brand New', 'Apple AirPods', input.cost_price, input.retail_price,
  input.image_url, 0, false, true, input.upc, product_group.id,
  'Standard', null, 'repairdesk_accessories', input.source_external_id,
  '5. Phone Cases > Air Pods', 'active',
  jsonb_build_object(
    'original_name', input.original_name,
    'repairdesk_product_id', input.source_product_id,
    'inventory_index_id', input.inventory_index_id,
    'original_cost', input.original_cost,
    'original_stock_reference_only', input.original_stock,
    'inventory_assignment', 'zero_until_counted'
  )
from product_input input
cross join product_context context
join public.product_groups product_group on product_group.code = input.group_code
on conflict (sku) do update
set slug = excluded.slug,
    name = excluded.name,
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
    is_visible = false,
    is_pos_visible = true,
    upc = excluded.upc,
    product_group_id = excluded.product_group_id,
    variant_name = excluded.variant_name,
    variant_color = excluded.variant_color,
    source_system = excluded.source_system,
    source_external_id = excluded.source_external_id,
    source_category_path = excluded.source_category_path,
    import_status = 'active',
    source_metadata = excluded.source_metadata,
    updated_at = timezone('utc'::text, now());

-- AirTag is one catalog card. The four sellable rows are presented as two styles (Key Ring / Loop), each with Leather or Silicone.
with accessory_context as (
  select
    (select id from public.categories where slug = 'accessories') as category_id,
    (select id from public.pos_category_taxonomy where category_name = 'Other Electronics' and subcategory_name = 'Tracker Cases') as pos_category_id
)
insert into public.product_groups (
  code, slug, name, category_id, product_family, fit_profile_id, main_image_url,
  status, is_pos_visible, is_visible, pos_category_id, pos_sort_order
)
select
  'TM8-GRP-ACC-AIRTAG-CASE', 'tm8-grp-acc-airtag-case', 'AirTag Case',
  context.category_id, 'Tracker Case', null,
  'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/165136523042456376.jpg',
  'active', true, false, context.pos_category_id, 10
from accessory_context context
on conflict (code) do update
set slug = excluded.slug,
    name = excluded.name,
    category_id = excluded.category_id,
    product_family = excluded.product_family,
    main_image_url = excluded.main_image_url,
    status = 'active',
    is_pos_visible = true,
    is_visible = false,
    pos_category_id = excluded.pos_category_id,
    pos_sort_order = excluded.pos_sort_order,
    updated_at = timezone('utc'::text, now());

with product_input(
  sku, slug, name, style_name, material_name, cost_price, retail_price,
  image_url, upc, source_external_id, source_product_id, inventory_index_id,
  original_name, original_stock
) as (
  values
    ('TM8-ACC-6664', 'tm8-acc-6664', 'AirTag Key Ring - Leather', 'Key Ring', 'Leather', null::numeric, 15::numeric, 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/165136523042456376.jpg', '2997000066649', '6664', '42456376', '50755669', 'Leather Air Tag Key Ring', 11),
    ('TM8-ACC-6020', 'tm8-acc-6020', 'AirTag Key Ring - Silicone', 'Key Ring', 'Silicone', 3::numeric, 10::numeric, 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1630904996.jpg', '2997000060203', '6020', '42455730', '50748366', 'Silicone Air Tag Key Ring', -1),
    ('TM8-ACC-6665', 'tm8-acc-6665', 'AirTag Loop - Leather', 'Loop', 'Leather', null::numeric, 15::numeric, 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/165136518942456377.jpg', '2997000066656', '6665', '42456377', '50755671', 'Leather Air Tag Loop', 16),
    ('TM8-ACC-6666', 'tm8-acc-6666', 'AirTag Loop - Silicone', 'Loop', 'Silicone', null::numeric, 10::numeric, 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1651365061.jpg', '2997000066663', '6666', '42456378', '50755673', 'Silicone Air Tag Loop', 32)
), product_context as (
  select
    (select id from public.categories where slug = 'accessories') as category_id,
    (select id from public.pos_category_taxonomy where category_name = 'Other Electronics' and subcategory_name = 'Tracker Cases') as pos_category_id
)
insert into public.products (
  sku, slug, name, brand, model, category_id, pos_category_id, pos_sort_order,
  short_description, condition_label, compatibility, cost_price, retail_price,
  image_url, stock_quantity, is_visible, is_pos_visible, upc, product_group_id,
  variant_name, variant_color, source_system, source_external_id,
  source_category_path, import_status, source_metadata
)
select
  input.sku, input.slug, input.name, 'OZTECHM8', input.style_name,
  context.category_id, context.pos_category_id, product_group.pos_sort_order,
  input.material_name || ' AirTag ' || input.style_name || '.',
  'Brand New', 'Apple AirTag', input.cost_price, input.retail_price,
  input.image_url, 0, false, true, input.upc, product_group.id,
  input.material_name, null, 'repairdesk_accessories', input.source_external_id,
  '5. Phone Cases > Air Tag', 'active',
  jsonb_build_object(
    'original_name', input.original_name,
    'option_style', input.style_name,
    'option_material', input.material_name,
    'repairdesk_product_id', input.source_product_id,
    'inventory_index_id', input.inventory_index_id,
    'original_stock_reference_only', input.original_stock,
    'inventory_assignment', 'zero_until_counted'
  )
from product_input input
cross join product_context context
join public.product_groups product_group on product_group.code = 'TM8-GRP-ACC-AIRTAG-CASE'
on conflict (sku) do update
set slug = excluded.slug,
    name = excluded.name,
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
    is_visible = false,
    is_pos_visible = true,
    upc = excluded.upc,
    product_group_id = excluded.product_group_id,
    variant_name = excluded.variant_name,
    variant_color = excluded.variant_color,
    source_system = excluded.source_system,
    source_external_id = excluded.source_external_id,
    source_category_path = excluded.source_category_path,
    import_status = 'active',
    source_metadata = excluded.source_metadata,
    updated_at = timezone('utc'::text, now());

-- Flip Case and Goospery Flip Case are the same sellable style. Consolidate them per device without touching Rich Diary or Hanman.
do $$
declare
  goospery_group record;
  canonical_group_id bigint;
  consolidated_name text;
begin
  for goospery_group in
    select product_group.*
    from public.product_groups product_group
    where product_group.name ilike 'Goospery Flip Case%'
      and product_group.status = 'active'
    order by product_group.id
  loop
    consolidated_name := regexp_replace(goospery_group.name, '^Goospery\s+', '', 'i');
    canonical_group_id := null;

    select product_group.id
    into canonical_group_id
    from public.product_groups product_group
    where product_group.id <> goospery_group.id
      and product_group.fit_profile_id is not distinct from goospery_group.fit_profile_id
      and product_group.product_family = 'Flip Case'
      and lower(product_group.name) = lower(consolidated_name)
      and product_group.status = 'active'
    order by product_group.id
    limit 1;

    update public.products product
    set name = regexp_replace(product.name, '^Goospery\s+', '', 'i'),
        updated_at = timezone('utc'::text, now())
    where product.product_group_id = goospery_group.id;

    if canonical_group_id is not null then
      update public.products product
      set product_group_id = canonical_group_id,
          updated_at = timezone('utc'::text, now())
      where product.product_group_id = goospery_group.id;

      update public.product_groups
      set status = 'archived',
          is_pos_visible = false,
          is_visible = false,
          updated_at = timezone('utc'::text, now())
      where id = goospery_group.id;
    else
      update public.product_groups
      set name = consolidated_name,
          slug = regexp_replace(slug, 'goospery-', '', 'i'),
          updated_at = timezone('utc'::text, now())
      where id = goospery_group.id;
    end if;
  end loop;
end;
$$;

-- S24, S24 Plus and S24 Ultra already had Aqua/Black/Pink. Add the missing Red option to each existing group.
with red_input(sku, slug, model_name, group_code, image_url, upc, source_external_id) as (
  values
    ('TM8-PC-S24-RED', 'tm8-pc-s24-red', 'Samsung Galaxy S24', 'TM8-GRP-PC-SAMSUNG-S24-CB2B3F57E', 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.31801200%201710833333.jpg', '2997000240018', 's24-shockproof-red'),
    ('TM8-PC-S24P-RED', 'tm8-pc-s24p-red', 'Samsung Galaxy S24 Plus', 'TM8-GRP-PC-SAMSUNG-S24-PLUS-CB2B3F57E', 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.21555000%201710833309.jpg', '2997000240025', 's24-plus-shockproof-red'),
    ('TM8-PC-S24U-RED', 'tm8-pc-s24u-red', 'Samsung Galaxy S24 Ultra', 'TM8-GRP-PC-SAMSUNG-S24-ULTRA-CB2B3F57E', 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.81762400%201710833019.jpg', '2997000240032', 's24-ultra-shockproof-red')
), templates as (
  select distinct on (product.product_group_id)
    product.product_group_id,
    product.category_id,
    product.pos_category_id,
    product.pos_sort_order,
    product.cost_price,
    product.retail_price,
    product.condition_label
  from public.products product
  where product.variant_color = 'Aqua'
  order by product.product_group_id, product.id
)
insert into public.products (
  sku, slug, name, brand, model, category_id, pos_category_id, pos_sort_order,
  short_description, condition_label, compatibility, cost_price, retail_price,
  image_url, stock_quantity, is_visible, is_pos_visible, upc, product_group_id,
  variant_name, variant_color, source_system, source_external_id,
  source_category_path, import_status, source_metadata
)
select
  input.sku, input.slug,
  'Shockproof Grip Case for ' || input.model_name || ' - Red',
  'OZTECHM8', input.model_name, template.category_id, template.pos_category_id,
  template.pos_sort_order,
  'Shockproof Grip Case. Fits ' || input.model_name || '.',
  coalesce(template.condition_label, 'Brand New'), input.model_name,
  template.cost_price, template.retail_price, input.image_url,
  0, false, true, input.upc, product_group.id,
  'Red', 'Red', 'techm8_manual_catalog', input.source_external_id,
  '5. Phone Cases > Samsung S24 Series', 'active',
  jsonb_build_object(
    'catalog_request', 'S24 series missing Red option',
    'image_note', 'Existing exact-model Aqua image retained until a Red product photo is uploaded',
    'inventory_assignment', 'zero_until_counted'
  )
from red_input input
join public.product_groups product_group on product_group.code = input.group_code
join templates template on template.product_group_id = product_group.id
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
    is_visible = false,
    is_pos_visible = true,
    upc = excluded.upc,
    product_group_id = excluded.product_group_id,
    variant_name = 'Red',
    variant_color = 'Red',
    source_system = excluded.source_system,
    source_external_id = excluded.source_external_id,
    source_category_path = excluded.source_category_path,
    import_status = 'active',
    source_metadata = excluded.source_metadata,
    updated_at = timezone('utc'::text, now());

do $$
begin
  if (select count(*) from public.products where source_system = 'repairdesk_accessories' and source_external_id in ('5955','5956','5954','5916')) <> 4 then
    raise exception 'AirPods import verification failed.';
  end if;

  if (select count(*) from public.products where product_group_id = (select id from public.product_groups where code = 'TM8-GRP-ACC-AIRTAG-CASE')) <> 4 then
    raise exception 'AirTag grouping verification failed.';
  end if;

  if exists (
    select 1
    from public.products product
    join public.product_groups product_group on product_group.id = product.product_group_id
    where product_group.name ilike 'Goospery Flip Case%'
      and product.import_status = 'active'
      and product.is_pos_visible
  ) then
    raise exception 'Goospery consolidation verification failed.';
  end if;

  if (
    select count(*)
    from public.products product
    join public.product_groups product_group on product_group.id = product.product_group_id
    where product_group.code in (
      'TM8-GRP-PC-SAMSUNG-S24-CB2B3F57E',
      'TM8-GRP-PC-SAMSUNG-S24-PLUS-CB2B3F57E',
      'TM8-GRP-PC-SAMSUNG-S24-ULTRA-CB2B3F57E'
    )
      and product.variant_color in ('Aqua', 'Red')
      and product.import_status = 'active'
      and product.is_pos_visible
  ) <> 6 then
    raise exception 'S24 Aqua/Red verification failed.';
  end if;
end;
$$;

commit;
