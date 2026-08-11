import fs from 'node:fs/promises';
import path from 'node:path';
import { FileBlob, SpreadsheetFile } from '@oai/artifact-tool';

const workspaceRoot = 'D:/program/TECHM8 PRICE LIST';
const reviewWorkbookPath = process.argv[2]
  ?? `${workspaceRoot}/outputs/computer-product-crosscheck-20260812/TECHM8_Computer_Product_Import_Cross_Checked.xlsx`;
const outputDir = `${workspaceRoot}/outputs/computer-product-catalog-rebuild`;
const importJsonPath = `${outputDir}/TECHM8_Computer_Products_Import.json`;
const importSqlPath = `${workspaceRoot}/supabase/website-migrations/20260812011000_import_repairdesk_computer_products.sql`;

const imageOverrides = new Map([
  ['9978', 'https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/product-images/products/computer-products/deepcool-ag400-plus-single-tower-air-cooler/deepcool-ag400-plus-single-tower-air-cooler-00.png'],
  ['9983', 'https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/product-images/products/computer-products/deepcool-ag620-120mm-argb-cpu-cooler-white/deepcool-ag620-120mm-argb-cpu-cooler-white-00.png'],
  ['10545', 'https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/product-images/products/computer-products/msi-mag-a850gn-850w-power-supply/msi-mag-a850gn-850w-power-supply-00.png'],
]);

const importActions = new Set(['IMPORT', 'REVIEW MATCH']);
const textValue = (value) => String(value ?? '').trim();
const numberValue = (value) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};
const slugify = (value) => textValue(value)
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, '-')
  .replace(/^-+|-+$/g, '')
  .slice(0, 80);
const cleanName = (value) => textValue(value)
  .replace(/[\u2012\u2013\u2014\u2015]/g, '-')
  .replace(/[\u201c\u201d]/g, '"')
  .replace(/[\u2018\u2019]/g, "'")
  .replace(/\s+/g, ' ')
  .trim();

function databaseCategorySlug(product) {
  const main = product.pos_main_category;
  const subcategory = product.pos_subcategory;
  const searchText = `${product.name} ${product.source_category_path}`.toLowerCase();

  if (main === 'Cables & Adapters') return 'cable';
  if (main === 'Mounts & Holders') return 'holder-car-play-charger';
  if (main === 'Audio') {
    if (subcategory === 'Speakers') return 'speakers';
    return 'wireless-and-bluetooth-headphones';
  }
  if (main === 'Computer & Gaming') {
    if (/graphics card|\bgpu\b|\brtx\b|\bgtx\b/.test(searchText)) return 'graphics-cards';
    if (/liquid cool|coreliquid|\baio\b/.test(searchText)) return 'liquid-cooling';
    if (subcategory === 'Consoles & Controllers' && /dualsense|playstation|\bps5\b/.test(searchText)) {
      return 'ps5-controllers';
    }
    return 'gaming-essentials';
  }
  throw new Error(`No existing database category mapping for ${product.item_id}: ${main} > ${subcategory}`);
}

await fs.mkdir(outputDir, { recursive: true });
const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(reviewWorkbookPath));
const productSheet = workbook.worksheets.getItem('Product Review');
const rows = productSheet.getUsedRange(true).values;
const headers = rows[0].map(textValue);
const column = Object.fromEntries(headers.map((header, index) => [header, index]));

const requiredHeaders = [
  'Item ID',
  'Import Action',
  'Source Category',
  'POS Main Category',
  'POS Subcategory',
  'Source Product Name',
  'POS Product Name',
  'Brand',
  'Source SKU',
  'POS SKU',
  'Final Cost (FROM COST REVIEW)',
  'Final Retail (FROM COST REVIEW)',
  'Barcode',
  'Image URL (EDIT IF MISSING)',
  'Source Stock',
];
for (const header of requiredHeaders) {
  if (!(header in column)) throw new Error(`Missing Product Review column: ${header}`);
}

const reviewedRows = rows.slice(1).filter((row) => textValue(row[column['Item ID']])).map((row) => {
  const itemId = textValue(row[column['Item ID']]);
  const action = textValue(row[column['Import Action']]).toUpperCase();
  const product = {
    item_id: itemId,
    review_action: action,
    source_category_path: textValue(row[column['Source Category']]),
    pos_main_category: textValue(row[column['POS Main Category']]),
    pos_subcategory: textValue(row[column['POS Subcategory']]),
    original_name: textValue(row[column['Source Product Name']]),
    name: cleanName(row[column['POS Product Name']] || row[column['Source Product Name']]),
    brand: textValue(row[column.Brand]) || 'OZTECHM8',
    source_sku: textValue(row[column['Source SKU']]),
    sku: textValue(row[column['POS SKU']]),
    cost_price: numberValue(row[column['Final Cost (FROM COST REVIEW)']]),
    retail_price: numberValue(row[column['Final Retail (FROM COST REVIEW)']]),
    upc: textValue(row[column.Barcode]),
    image_url: imageOverrides.get(itemId) || textValue(row[column['Image URL (EDIT IF MISSING)']]),
    source_stock: numberValue(row[column['Source Stock']]),
  };
  return {
    ...product,
    slug: `repairdesk-computer-${itemId}-${slugify(product.name)}`,
    category_slug: databaseCategorySlug(product),
  };
});

const products = reviewedRows.filter((product) => importActions.has(product.review_action)).map((product) => ({
  sku: product.sku,
  slug: product.slug,
  name: product.name,
  brand: product.brand,
  model: null,
  category_slug: product.category_slug,
  short_description: product.pos_subcategory,
  condition_label: 'Brand New',
  compatibility: null,
  cost_price: product.cost_price,
  retail_price: product.retail_price,
  image_url: product.image_url,
  stock_quantity: 0,
  is_visible: false,
  is_pos_visible: true,
  upc: product.upc || null,
  source_system: 'repairdesk_computer_products',
  source_external_id: product.item_id,
  source_category_path: product.source_category_path,
  import_status: 'active',
  source_metadata: {
    original_name: product.original_name,
    original_sku: product.source_sku,
    source_stock: product.source_stock,
    pos_main_category: product.pos_main_category,
    pos_subcategory: product.pos_subcategory,
    approved_review_action: product.review_action,
    proposed_stock: 0,
    inventory_assignment: 'none',
    image_source: imageOverrides.has(product.item_id) ? 'owner_supplied_supabase_storage' : 'repairdesk_pos',
  },
}));

const actionCounts = reviewedRows.reduce((counts, product) => {
  counts[product.review_action] = (counts[product.review_action] ?? 0) + 1;
  return counts;
}, {});
const expectedCounts = { IMPORT: 135, EXCLUDE: 41, 'REVIEW MATCH': 2, 'KEEP EXISTING': 5 };
for (const [action, expected] of Object.entries(expectedCounts)) {
  if (actionCounts[action] !== expected) {
    throw new Error(`Expected ${expected} ${action} rows, found ${actionCounts[action] ?? 0}.`);
  }
}
if (products.length !== 137) throw new Error(`Expected 137 products to import, found ${products.length}.`);

const invalidProducts = products.filter((product) => (
  !product.sku
  || !product.slug
  || !product.name
  || !product.category_slug
  || !product.image_url
  || product.cost_price <= 0
  || product.retail_price <= 0
));
if (invalidProducts.length) {
  throw new Error(`Invalid import rows: ${invalidProducts.map((product) => product.source_external_id).join(', ')}`);
}
for (const [field, values] of [
  ['SKU', products.map((product) => product.sku)],
  ['slug', products.map((product) => product.slug)],
  ['source identity', products.map((product) => product.source_external_id)],
]) {
  const duplicates = values.filter((value, index) => values.indexOf(value) !== index);
  if (duplicates.length) throw new Error(`Duplicate ${field}: ${[...new Set(duplicates)].join(', ')}`);
}

const payload = {
  generated_at: new Date().toISOString(),
  source_workbook: path.basename(reviewWorkbookPath),
  source_system: 'repairdesk_computer_products',
  policy: {
    imported_actions: [...importActions],
    red_exclusions_skipped: actionCounts.EXCLUDE,
    existing_products_preserved: actionCounts['KEEP EXISTING'],
    database_categories_unchanged: true,
    starting_inventory: 0,
    online_visible: false,
    pos_visible: true,
    one_main_image_only: true,
  },
  action_counts: actionCounts,
  products,
};
await fs.writeFile(importJsonPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');

const sqlJson = JSON.stringify(products);
const sql = `begin;

create temporary table computer_product_import_input on commit drop as
select *
from jsonb_to_recordset($catalog$${sqlJson}$catalog$::jsonb) as x(
  sku text,
  slug text,
  name text,
  brand text,
  model text,
  category_slug text,
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
  if (select count(*) from computer_product_import_input) <> 137 then
    raise exception 'Computer product import expected 137 rows.';
  end if;

  if exists (
    select 1
    from computer_product_import_input input
    left join public.categories category on category.slug = input.category_slug
    where category.id is null
  ) then
    raise exception 'Computer product import references a missing category.';
  end if;

  if exists (
    select 1
    from computer_product_import_input input
    join public.products product on product.sku = input.sku
    where product.source_system is distinct from input.source_system
       or product.source_external_id is distinct from input.source_external_id
  ) then
    raise exception 'Computer product import found an SKU owned by another product.';
  end if;

  if exists (
    select 1
    from computer_product_import_input input
    join public.products product
      on product.source_system = input.source_system
     and product.source_external_id = input.source_external_id
    where product.sku <> input.sku
  ) then
    raise exception 'Computer product import found an existing source item with another SKU.';
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
  short_description,
  condition_label,
  compatibility,
  cost_price,
  retail_price,
  image_url,
  stock_quantity,
  is_visible,
  is_pos_visible,
  upc,
  source_system,
  source_external_id,
  source_category_path,
  import_status,
  source_metadata
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
from computer_product_import_input input
join public.categories category on category.slug = input.category_slug
on conflict (sku) do update
set slug = excluded.slug,
    name = excluded.name,
    brand = excluded.brand,
    model = excluded.model,
    category_id = excluded.category_id,
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
    source_category_path = excluded.source_category_path,
    import_status = excluded.import_status,
    source_metadata = excluded.source_metadata,
    updated_at = timezone('utc'::text, now())
where public.products.source_system = 'repairdesk_computer_products'
  and public.products.source_external_id = excluded.source_external_id;

do $$
begin
  if (
    select count(*)
    from public.products
    where source_system = 'repairdesk_computer_products'
      and import_status = 'active'
      and is_pos_visible
      and not is_visible
      and stock_quantity = 0
      and cost_price > 0
      and retail_price > 0
      and image_url is not null
      and btrim(image_url) <> ''
  ) <> 137 then
    raise exception 'Computer product post-import validation failed.';
  end if;
end
$$;

commit;

select
  category.name as database_category,
  count(*) as product_count,
  count(*) filter (where product.image_url is null or btrim(product.image_url) = '') as missing_images,
  count(*) filter (where product.stock_quantity <> 0) as nonzero_starting_stock
from public.products product
join public.categories category on category.id = product.category_id
where product.source_system = 'repairdesk_computer_products'
  and product.import_status = 'active'
group by category.name
order by category.name;
`;

await fs.writeFile(importSqlPath, sql, 'utf8');
console.log(JSON.stringify({
  reviewWorkbookPath,
  importJsonPath,
  importSqlPath,
  actionCounts,
  importCount: products.length,
  categoryCounts: products.reduce((counts, product) => {
    counts[product.category_slug] = (counts[product.category_slug] ?? 0) + 1;
    return counts;
  }, {}),
  ownerImageOverrides: [...imageOverrides.keys()],
}, null, 2));
