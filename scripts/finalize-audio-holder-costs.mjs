import fs from 'node:fs/promises';
import path from 'node:path';
import { FileBlob, SpreadsheetFile } from '@oai/artifact-tool';

const workspaceRoot = 'D:/program/TECHM8 PRICE LIST';
const sourcePaths = [
  'E:/ontimefile/products (25).xlsx',
  'E:/ontimefile/products (26).xlsx',
];
const reviewWorkbookPath = `${workspaceRoot}/outputs/audio-holder-fan-catalog-20260812/TECHM8_Audio_Holder_Fan_Import_Review.xlsx`;
const importJsonPath = `${workspaceRoot}/outputs/audio-holder-fan-catalog-20260812/TECHM8_Audio_Holder_Fan_Import.json`;
const imageMapPath = `${workspaceRoot}/.codex-temp/audio-mount-import/repairdesk-images.json`;
const overridesPath = `${workspaceRoot}/outputs/audio-holder-fan-catalog-20260812/TECHM8_Audio_Holder_Fan_Cost_Overrides.json`;
const migrationPath = `${workspaceRoot}/supabase/website-migrations/20260813001836_finalize_audio_holder_fan_costs.sql`;

const text = (value) => String(value ?? '').trim();
const numberValue = (value) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};
const normalize = (value) => text(value)
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();
const slugify = (value) => text(value)
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, '-')
  .replace(/^-+|-+$/g, '')
  .slice(0, 90);
const sqlLiteral = (value) => `'${text(value).replaceAll("'", "''")}'`;

function ean13FromSourceId(sourceId, prefix = '2996') {
  const digits = text(sourceId).replace(/\D/g, '').slice(-8).padStart(8, '0');
  const body = `${prefix}${digits}`;
  let sum = 0;
  for (let index = 0; index < body.length; index += 1) {
    sum += Number(body[index]) * (index % 2 === 0 ? 1 : 3);
  }
  return `${body}${(10 - (sum % 10)) % 10}`;
}

function categorySlug(mainCategory, subcategory) {
  if (mainCategory === 'Audio') return 'wireless-and-bluetooth-headphones';
  if (mainCategory === 'Cables & Adapters') return 'cable';
  if (mainCategory === 'Mounts & Holders') return 'holder-car-play-charger';
  if (subcategory === 'Personal Fans') return 'accessories';
  throw new Error(`Unsupported category: ${mainCategory} > ${subcategory}`);
}

function brandFromName(name) {
  if (/^remax\b/i.test(name)) return 'Remax';
  if (/^wekome\b/i.test(name)) return 'WEKOME';
  if (/^wk\b/i.test(name)) return 'WK';
  return 'OZTECHM8';
}

async function readJson(filePath) {
  return JSON.parse((await fs.readFile(filePath, 'utf8')).replace(/^\uFEFF/, ''));
}

async function readSourceProducts() {
  const products = new Map();
  for (const sourcePath of sourcePaths) {
    const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(sourcePath));
    const rows = workbook.worksheets.getItem('Sheet1').getUsedRange(true).values;
    const headers = rows[0].map(text);
    const column = Object.fromEntries(headers.map((header, index) => [header, index]));
    for (const row of rows.slice(2)) {
      const itemId = text(row[column['Item ID']]);
      if (!itemId) continue;
      products.set(itemId, {
        source_file: path.basename(sourcePath),
        item_id: itemId,
        source_category: text(row[column.Category]),
        original_name: text(row[column['Item Name']]),
        source_sku: text(row[column.SKU]),
        source_upc: text(row[column.UPC]),
        source_stock: numberValue(row[column['On Hand Qty']]),
        source_cost: numberValue(row[column['Cost Price']]),
        retail_price: numberValue(row[column['Retail Price']]),
      });
    }
  }
  return products;
}

const reviewWorkbook = await SpreadsheetFile.importXlsx(await FileBlob.load(reviewWorkbookPath));
const reviewRows = reviewWorkbook.worksheets.getItem('Cost Required').getRange('A2:J9').values.map((row) => ({
  item_id: text(row[0]),
  product_name: text(row[1]),
  record_type: text(row[2]),
  source_category: text(row[3]),
  pos_category: text(row[4]),
  current_cost: numberValue(row[5]),
  final_cost: numberValue(row[6]),
  retail_price: numberValue(row[7]),
  image_url: text(row[8]),
}));

if (reviewRows.length !== 8 || new Set(reviewRows.map((row) => row.item_id)).size !== 8) {
  throw new Error('Expected eight unique cost approval rows.');
}
if (reviewRows.some((row) => row.final_cost <= 0)) {
  throw new Error('Every approved final cost must be positive.');
}

const originalPayload = await readJson(importJsonPath);
const originalCostRows = new Map(originalPayload.cost_required.map((row) => [text(row.item_id), row]));
const sourceProducts = await readSourceProducts();
const imageRows = await readJson(imageMapPath);
const imageByUrl = new Map(imageRows.map((row) => [text(row.image_url), row]));

for (const reviewRow of reviewRows) {
  const original = originalCostRows.get(reviewRow.item_id);
  if (!original) throw new Error(`Unknown cost approval item: ${reviewRow.item_id}`);
  if (original.name !== reviewRow.product_name || numberValue(original.retail_price) !== reviewRow.retail_price) {
    throw new Error(`Cost approval row does not match the reviewed product: ${reviewRow.item_id}`);
  }
}

const existingCostFix = reviewRows.find((row) => row.record_type === 'Existing');
const newCostRows = reviewRows.filter((row) => row.record_type === 'New - waiting');
if (!existingCostFix || existingCostFix.item_id !== '9019' || newCostRows.length !== 7) {
  throw new Error('Expected one Remax G6 cost correction and seven new products.');
}

const importProducts = newCostRows.map((reviewRow) => {
  const original = originalCostRows.get(reviewRow.item_id);
  const source = sourceProducts.get(reviewRow.item_id);
  const image = imageByUrl.get(reviewRow.image_url);
  if (!source) throw new Error(`Missing source product: ${reviewRow.item_id}`);
  if (source.source_sku !== original.sku || source.retail_price !== reviewRow.retail_price) {
    throw new Error(`Source SKU or retail price changed for ${reviewRow.item_id}.`);
  }
  if (source.source_cost !== 0) throw new Error(`Source cost is no longer zero for ${reviewRow.item_id}.`);
  const [posMainCategory, posSubcategory] = reviewRow.pos_category.split('>').map(text);
  if (posMainCategory !== original.pos_main_category || posSubcategory !== original.pos_subcategory) {
    throw new Error(`POS category mismatch for ${reviewRow.item_id}.`);
  }
  const sourceSystem = source.source_file === 'products (25).xlsx'
    ? 'repairdesk_audio_products'
    : 'repairdesk_holder_fan_products';
  return {
    sku: original.sku,
    slug: `repairdesk-accessory-${reviewRow.item_id}-${slugify(reviewRow.product_name)}`,
    name: reviewRow.product_name,
    brand: brandFromName(reviewRow.product_name),
    model: null,
    database_category_slug: categorySlug(posMainCategory, posSubcategory),
    pos_main_category: posMainCategory,
    pos_subcategory: posSubcategory,
    short_description: posSubcategory,
    condition_label: 'Brand New',
    compatibility: null,
    cost_price: reviewRow.final_cost,
    retail_price: reviewRow.retail_price,
    image_url: reviewRow.image_url,
    stock_quantity: 0,
    is_visible: false,
    is_pos_visible: true,
    upc: ean13FromSourceId(reviewRow.item_id),
    source_system: sourceSystem,
    source_external_id: reviewRow.item_id,
    source_category_path: source.source_category,
    import_status: 'active',
    source_metadata: {
      original_name: source.original_name,
      original_sku: source.source_sku,
      original_upc: source.source_upc,
      source_stock: source.source_stock,
      owner_confirmed_cost: reviewRow.final_cost,
      owner_confirmed_at: '2026-08-13',
      proposed_stock: 0,
      inventory_assignment: 'none',
      repairdesk_product_id: image?.repairdesk_product_id || null,
      inventory_index_id: image?.inventory_index_id || null,
      image_source: 'repairdesk_pos',
      pos_main_category: posMainCategory,
      pos_subcategory: posSubcategory,
    },
  };
});

const skus = importProducts.map((product) => product.sku);
const barcodes = importProducts.map((product) => product.upc);
if (new Set(skus).size !== importProducts.length) throw new Error('Duplicate finalized SKU.');
if (new Set(barcodes).size !== importProducts.length) throw new Error('Duplicate finalized barcode.');

const overrides = {
  approved_at: '2026-08-13',
  source_workbook: path.basename(reviewWorkbookPath),
  existing_cost_correction: {
    item_id: existingCostFix.item_id,
    product_id: originalCostRows.get(existingCostFix.item_id).existing_product_id,
    sku: originalCostRows.get(existingCostFix.item_id).sku,
    name: existingCostFix.product_name,
    final_cost: existingCostFix.final_cost,
  },
  newly_enabled_products: importProducts.map((product) => ({
    item_id: product.source_external_id,
    sku: product.sku,
    name: product.name,
    final_cost: product.cost_price,
  })),
};
await fs.writeFile(overridesPath, `${JSON.stringify(overrides, null, 2)}\n`, 'utf8');

const existingFix = overrides.existing_cost_correction;
const sql = `begin;

create temporary table audio_holder_fan_cost_final_input on commit drop as
select *
from jsonb_to_recordset($catalog$${JSON.stringify(importProducts)}$catalog$::jsonb) as x(
  sku text,
  slug text,
  name text,
  brand text,
  model text,
  database_category_slug text,
  pos_main_category text,
  pos_subcategory text,
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
  source_system text,
  source_external_id text,
  source_category_path text,
  import_status text,
  source_metadata jsonb
);

do $$
begin
  if (select count(*) from audio_holder_fan_cost_final_input) <> 7 then
    raise exception 'Expected seven finalized audio/holder/fan products.';
  end if;

  if exists (
    select 1
    from audio_holder_fan_cost_final_input input
    left join public.categories category on category.slug = input.database_category_slug
    left join public.pos_category_taxonomy taxonomy
      on taxonomy.category_name = input.pos_main_category
     and taxonomy.subcategory_name = input.pos_subcategory
     and taxonomy.active
    where category.id is null or taxonomy.id is null
  ) then
    raise exception 'A finalized product references a missing category.';
  end if;

  if exists (
    select 1
    from audio_holder_fan_cost_final_input input
    where input.cost_price <= 0
       or input.retail_price <= 0
       or coalesce(btrim(input.image_url), '') = ''
  ) then
    raise exception 'A finalized product has invalid cost, retail price, or image.';
  end if;

  if exists (
    select 1
    from audio_holder_fan_cost_final_input input
    join public.products product on product.sku = input.sku
    where product.source_system is distinct from input.source_system
       or product.source_external_id is distinct from input.source_external_id
  ) then
    raise exception 'A finalized SKU is owned by another product.';
  end if;

  if exists (
    select 1
    from audio_holder_fan_cost_final_input input
    join public.products product
      on product.source_system = input.source_system
     and product.source_external_id = input.source_external_id
    where product.sku <> input.sku
  ) then
    raise exception 'A finalized source item already has another SKU.';
  end if;

  if not exists (
    select 1
    from public.products product
    where product.id = ${Number(existingFix.product_id)}
      and product.sku = ${sqlLiteral(existingFix.sku)}
      and product.name = 'Remax G6  Wireless GameBubs'
      and product.cost_price in (0, ${Number(existingFix.final_cost)})
  ) then
    raise exception 'The existing Remax G6 product no longer matches the approved correction.';
  end if;
end
$$;

insert into public.products (
  sku, slug, name, brand, model, category_id, pos_category_id,
  short_description, condition_label, compatibility,
  cost_price, retail_price, image_url, stock_quantity,
  is_visible, is_pos_visible, upc,
  source_system, source_external_id, source_category_path,
  import_status, source_metadata
)
select
  input.sku,
  input.slug,
  input.name,
  input.brand,
  input.model,
  category.id,
  taxonomy.id,
  input.short_description,
  input.condition_label,
  input.compatibility,
  input.cost_price,
  input.retail_price,
  input.image_url,
  0,
  false,
  true,
  input.upc,
  input.source_system,
  input.source_external_id,
  input.source_category_path,
  input.import_status,
  input.source_metadata
from audio_holder_fan_cost_final_input input
join public.categories category on category.slug = input.database_category_slug
join public.pos_category_taxonomy taxonomy
  on taxonomy.category_name = input.pos_main_category
 and taxonomy.subcategory_name = input.pos_subcategory
 and taxonomy.active
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
    is_pos_visible = true,
    upc = excluded.upc,
    source_category_path = excluded.source_category_path,
    import_status = excluded.import_status,
    source_metadata = excluded.source_metadata,
    updated_at = timezone('utc'::text, now())
where public.products.source_system = excluded.source_system
  and public.products.source_external_id = excluded.source_external_id;

update public.products
set cost_price = ${Number(existingFix.final_cost)},
    updated_at = timezone('utc'::text, now())
where id = ${Number(existingFix.product_id)}
  and sku = ${sqlLiteral(existingFix.sku)};

do $$
begin
  if (
    select count(*)
    from public.products product
    where (product.source_system, product.source_external_id) in (
      select input.source_system, input.source_external_id
      from audio_holder_fan_cost_final_input input
    )
      and product.import_status = 'active'
      and product.is_pos_visible
      and not product.is_visible
      and product.stock_quantity = 0
      and product.cost_price > 0
      and product.retail_price > 0
      and product.pos_category_id is not null
      and coalesce(btrim(product.image_url), '') <> ''
  ) <> 7 then
    raise exception 'Finalized product validation failed.';
  end if;

  if exists (
    select 1
    from public.product_store_inventory inventory
    join public.products product on product.id = inventory.product_id
    where (product.source_system, product.source_external_id) in (
      select input.source_system, input.source_external_id
      from audio_holder_fan_cost_final_input input
    )
  ) then
    raise exception 'Finalized products must not begin with store inventory.';
  end if;

  if not exists (
    select 1
    from public.products product
    where product.id = ${Number(existingFix.product_id)}
      and product.sku = ${sqlLiteral(existingFix.sku)}
      and product.cost_price = ${Number(existingFix.final_cost)}
  ) then
    raise exception 'Remax G6 cost correction failed.';
  end if;
end
$$;

commit;
`;

await fs.writeFile(migrationPath, sql, 'utf8');

console.log(JSON.stringify({
  migration: migrationPath,
  overrides: overridesPath,
  new_products: importProducts.length,
  existing_cost_corrections: 1,
  costs: reviewRows.map((row) => ({ item_id: row.item_id, final_cost: row.final_cost })),
}, null, 2));
