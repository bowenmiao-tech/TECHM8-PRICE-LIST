import fs from 'node:fs/promises';

const inputPath = new URL('../outputs/product-catalog-rebuild/TECHM8_Tablet_Cases_Draft_Import.json', import.meta.url);
const outputPath = new URL('../outputs/product-catalog-rebuild/TECHM8_Tablet_Cases_Draft_Import.sql', import.meta.url);
const chunkDir = new URL('../outputs/product-catalog-rebuild/sql-chunks/', import.meta.url);
const payload = JSON.parse(await fs.readFile(inputPath, 'utf8'));

const jsonLiteral = (value) => `$catalog$${JSON.stringify(value)}$catalog$::jsonb`;
const desiredSourceIds = payload.products.map((product) => String(product.source_external_id));
const desiredGroupCodes = payload.product_groups.map((group) => String(group.code));
const desiredProfileCodes = payload.fit_profiles.map((profile) => String(profile.code));
const desiredDeviceCodes = payload.device_models.map((device) => String(device.code));

const sql = `begin;

with desired as (
  select jsonb_array_elements_text(${jsonLiteral(desiredSourceIds)}) as source_external_id
)
delete from public.products product
where product.source_system = 'repairdesk_tablet_cases'
  and coalesce(product.import_status, '') <> 'active'
  and not exists (
    select 1 from desired where desired.source_external_id = product.source_external_id
  );

with desired as (
  select jsonb_array_elements_text(${jsonLiteral(desiredGroupCodes)}) as code
)
delete from public.product_groups product_group
where product_group.code like 'TM8-GRP-%'
  and coalesce(product_group.status, '') <> 'active'
  and not exists (select 1 from desired where desired.code = product_group.code)
  and not exists (select 1 from public.products product where product.product_group_id = product_group.id);

with desired as (
  select jsonb_array_elements_text(${jsonLiteral(desiredProfileCodes)}) as code
)
delete from public.product_fit_profile_devices mapping
using public.product_fit_profiles profile
where mapping.fit_profile_id = profile.id
  and not exists (select 1 from desired where desired.code = profile.code)
  and not exists (select 1 from public.product_groups product_group where product_group.fit_profile_id = profile.id);

with desired as (
  select jsonb_array_elements_text(${jsonLiteral(desiredProfileCodes)}) as code
)
delete from public.product_fit_profiles profile
where coalesce(profile.review_status, '') <> 'approved'
  and not exists (select 1 from desired where desired.code = profile.code)
  and not exists (select 1 from public.product_groups product_group where product_group.fit_profile_id = profile.id);

with desired as (
  select jsonb_array_elements_text(${jsonLiteral(desiredDeviceCodes)}) as code
)
delete from public.device_models device
where not exists (select 1 from desired where desired.code = device.code)
  and not exists (select 1 from public.product_fit_profile_devices mapping where mapping.device_model_id = device.id);

with input as (
  select * from jsonb_to_recordset(${jsonLiteral(payload.fit_profiles)}) as x(
    code text,
    display_name text,
    source_category text,
    notes text,
    review_status text
  )
)
insert into public.product_fit_profiles (code, display_name, source_category, notes, review_status)
select code, display_name, source_category, notes, review_status
from input
on conflict (code) do update
set display_name = excluded.display_name,
    source_category = excluded.source_category,
    notes = excluded.notes,
    review_status = case
      when product_fit_profiles.review_status = 'approved' then product_fit_profiles.review_status
      else excluded.review_status
    end,
    updated_at = timezone('utc'::text, now());

with input as (
  select * from jsonb_to_recordset(${jsonLiteral(payload.device_models)}) as x(
    code text,
    brand text,
    display_name text,
    model_family text,
    generation text,
    release_year integer
  )
)
insert into public.device_models (code, brand, display_name, model_family, generation, release_year)
select code, brand, display_name, model_family, generation, release_year
from input
on conflict (code) do update
set brand = excluded.brand,
    display_name = excluded.display_name,
    model_family = excluded.model_family,
    generation = excluded.generation,
    release_year = excluded.release_year,
    updated_at = timezone('utc'::text, now());

with desired as (
  select * from jsonb_to_recordset(${jsonLiteral(payload.compatibility_mappings)}) as x(
    fit_profile_code text,
    device_model_code text
  )
)
delete from public.product_fit_profile_devices mapping
using public.product_fit_profiles profile, public.device_models device
where mapping.fit_profile_id = profile.id
  and mapping.device_model_id = device.id
  and profile.code in (
    select jsonb_array_elements_text(${jsonLiteral(desiredProfileCodes)})
  )
  and not exists (
    select 1
    from desired
    where desired.fit_profile_code = profile.code
      and desired.device_model_code = device.code
  );

with input as (
  select * from jsonb_to_recordset(${jsonLiteral(payload.compatibility_mappings)}) as x(
    fit_profile_code text,
    device_model_code text
  )
)
insert into public.product_fit_profile_devices (fit_profile_id, device_model_id)
select profile.id, device.id
from input
join public.product_fit_profiles profile on profile.code = input.fit_profile_code
join public.device_models device on device.code = input.device_model_code
on conflict (fit_profile_id, device_model_id) do nothing;

with input as (
  select * from jsonb_to_recordset(${jsonLiteral(payload.product_groups)}) as x(
    code text,
    slug text,
    name text,
    product_family text,
    fit_profile_code text,
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
  input.code,
  input.slug,
  input.name,
  category.id,
  input.product_family,
  profile.id,
  nullif(input.main_image_url, ''),
  input.status,
  input.is_pos_visible,
  input.is_visible
from input
join public.categories category on category.slug = 'ipad-tablet-cases'
join public.product_fit_profiles profile on profile.code = input.fit_profile_code
on conflict (code) do update
set slug = excluded.slug,
    name = excluded.name,
    category_id = excluded.category_id,
    product_family = excluded.product_family,
    fit_profile_id = excluded.fit_profile_id,
    main_image_url = excluded.main_image_url,
    status = case when product_groups.status = 'active' then product_groups.status else excluded.status end,
    is_pos_visible = case when product_groups.status = 'active' then product_groups.is_pos_visible else excluded.is_pos_visible end,
    is_visible = case when product_groups.status = 'active' then product_groups.is_visible else excluded.is_visible end,
    updated_at = timezone('utc'::text, now());

with input as (
  select * from jsonb_to_recordset(${jsonLiteral(payload.products)}) as x(
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

select
  count(*) as imported_products,
  count(*) filter (where import_status = 'blocked') as blocked_products,
  count(*) filter (where import_status = 'review') as review_products,
  count(*) filter (where is_pos_visible) as pos_visible_products,
  count(*) filter (where is_visible) as online_visible_products,
  count(*) filter (where stock_quantity <> 0) as products_with_stock
from public.products
where source_system = 'repairdesk_tablet_cases';
`;

await fs.writeFile(outputPath, sql, 'utf8');

const fullProductsLiteral = jsonLiteral(payload.products);
const productStartNeedle = `with input as (\n  select * from jsonb_to_recordset(${fullProductsLiteral}) as x(\n    sku text,`;
const productStart = sql.indexOf(productStartNeedle);
const productEnd = sql.indexOf('\n\ncommit;', productStart);
if (productStart < 0 || productEnd < 0) throw new Error('Product SQL block could not be isolated.');

await fs.rm(chunkDir, { recursive: true, force: true });
await fs.mkdir(chunkDir, { recursive: true });
const setupBody = sql.slice('begin;\n\n'.length, productStart).trim();
const setupBlocks = setupBody.split(/\n\n(?=with input as \()/);
const setupFiles = [];
for (const [index, block] of setupBlocks.entries()) {
  const fileName = `000-${String(index + 1).padStart(2, '0')}-catalog-setup.sql`;
  const setupChunkSql = `begin;\n\n${block}\n\ncommit;\n`;
  await fs.writeFile(new URL(fileName, chunkDir), setupChunkSql, 'utf8');
  setupFiles.push({ fileName, bytes: Buffer.byteLength(setupChunkSql, 'utf8') });
}

const productBlockTemplate = sql.slice(productStart, productEnd);
const chunkSize = 20;
const chunkFiles = [];
for (let offset = 0; offset < payload.products.length; offset += chunkSize) {
  const chunk = payload.products.slice(offset, offset + chunkSize);
  const productBlock = productBlockTemplate.replace(fullProductsLiteral, jsonLiteral(chunk));
  const sequence = String(chunkFiles.length + 1).padStart(3, '0');
  const fileName = `${sequence}-products-${offset + 1}-${offset + chunk.length}.sql`;
  const chunkSql = `begin;\n\n${productBlock}\n\ncommit;\n`;
  await fs.writeFile(new URL(fileName, chunkDir), chunkSql, 'utf8');
  chunkFiles.push({ fileName, bytes: Buffer.byteLength(chunkSql, 'utf8'), rows: chunk.length });
}

await fs.writeFile(
  new URL('manifest.json', chunkDir),
  JSON.stringify({ setup_chunks: setupFiles, product_chunks: chunkFiles }, null, 2),
  'utf8'
);

console.log(JSON.stringify({
  outputPath: outputPath.pathname,
  bytes: Buffer.byteLength(sql, 'utf8'),
  setupChunks: setupFiles.length,
  maxSetupBytes: Math.max(...setupFiles.map((chunk) => chunk.bytes)),
  chunks: chunkFiles.length,
  maxChunkBytes: Math.max(...chunkFiles.map((chunk) => chunk.bytes)),
}));
