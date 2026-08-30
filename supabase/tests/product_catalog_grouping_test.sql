begin;

do $$
declare
  source_product public.products%rowtype;
  test_product_id bigint;
  test_product public.products%rowtype;
begin
  select *
  into source_product
  from public.products
  where sku = 'TM8-PC-9063';

  if not found then
    raise exception 'Clone test source product was not found.';
  end if;

  insert into public.products (
    sku, slug, name, brand, model, category_id, pos_category_id, pos_sort_order,
    compatibility, cost_price, retail_price, image_url, stock_quantity,
    is_visible, is_pos_visible, product_group_id, variant_name, variant_color,
    import_status, source_metadata
  ) values (
    source_product.sku || '-COPY', 'codex-clone-grouping-test', source_product.name,
    source_product.brand, source_product.model, source_product.category_id,
    source_product.pos_category_id, source_product.pos_sort_order,
    source_product.compatibility, source_product.cost_price, source_product.retail_price,
    source_product.image_url, 0, false, true, null, null, null, 'active', '{}'::jsonb
  )
  returning id into test_product_id;

  select * into test_product from public.products where id = test_product_id;
  if test_product.product_group_id is distinct from source_product.product_group_id
     or test_product.variant_color <> 'Black' then
    raise exception 'An exact cloned product did not inherit its group and colour.';
  end if;

  update public.products
  set name = 'Shockproof Grip Case for Samsung Galaxy S24 Plus - Red'
  where id = test_product_id;

  select * into test_product from public.products where id = test_product_id;
  if test_product.product_group_id is distinct from source_product.product_group_id
     or test_product.variant_name <> 'Red'
     or test_product.variant_color <> 'Red' then
    raise exception 'A colour-only clone did not remain grouped as Red.';
  end if;

  update public.products
  set name = 'Wallet Case for Samsung Galaxy S24 Plus - Red'
  where id = test_product_id;

  select * into test_product from public.products where id = test_product_id;
  if test_product.product_group_id is not null then
    raise exception 'A clone changed to a different style remained incorrectly grouped.';
  end if;

  update public.products
  set name = 'Shockproof Grip Case for Samsung Galaxy S24 Ultra - Red',
      model = 'Samsung Galaxy S24 Ultra'
  where id = test_product_id;

  select * into test_product from public.products where id = test_product_id;
  if test_product.product_group_id is not null then
    raise exception 'A clone changed to a different phone model inherited the source model group.';
  end if;
end;
$$;

do $$
begin
  if (select count(*) from public.products where source_system = 'repairdesk_accessories' and source_external_id in ('5955','5956','5954','5916')) <> 4 then
    raise exception 'Expected four AirPods products.';
  end if;

  if (
    select count(*)
    from public.products product
    join public.product_groups product_group on product_group.id = product.product_group_id
    where product_group.code = 'TM8-GRP-ACC-AIRTAG-CASE'
  ) <> 4 then
    raise exception 'Expected four sellable AirTag combinations in one group.';
  end if;

  if (
    select count(distinct product.model)
    from public.products product
    join public.product_groups product_group on product_group.id = product.product_group_id
    where product_group.code = 'TM8-GRP-ACC-AIRTAG-CASE'
  ) <> 2 then
    raise exception 'Expected exactly two AirTag styles.';
  end if;

  if exists (
    select 1
    from public.products product
    join public.product_groups product_group on product_group.id = product.product_group_id
    where product_group.name ilike 'Goospery Flip Case%'
      and product.import_status = 'active'
      and product.is_pos_visible
  ) then
    raise exception 'Goospery products still render as a separate Flip Case card.';
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
    raise exception 'Each S24 model must have Aqua and Red.';
  end if;

  if exists (
    select 1
    from public.products
    where sku in (
      'TM8-ACC-5955','TM8-ACC-5956','TM8-ACC-5954','TM8-ACC-5916',
      'TM8-ACC-6664','TM8-ACC-6020','TM8-ACC-6665','TM8-ACC-6666',
      'TM8-PC-S24-RED','TM8-PC-S24P-RED','TM8-PC-S24U-RED'
    )
      and stock_quantity <> 0
  ) then
    raise exception 'A new catalog product started with non-zero catalog stock.';
  end if;
end;
$$;

rollback;
