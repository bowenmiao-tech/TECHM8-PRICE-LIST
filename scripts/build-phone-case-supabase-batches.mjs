import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const inputPath = path.join(
  root,
  "outputs",
  "phone-case-catalog-20260817",
  "TECHM8_Phone_Cases_Import.json",
);
const outputDir = path.join(root, ".codex-temp", "phone-case-review-update", "supabase-batches");
const payload = JSON.parse(fs.readFileSync(inputPath, "utf8"));

fs.mkdirSync(outputDir, { recursive: true });

function jsonLiteral(tag, value) {
  const json = JSON.stringify(value);
  if (json.includes(`$${tag}$`)) {
    throw new Error(`Dollar quote tag ${tag} occurs in JSON payload.`);
  }
  return `$${tag}$${json}$${tag}$::jsonb`;
}

function writeBatch(name, sql) {
  const filePath = path.join(outputDir, `${name}.sql`);
  fs.writeFileSync(filePath, `${sql.trim()}\n`, "utf8");
  return { name, filePath, bytes: fs.statSync(filePath).size };
}

function chunks(values, size) {
  const result = [];
  for (let index = 0; index < values.length; index += size) {
    result.push(values.slice(index, index + size));
  }
  return result;
}

const files = [];
files.push(writeBatch("01_phone_case_catalog_reference_data", `
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
from jsonb_to_recordset(${jsonLiteral("taxonomy", payload.taxonomy)}) as input(
  category_name text, subcategory_name text, category_sort integer, subcategory_sort integer
)
on conflict (category_name, subcategory_name) do update
set category_sort = excluded.category_sort,
    subcategory_sort = excluded.subcategory_sort,
    active = true,
    updated_at = now();

insert into public.product_fit_profiles (code, display_name, source_category, notes, review_status)
select code, display_name, source_category, notes, review_status
from jsonb_to_recordset(${jsonLiteral("profiles", payload.fit_profiles)}) as input(
  code text, display_name text, source_category text, notes text, review_status text
)
on conflict (code) do update
set display_name = excluded.display_name,
    source_category = excluded.source_category,
    notes = excluded.notes,
    review_status = excluded.review_status,
    updated_at = timezone('utc'::text, now());

insert into public.device_models (code, brand, display_name, model_family, generation, release_year)
select code, brand, display_name, model_family, generation, release_year
from jsonb_to_recordset(${jsonLiteral("devices", payload.device_models)}) as input(
  code text, brand text, display_name text, model_family text, generation text, release_year integer
)
on conflict (code) do update
set brand = excluded.brand,
    display_name = excluded.display_name,
    model_family = excluded.model_family,
    generation = excluded.generation,
    release_year = excluded.release_year,
    updated_at = timezone('utc'::text, now());

insert into public.product_fit_profile_devices (fit_profile_id, device_model_id)
select profile.id, device.id
from jsonb_to_recordset(${jsonLiteral("mappings", payload.compatibility_mappings)}) as input(
  fit_profile_code text, device_model_code text
)
join public.product_fit_profiles profile on profile.code = input.fit_profile_code
join public.device_models device on device.code = input.device_model_code
on conflict (fit_profile_id, device_model_id) do nothing;

commit;
`));

for (const [index, groupBatch] of chunks(payload.product_groups, 180).entries()) {
  const suffix = String(index + 1).padStart(2, "0");
  files.push(writeBatch(`02_phone_case_groups_${suffix}`, `
begin;

insert into public.product_groups (
  code, slug, name, category_id, product_family, fit_profile_id, main_image_url,
  status, is_pos_visible, is_visible, pos_category_id, pos_sort_order
)
select
  input.code, input.slug, input.name, category.id, input.product_family, profile.id,
  input.main_image_url, input.status, input.is_pos_visible, input.is_visible,
  taxonomy.id, input.pos_sort_order
from jsonb_to_recordset(${jsonLiteral(`groups_${suffix}`, groupBatch)}) as input(
  code text, slug text, name text, product_family text, fit_profile_code text,
  main_image_url text, pos_main_category text, pos_subcategory text,
  pos_sort_order integer, status text, is_pos_visible boolean, is_visible boolean
)
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

commit;
`));
}

for (const [index, productBatch] of chunks(payload.products, 170).entries()) {
  const suffix = String(index + 1).padStart(2, "0");
  files.push(writeBatch(`03_phone_case_products_${suffix}`, `
begin;

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
from jsonb_to_recordset(${jsonLiteral(`products_${suffix}`, productBatch)}) as input(
  sku text, slug text, name text, brand text, model text, short_description text,
  condition_label text, compatibility text, cost_price numeric, retail_price numeric,
  image_url text, stock_quantity integer, is_visible boolean, is_pos_visible boolean,
  upc text, product_group_code text, variant_name text, variant_color text,
  source_system text, source_external_id text, source_category_path text,
  import_status text, pos_main_category text, pos_subcategory text,
  pos_sort_order integer, source_metadata jsonb
)
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

commit;
`));
}

files.push(writeBatch("04_phone_case_catalog_cleanup", `
begin;

update public.products product
set is_visible = false,
    is_pos_visible = false,
    import_status = 'archived',
    updated_at = timezone('utc'::text, now())
where product.source_system = 'repairdesk_phone_cases'
  and product.sku not in (
    select value #>> '{}'
    from jsonb_array_elements(${jsonLiteral("active_skus", payload.products.map((product) => product.sku))})
  );

update public.product_groups product_group
set status = 'archived',
    is_visible = false,
    is_pos_visible = false,
    updated_at = timezone('utc'::text, now())
where exists (
    select 1
    from public.products product
    where product.product_group_id = product_group.id
      and product.source_system = 'repairdesk_phone_cases'
  )
  and product_group.code not in (
    select value #>> '{}'
    from jsonb_array_elements(${jsonLiteral("active_groups", payload.product_groups.map((group) => group.code))})
  );

do $$
begin
  if (select count(*) from public.products where source_system = 'repairdesk_phone_cases' and import_status = 'active') <> ${payload.products.length} then
    raise exception 'Phone case database count does not match the import.';
  end if;
  if exists (
    select 1 from public.products product
    left join public.product_groups product_group on product_group.id = product.product_group_id
    left join public.pos_category_taxonomy taxonomy on taxonomy.id = product.pos_category_id
    where product.source_system = 'repairdesk_phone_cases'
      and product.import_status = 'active'
      and (product.cost_price <= 0 or product.retail_price <= 0 or product.cost_price >= product.retail_price
        or product.stock_quantity <> 0 or not product.is_pos_visible
        or product_group.id is null or taxonomy.category_name <> 'Phone Cases'
        or coalesce(btrim(product.image_url), '') = '')
  ) then
    raise exception 'Imported phone case verification failed.';
  end if;
end $$;

commit;
`));

console.log(JSON.stringify({
  outputDir,
  batches: files,
  totalBytes: files.reduce((sum, file) => sum + file.bytes, 0),
  expectedProducts: payload.products.length,
  expectedGroups: payload.product_groups.length,
}, null, 2));
