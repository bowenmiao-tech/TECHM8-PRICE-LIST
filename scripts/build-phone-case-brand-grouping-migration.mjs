import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const beforePath = process.env.PHONE_CASE_GROUPING_BEFORE_PATH
  || path.join(root, ".codex-temp", "phone-case-brand-grouping", "before.json");
const afterPath = process.env.PHONE_CASE_GROUPING_AFTER_PATH
  || path.join(root, "outputs", "phone-case-catalog-reconciliation-20260819", "TECHM8_Phone_Cases_Import.json");
const outputPath = process.env.PHONE_CASE_GROUPING_MIGRATION_PATH
  || path.join(root, "supabase", "website-migrations", "20260820093000_regroup_branded_phone_cases.sql");

const before = JSON.parse(fs.readFileSync(beforePath, "utf8"));
const after = JSON.parse(fs.readFileSync(afterPath, "utf8"));
const collectionBrands = new Set(["CASETiFY", "EFM", "OtterBox"]);
const expectedExcludedSourceIds = ["6688", "7112", "7143", "7679", "7680", "7681"];

function jsonLiteral(tag, value) {
  const json = JSON.stringify(value);
  if (json.includes(`$${tag}$`)) throw new Error(`Dollar quote tag ${tag} occurs in JSON payload.`);
  return `$${tag}$${json}$${tag}$::jsonb`;
}

function indexBy(values, key) {
  return new Map(values.map(value => [value[key], value]));
}

const beforeProducts = indexBy(before.products, "sku");
const afterProducts = indexBy(after.products, "sku");
if (beforeProducts.size !== afterProducts.size || afterProducts.size !== 1741) {
  throw new Error(`Expected the same 1741 products before and after grouping; got ${beforeProducts.size}/${afterProducts.size}.`);
}

const immutableFields = ["cost_price", "retail_price", "image_url", "upc", "stock_quantity"];
const groupingFields = [
  "name", "brand", "model", "short_description", "compatibility",
  "product_group_code", "variant_name", "variant_color", "pos_sort_order",
];
const targetProducts = after.products.filter(product => collectionBrands.has(product.brand));
const targetSkus = new Set(targetProducts.map(product => product.sku));

for (const product of after.products) {
  const previous = beforeProducts.get(product.sku);
  if (!previous) throw new Error(`Product ${product.sku} is new; this migration must only regroup existing products.`);
  for (const field of immutableFields) {
    if (JSON.stringify(product[field]) !== JSON.stringify(previous[field])) {
      throw new Error(`Immutable field ${field} changed for ${product.sku}.`);
    }
  }
  if (!targetSkus.has(product.sku)) {
    for (const field of groupingFields) {
      if (JSON.stringify(product[field]) !== JSON.stringify(previous[field])) {
        throw new Error(`Non-target product ${product.sku} changed field ${field}.`);
      }
    }
  }
}

if (targetProducts.length !== 477) {
  throw new Error(`Expected 477 branded products, got ${targetProducts.length}.`);
}

const targetGroupCodes = new Set(targetProducts.map(product => product.product_group_code));
const targetGroups = after.product_groups.filter(group => targetGroupCodes.has(group.code));
if (targetGroups.length !== 105 || targetGroups.some(group => group.product_family !== "Branded Case Collection")) {
  throw new Error(`Expected 105 branded collection groups, got ${targetGroups.length}.`);
}

const variantKeys = new Set();
for (const product of targetProducts) {
  const key = `${product.product_group_code}\u0000${String(product.variant_name).toLowerCase()}`;
  if (variantKeys.has(key)) throw new Error(`Duplicate child option in ${product.product_group_code}: ${product.variant_name}`);
  variantKeys.add(key);
}

const oldGroupCodes = Array.from(new Set(targetProducts.map(product => beforeProducts.get(product.sku).product_group_code)));
const productInput = targetProducts.map(product => ({
  sku: product.sku,
  source_external_id: product.source_external_id,
  name: product.name,
  brand: product.brand,
  model: product.model,
  short_description: product.short_description,
  compatibility: product.compatibility,
  product_group_code: product.product_group_code,
  variant_name: product.variant_name,
  variant_color: product.variant_color,
  pos_sort_order: product.pos_sort_order,
}));

const sql = `
begin;

create temporary table branded_case_profile_input on commit drop as
select * from jsonb_to_recordset(${jsonLiteral("profiles", after.fit_profiles)}) as input(
  code text, display_name text, source_category text, notes text, review_status text
);

create temporary table branded_case_device_input on commit drop as
select * from jsonb_to_recordset(${jsonLiteral("devices", after.device_models)}) as input(
  code text, brand text, display_name text, model_family text, generation text, release_year integer
);

create temporary table branded_case_mapping_input on commit drop as
select * from jsonb_to_recordset(${jsonLiteral("mappings", after.compatibility_mappings)}) as input(
  fit_profile_code text, device_model_code text
);

create temporary table branded_case_group_input on commit drop as
select * from jsonb_to_recordset(${jsonLiteral("groups", targetGroups)}) as input(
  code text, slug text, name text, product_family text, fit_profile_code text,
  main_image_url text, pos_main_category text, pos_subcategory text, pos_sort_order integer,
  status text, is_pos_visible boolean, is_visible boolean
);

create temporary table branded_case_product_input on commit drop as
select * from jsonb_to_recordset(${jsonLiteral("products", productInput)}) as input(
  sku text, source_external_id text, name text, brand text, model text,
  short_description text, compatibility text, product_group_code text,
  variant_name text, variant_color text, pos_sort_order integer
);

do $$
begin
  if (select count(*) from branded_case_group_input) <> 105 then
    raise exception 'Expected 105 branded phone case groups.';
  end if;
  if (select count(*) from branded_case_product_input) <> 477 then
    raise exception 'Expected 477 branded phone case products.';
  end if;
  if exists (
    select 1 from branded_case_group_input
    where product_family <> 'Branded Case Collection'
       or status <> 'active' or not is_pos_visible or is_visible
       or coalesce(btrim(main_image_url), '') = ''
  ) then
    raise exception 'Branded phone case group input is invalid.';
  end if;
  if exists (
    select sku from branded_case_product_input group by sku having count(*) > 1
  ) or exists (
    select source_external_id from branded_case_product_input group by source_external_id having count(*) > 1
  ) or exists (
    select product_group_code, lower(variant_name)
    from branded_case_product_input
    group by product_group_code, lower(variant_name)
    having count(*) > 1
  ) then
    raise exception 'Branded phone case input contains a duplicate product or child option.';
  end if;
  if (
    select count(*)
    from public.products product
    join branded_case_product_input input
      on input.sku = product.sku
     and input.source_external_id = product.source_external_id
    where product.source_system = 'repairdesk_phone_cases'
      and product.import_status = 'active'
  ) <> 477 then
    raise exception 'The live database does not contain all 477 expected branded phone case products.';
  end if;
end $$;

insert into public.product_fit_profiles (code, display_name, source_category, notes, review_status)
select code, display_name, source_category, notes, review_status
from branded_case_profile_input
on conflict (code) do update
set display_name = excluded.display_name,
    source_category = excluded.source_category,
    notes = excluded.notes,
    review_status = excluded.review_status,
    updated_at = timezone('utc'::text, now());

insert into public.device_models (code, brand, display_name, model_family, generation, release_year)
select code, brand, display_name, model_family, generation, release_year
from branded_case_device_input
on conflict (code) do update
set brand = excluded.brand,
    display_name = excluded.display_name,
    model_family = excluded.model_family,
    generation = excluded.generation,
    release_year = excluded.release_year,
    updated_at = timezone('utc'::text, now());

insert into public.product_fit_profile_devices (fit_profile_id, device_model_id)
select profile.id, device.id
from branded_case_mapping_input input
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
from branded_case_group_input input
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

update public.products product
set name = input.name,
    brand = input.brand,
    model = input.model,
    short_description = input.short_description,
    compatibility = input.compatibility,
    product_group_id = product_group.id,
    variant_name = input.variant_name,
    variant_color = input.variant_color,
    pos_sort_order = input.pos_sort_order,
    updated_at = timezone('utc'::text, now())
from branded_case_product_input input
join public.product_groups product_group on product_group.code = input.product_group_code
where product.sku = input.sku
  and product.source_system = 'repairdesk_phone_cases'
  and product.source_external_id = input.source_external_id;

update public.product_groups product_group
set status = 'archived',
    is_pos_visible = false,
    is_visible = false,
    updated_at = timezone('utc'::text, now())
where product_group.code in (
  select value #>> '{}'
  from jsonb_array_elements(${jsonLiteral("old_groups", oldGroupCodes)})
)
  and not exists (
    select 1 from public.products product where product.product_group_id = product_group.id
  );

do $$
begin
  if (
    select count(*)
    from public.products product
    join branded_case_product_input input on input.sku = product.sku
    join public.product_groups product_group on product_group.id = product.product_group_id
    where product.source_system = 'repairdesk_phone_cases'
      and product.source_external_id = input.source_external_id
      and product_group.code = input.product_group_code
      and product.brand = input.brand
      and product.name = input.name
      and product.model = input.model
      and product.variant_name = input.variant_name
      and product.variant_color is not distinct from input.variant_color
  ) <> 477 then
    raise exception 'Branded phone case regroup verification failed.';
  end if;
  if (select count(*) from public.products where source_system = 'repairdesk_phone_cases') <> 1741 then
    raise exception 'Phone case product count changed during regrouping.';
  end if;
  if exists (
    select 1 from public.products
    where source_system = 'repairdesk_phone_cases'
      and source_external_id in (${expectedExcludedSourceIds.map(value => `'${value}'`).join(", ")})
      and import_status = 'active'
  ) then
    raise exception 'A permanently excluded phone case was restored.';
  end if;
end $$;

commit;

select
  count(*) as branded_products,
  count(distinct product.product_group_id) as branded_groups,
  count(*) filter (where product.brand = 'CASETiFY') as casetify_products,
  count(*) filter (where product.brand = 'EFM') as efm_products,
  count(*) filter (where product.brand = 'OtterBox') as otterbox_products
from public.products product
join public.product_groups product_group on product_group.id = product.product_group_id
where product.source_system = 'repairdesk_phone_cases'
  and product_group.product_family = 'Branded Case Collection';
`;

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${sql.trim()}\n`, "utf8");

console.log(JSON.stringify({
  beforePath,
  afterPath,
  outputPath,
  products: targetProducts.length,
  groups: targetGroups.length,
  oldGroups: oldGroupCodes.length,
  brands: Object.fromEntries(Array.from(collectionBrands).map(brand => [
    brand,
    targetProducts.filter(product => product.brand === brand).length,
  ])),
}, null, 2));
