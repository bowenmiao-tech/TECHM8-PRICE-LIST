import fs from 'node:fs/promises';
import path from 'node:path';
import { FileBlob, SpreadsheetFile, Workbook } from '@oai/artifact-tool';

const workspaceRoot = 'D:/program/TECHM8 PRICE LIST';
const sourcePaths = [
  'E:/ontimefile/products (25).xlsx',
  'E:/ontimefile/products (26).xlsx',
];
const imageMapPath = `${workspaceRoot}/.codex-temp/audio-mount-import/repairdesk-images.json`;
const liveProductPaths = [
  `${workspaceRoot}/.codex-temp/audio-mount-import/live-products.json`,
  `${workspaceRoot}/.codex-temp/audio-mount-import/live-products-page2.json`,
];
const outputDir = `${workspaceRoot}/outputs/audio-holder-fan-catalog-20260812`;
const reviewWorkbookPath = `${outputDir}/TECHM8_Audio_Holder_Fan_Import_Review.xlsx`;
const importJsonPath = `${outputDir}/TECHM8_Audio_Holder_Fan_Import.json`;
const migrationPath = `${workspaceRoot}/supabase/website-migrations/20260812194702_import_repairdesk_audio_holder_fan_products.sql`;
const previewDir = `${workspaceRoot}/.codex-temp/audio-mount-import/previews`;

const text = (value) => String(value ?? '').trim();
const numberValue = (value) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};
const meaningfulCode = (value) => {
  const normalized = text(value);
  return normalized && normalized !== '77' ? normalized : '';
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

function ean13FromSourceId(sourceId, prefix = '2996') {
  const digits = text(sourceId).replace(/\D/g, '').slice(-8).padStart(8, '0');
  const body = `${prefix}${digits}`;
  let sum = 0;
  for (let index = 0; index < body.length; index += 1) {
    sum += Number(body[index]) * (index % 2 === 0 ? 1 : 3);
  }
  return `${body}${(10 - (sum % 10)) % 10}`;
}

function cleanProductName(value) {
  return text(value)
    .replace(/[\u2012\u2013\u2014\u2015]/g, '-')
    .replace(/[\u201c\u201d]/g, '"')
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/REMAX[｜|]/gi, 'Remax ')
    .replace(/^REMAX\b/i, 'Remax')
    .replace(/^Wekome\b/i, 'WEKOME')
    .replace(/\bType\s*-?\s*C\b/gi, 'USB-C')
    .replace(/\bLighting\b(?=\s+(?:Wired|Headphone|Earphone|Adapter))/gi, 'Lightning')
    .replace(/\bhead\s*phones?\b/gi, 'Headphones')
    .replace(/\s+/g, ' ')
    .trim();
}

const nameOverrides = new Map([
  ['9019', 'Remax G6 Wireless Gaming Earbuds'],
  ['9670', 'YAU44 Lightning to 3.5mm Audio Adapter'],
  ['11201', 'WEKOME Desktop Phone Holder'],
  ['10265', 'Remax F37 USB Fan'],
  ['10264', 'Remax RM-C60 Phone Stand'],
]);

function brandFromName(name) {
  if (/^remax\b/i.test(name)) return 'Remax';
  if (/^wekome\b/i.test(name)) return 'WEKOME';
  if (/^wk\b/i.test(name)) return 'WK';
  return 'OZTECHM8';
}

function categoryForProduct(product) {
  const sourceCategory = product.source_category;
  const search = product.name.toLowerCase();

  if (/headphones adapter/i.test(sourceCategory)) {
    return {
      database_category_slug: 'cable',
      pos_main_category: 'Cables & Adapters',
      pos_subcategory: 'Audio Cables & Adapters',
    };
  }
  if (/line headphones/i.test(sourceCategory)) {
    return {
      database_category_slug: 'wireless-and-bluetooth-headphones',
      pos_main_category: 'Audio',
      pos_subcategory: 'Wired Earphones & Headphones',
    };
  }
  if (/wireless headphones/i.test(sourceCategory)) {
    return {
      database_category_slug: 'wireless-and-bluetooth-headphones',
      pos_main_category: 'Audio',
      pos_subcategory: 'Wireless Earbuds & Headphones',
    };
  }
  if (/fan/i.test(search)) {
    return {
      database_category_slug: 'accessories',
      pos_main_category: 'Other Electronics',
      pos_subcategory: 'Personal Fans',
    };
  }
  if (/laptop stand/i.test(search)) {
    return {
      database_category_slug: 'holder-car-play-charger',
      pos_main_category: 'Mounts & Holders',
      pos_subcategory: 'Laptop Stands',
    };
  }
  if (/selfie|live stream|\b2m stand\b|\b8809\b/i.test(search)) {
    return {
      database_category_slug: 'holder-car-play-charger',
      pos_main_category: 'Mounts & Holders',
      pos_subcategory: 'Selfie Sticks & Live Stands',
    };
  }
  return {
    database_category_slug: 'holder-car-play-charger',
    pos_main_category: 'Mounts & Holders',
    pos_subcategory: 'Phone & Tablet Stands',
  };
}

function sourceSystemFor(product) {
  return product.source_file === 'products (25).xlsx'
    ? 'repairdesk_audio_products'
    : 'repairdesk_holder_fan_products';
}

async function readJson(filePath) {
  return JSON.parse((await fs.readFile(filePath, 'utf8')).replace(/^\uFEFF/, ''));
}

async function readSourceProducts() {
  const products = [];
  for (const sourcePath of sourcePaths) {
    const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(sourcePath));
    const sheet = workbook.worksheets.getItem('Sheet1');
    const rows = sheet.getUsedRange(true).values;
    const headers = rows[0].map(text);
    const column = Object.fromEntries(headers.map((header, index) => [header, index]));
    for (const row of rows.slice(2)) {
      const itemId = text(row[column['Item ID']]);
      if (!itemId) continue;
      products.push({
        source_file: path.basename(sourcePath),
        item_id: itemId,
        source_category: text(row[column.Category]),
        original_name: text(row[column['Item Name']]),
        source_sku: text(row[column.SKU]),
        source_upc: text(row[column.UPC]),
        source_stock: numberValue(row[column['On Hand Qty']]),
        source_cost: numberValue(row[column['Cost Price']]),
        retail_price: numberValue(row[column['Retail Price']]),
        source_pos_visible: text(row[column['Display On Point of Sale']]).toUpperCase() === 'YES',
      });
    }
  }
  return products;
}

function matchLiveProduct(product, liveProducts) {
  const checks = [
    (row) => text(row.source_external_id) === product.item_id,
    (row) => meaningfulCode(row.sku) && meaningfulCode(row.sku) === meaningfulCode(product.source_sku),
    (row) => meaningfulCode(row.barcode) && meaningfulCode(row.barcode) === meaningfulCode(product.source_upc),
    (row) => normalize(row.name) === normalize(product.original_name),
  ];
  for (const check of checks) {
    const matches = liveProducts.filter(check);
    if (matches.length === 1) return matches[0];
    if (matches.length > 1) throw new Error(`Ambiguous live product match for ${product.item_id}: ${product.original_name}`);
  }
  return null;
}

async function validateImageUrls(products) {
  const failures = [];
  const queue = [...products];
  const workers = Array.from({ length: 8 }, async () => {
    while (queue.length) {
      const product = queue.shift();
      try {
        const response = await fetch(product.image_url, { method: 'GET', redirect: 'follow' });
        if (!response.ok || !String(response.headers.get('content-type') || '').startsWith('image/')) {
          failures.push({ item_id: product.item_id, status: response.status, content_type: response.headers.get('content-type') });
        }
        await response.body?.cancel();
      } catch (error) {
        failures.push({ item_id: product.item_id, error: error.message });
      }
    }
  });
  await Promise.all(workers);
  if (failures.length) throw new Error(`Image validation failed: ${JSON.stringify(failures)}`);
}

function setSheetHeader(range) {
  range.format = {
    fill: '#087F68',
    font: { bold: true, color: '#FFFFFF' },
    verticalAlignment: 'center',
    wrapText: true,
  };
  range.format.rowHeight = 30;
}

function styleSheet(sheet, usedRange) {
  sheet.showGridLines = false;
  sheet.freezePanes.freezeRows(1);
  usedRange.format.font = { name: 'Aptos', size: 10, color: '#24343A' };
  usedRange.format.verticalAlignment = 'center';
}

await fs.mkdir(outputDir, { recursive: true });
await fs.mkdir(previewDir, { recursive: true });

const sourceProducts = await readSourceProducts();
const imageRows = await readJson(imageMapPath);
const liveProducts = (await Promise.all(liveProductPaths.map(readJson))).flatMap((payload) => payload.rows || []);
const imageByName = new Map(imageRows.map((row) => [normalize(row.name), row]));
const sourceUpcCounts = sourceProducts.reduce((counts, product) => {
  const upc = meaningfulCode(product.source_upc);
  if (upc) counts.set(upc, (counts.get(upc) || 0) + 1);
  return counts;
}, new Map());
const liveSkuOwners = new Map(liveProducts.map((product) => [text(product.sku), product]));

const reviewedProducts = sourceProducts.map((sourceProduct) => {
  const image = imageByName.get(normalize(sourceProduct.original_name));
  if (!image?.image_url) throw new Error(`Missing RepairDesk image for ${sourceProduct.item_id}: ${sourceProduct.original_name}`);
  const existing = matchLiveProduct(sourceProduct, liveProducts);
  const proposedName = nameOverrides.get(sourceProduct.item_id) || cleanProductName(sourceProduct.original_name);
  const category = categoryForProduct({ ...sourceProduct, name: proposedName });
  const sourceSku = meaningfulCode(sourceProduct.source_sku);
  const generatedSkuPrefix = category.pos_main_category === 'Audio' || category.pos_main_category === 'Cables & Adapters'
    ? 'TM8-AUD'
    : category.pos_subcategory === 'Personal Fans' ? 'TM8-FAN' : 'TM8-MNT';
  const sku = existing?.sku || sourceSku || `${generatedSkuPrefix}-${sourceProduct.item_id}`;
  const sourceUpc = meaningfulCode(sourceProduct.source_upc);
  const barcode = existing?.barcode
    || (sourceUpc && sourceUpcCounts.get(sourceUpc) === 1 ? sourceUpc : ean13FromSourceId(sourceProduct.item_id));
  const missingCost = sourceProduct.source_cost <= 0;
  const action = existing ? 'KEEP EXISTING' : missingCost ? 'NEEDS COST' : 'IMPORT';
  return {
    ...sourceProduct,
    ...category,
    action,
    existing_product_id: existing?.id || null,
    existing_source_system: existing?.source_system || null,
    sku,
    barcode,
    name: proposedName,
    brand: brandFromName(proposedName),
    image_url: existing?.image_url || image.image_url,
    repairdesk_product_id: image.repairdesk_product_id,
    inventory_index_id: image.inventory_index_id,
    final_cost: existing ? numberValue(existing.cost_price) : sourceProduct.source_cost,
    current_retail_price: existing ? numberValue(existing.sale_price) : sourceProduct.retail_price,
    source_system: sourceSystemFor(sourceProduct),
  };
});

if (reviewedProducts.length !== 49) throw new Error(`Expected 49 source products, found ${reviewedProducts.length}.`);
if (reviewedProducts.some((product) => !product.source_pos_visible)) throw new Error('All source products must remain POS-visible candidates.');
if (reviewedProducts.some((product) => !product.image_url)) throw new Error('Every reviewed product must have one image.');
if (reviewedProducts.some((product) => product.current_retail_price <= 0)) throw new Error('Every reviewed product must have a positive retail price.');

for (const [field, values] of [
  ['source identity', reviewedProducts.map((product) => `${product.source_system}:${product.item_id}`)],
  ['SKU', reviewedProducts.filter((product) => product.action !== 'KEEP EXISTING').map((product) => product.sku)],
]) {
  const duplicates = values.filter((value, index) => values.indexOf(value) !== index);
  if (duplicates.length) throw new Error(`Duplicate ${field}: ${[...new Set(duplicates)].join(', ')}`);
}
for (const product of reviewedProducts.filter((item) => item.action === 'IMPORT')) {
  const owner = liveSkuOwners.get(product.sku);
  if (owner) throw new Error(`New SKU ${product.sku} is already owned by live product ${owner.id}.`);
}

await validateImageUrls(reviewedProducts);

const readyProducts = reviewedProducts.filter((product) => product.action === 'IMPORT');
const existingProducts = reviewedProducts.filter((product) => product.action === 'KEEP EXISTING');
const costRequired = reviewedProducts.filter((product) => product.source_cost <= 0);
if (readyProducts.length !== 36) throw new Error(`Expected 36 new import products, found ${readyProducts.length}.`);
if (existingProducts.length !== 6) throw new Error(`Expected 6 existing products, found ${existingProducts.length}.`);
if (costRequired.length !== 8) throw new Error(`Expected 8 cost-required products, found ${costRequired.length}.`);

const importProducts = readyProducts.map((product) => ({
  sku: product.sku,
  slug: `repairdesk-accessory-${product.item_id}-${slugify(product.name)}`,
  name: product.name,
  brand: product.brand,
  model: null,
  database_category_slug: product.database_category_slug,
  pos_main_category: product.pos_main_category,
  pos_subcategory: product.pos_subcategory,
  short_description: product.pos_subcategory,
  condition_label: 'Brand New',
  compatibility: null,
  cost_price: product.source_cost,
  retail_price: product.source_retail_price || product.retail_price,
  image_url: product.image_url,
  stock_quantity: 0,
  is_visible: false,
  is_pos_visible: true,
  upc: product.barcode,
  source_system: product.source_system,
  source_external_id: product.item_id,
  source_category_path: product.source_category,
  import_status: 'active',
  source_metadata: {
    original_name: product.original_name,
    original_sku: product.source_sku,
    original_upc: product.source_upc,
    source_stock: product.source_stock,
    proposed_stock: 0,
    inventory_assignment: 'none',
    repairdesk_product_id: product.repairdesk_product_id,
    inventory_index_id: product.inventory_index_id,
    image_source: 'repairdesk_pos',
    pos_main_category: product.pos_main_category,
    pos_subcategory: product.pos_subcategory,
  },
}));

const existingAssignments = existingProducts.map((product) => ({
  product_id: product.existing_product_id,
  sku: product.sku,
  pos_main_category: product.pos_main_category,
  pos_subcategory: product.pos_subcategory,
}));

const payload = {
  generated_at: new Date().toISOString(),
  source_files: sourcePaths.map((sourcePath) => path.basename(sourcePath)),
  policy: {
    source_count: reviewedProducts.length,
    new_products_imported: readyProducts.length,
    existing_products_preserved: existingProducts.length,
    products_waiting_for_cost: costRequired.filter((product) => !product.existing_product_id).length,
    inventory_imported: false,
    all_store_inventory_starts_at_zero: true,
    online_visible: false,
    pos_visible: true,
    one_main_image_only: true,
  },
  products: importProducts,
  existing_category_assignments: existingAssignments,
  cost_required: costRequired.map((product) => ({
    item_id: product.item_id,
    existing_product_id: product.existing_product_id,
    sku: product.sku,
    name: product.name,
    source_category: product.source_category,
    pos_main_category: product.pos_main_category,
    pos_subcategory: product.pos_subcategory,
    current_cost: product.final_cost,
    retail_price: product.current_retail_price,
    image_url: product.image_url,
  })),
};
await fs.writeFile(importJsonPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');

const sql = `begin;

create temporary table audio_holder_fan_import_input on commit drop as
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

create temporary table audio_holder_fan_existing_assignments on commit drop as
select *
from jsonb_to_recordset($catalog$${JSON.stringify(existingAssignments)}$catalog$::jsonb) as x(
  product_id bigint,
  sku text,
  pos_main_category text,
  pos_subcategory text
);

do $$
begin
  if (select count(*) from audio_holder_fan_import_input) <> 36 then
    raise exception 'Audio/holder/fan import expected 36 new products.';
  end if;

  if (select count(*) from audio_holder_fan_existing_assignments) <> 6 then
    raise exception 'Audio/holder/fan import expected 6 existing category assignments.';
  end if;

  if exists (
    select 1
    from audio_holder_fan_import_input input
    left join public.categories category on category.slug = input.database_category_slug
    left join public.pos_category_taxonomy taxonomy
      on taxonomy.category_name = input.pos_main_category
     and taxonomy.subcategory_name = input.pos_subcategory
     and taxonomy.active
    where category.id is null or taxonomy.id is null
  ) then
    raise exception 'Audio/holder/fan import references a missing database or POS category.';
  end if;

  if exists (
    select 1
    from audio_holder_fan_import_input input
    where input.cost_price <= 0
       or input.retail_price <= 0
       or coalesce(btrim(input.image_url), '') = ''
  ) then
    raise exception 'Audio/holder/fan import contains an invalid cost, retail price, or image.';
  end if;

  if exists (
    select 1
    from audio_holder_fan_import_input input
    join public.products product on product.sku = input.sku
    where product.source_system is distinct from input.source_system
       or product.source_external_id is distinct from input.source_external_id
  ) then
    raise exception 'Audio/holder/fan import found an SKU owned by another product.';
  end if;

  if exists (
    select 1
    from audio_holder_fan_import_input input
    join public.products product
      on product.source_system = input.source_system
     and product.source_external_id = input.source_external_id
    where product.sku <> input.sku
  ) then
    raise exception 'Audio/holder/fan import found an existing source item with another SKU.';
  end if;

  if exists (
    select 1
    from audio_holder_fan_existing_assignments assignment
    left join public.products product
      on product.id = assignment.product_id
     and product.sku = assignment.sku
    where product.id is null
  ) then
    raise exception 'Audio/holder/fan import could not find an existing product assignment.';
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
from audio_holder_fan_import_input input
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

update public.products product
set pos_category_id = taxonomy.id,
    updated_at = timezone('utc'::text, now())
from audio_holder_fan_existing_assignments assignment
join public.pos_category_taxonomy taxonomy
  on taxonomy.category_name = assignment.pos_main_category
 and taxonomy.subcategory_name = assignment.pos_subcategory
 and taxonomy.active
where product.id = assignment.product_id
  and product.sku = assignment.sku;

do $$
begin
  if (
    select count(*)
    from public.products product
    where (product.source_system, product.source_external_id) in (
      select input.source_system, input.source_external_id
      from audio_holder_fan_import_input input
    )
      and product.import_status = 'active'
      and product.is_pos_visible
      and not product.is_visible
      and product.stock_quantity = 0
      and product.cost_price > 0
      and product.retail_price > 0
      and product.pos_category_id is not null
      and coalesce(btrim(product.image_url), '') <> ''
  ) <> 36 then
    raise exception 'Audio/holder/fan post-import validation failed for new products.';
  end if;

  if (
    select count(*)
    from audio_holder_fan_existing_assignments assignment
    join public.products product on product.id = assignment.product_id and product.sku = assignment.sku
    join public.pos_category_taxonomy taxonomy on taxonomy.id = product.pos_category_id
    where taxonomy.category_name = assignment.pos_main_category
      and taxonomy.subcategory_name = assignment.pos_subcategory
  ) <> 6 then
    raise exception 'Audio/holder/fan post-import validation failed for existing products.';
  end if;
end
$$;

commit;
`;
await fs.writeFile(migrationPath, sql, 'utf8');

const workbook = Workbook.create();
const summarySheet = workbook.worksheets.add('Import Summary');
const readySheet = workbook.worksheets.add('Ready Products');
const existingSheet = workbook.worksheets.add('Existing Products');
const costSheet = workbook.worksheets.add('Cost Required');

summarySheet.showGridLines = false;
summarySheet.getRange('A1:H1').merge();
summarySheet.getRange('A1').values = [['TECHM8 Audio, Holder & Fan POS Import Review']];
summarySheet.getRange('A1:H1').format = {
  fill: '#087F68',
  font: { name: 'Aptos Display', size: 18, bold: true, color: '#FFFFFF' },
  verticalAlignment: 'center',
};
summarySheet.getRange('A1:H1').format.rowHeight = 44;
summarySheet.getRange('A3:B8').values = [
  ['Review result', 'Count'],
  ['Source products', null],
  ['New products ready and imported', null],
  ['Existing products preserved', null],
  ['Products requiring cost', null],
  ['Products with validated main image', null],
];
summarySheet.getRange('B4').formulas = [["=COUNTA('Ready Products'!A2:A37)+COUNTA('Existing Products'!A2:A7)+COUNTA('Cost Required'!A2:A9)-COUNTIF('Cost Required'!C2:C9,\"Existing\")"]];
summarySheet.getRange('B5').formulas = [["=COUNTA('Ready Products'!A2:A37)"]];
summarySheet.getRange('B6').formulas = [["=COUNTA('Existing Products'!A2:A7)"]];
summarySheet.getRange('B7').formulas = [["=COUNTA('Cost Required'!A2:A9)"]];
summarySheet.getRange('B8').formulas = [['=B4']];
setSheetHeader(summarySheet.getRange('A3:B3'));
summarySheet.getRange('A4:A8').format.font = { bold: true };
summarySheet.getRange('B4:B8').format.numberFormat = '#,##0';
summarySheet.getRange('A10:H10').merge();
summarySheet.getRange('A10').values = [['Import rules']];
summarySheet.getRange('A10:H10').format = { fill: '#DDF3EC', font: { bold: true, color: '#075F50' } };
summarySheet.getRange('A11:H15').merge(true);
summarySheet.getRange('A11:A15').values = [
  ['All new store inventories start at 0. Source stock is retained only as audit metadata.'],
  ['Products with zero cost are not newly enabled until the owner supplies a valid cost.'],
  ['Existing products are not duplicated; only their POS category assignment is updated.'],
  ['All products use one main image captured from the current RepairDesk POS.'],
  ['Products are visible in POS and remain hidden from the online storefront.'],
];
summarySheet.getRange('A11:H15').format.wrapText = true;
summarySheet.getRange('A11:H15').format.fill = '#F5F8F8';
summarySheet.getRange('A3:B8').format.borders = { preset: 'outside', style: 'thin', color: '#C9D7D5' };
summarySheet.getRange('A1:H15').format.font = { name: 'Aptos', size: 10, color: '#24343A' };
summarySheet.getRange('A1:H1').format.font = { name: 'Aptos Display', size: 18, bold: true, color: '#FFFFFF' };
summarySheet.getRange('A:A').format.columnWidth = 38;
summarySheet.getRange('B:B').format.columnWidth = 16;
summarySheet.getRange('C:H').format.columnWidth = 12;

const readyHeaders = ['Item ID', 'POS SKU', 'Product Name', 'Brand', 'Source Category', 'POS Main Category', 'POS Subcategory', 'Cost', 'Retail', 'Barcode', 'Image URL'];
readySheet.getRangeByIndexes(0, 0, 1, readyHeaders.length).values = [readyHeaders];
readySheet.getRangeByIndexes(1, 0, readyProducts.length, readyHeaders.length).values = readyProducts.map((product) => [
  product.item_id,
  product.sku,
  product.name,
  product.brand,
  product.source_category,
  product.pos_main_category,
  product.pos_subcategory,
  product.source_cost,
  product.current_retail_price,
  product.barcode,
  product.image_url,
]);
styleSheet(readySheet, readySheet.getRangeByIndexes(0, 0, readyProducts.length + 1, readyHeaders.length));
setSheetHeader(readySheet.getRangeByIndexes(0, 0, 1, readyHeaders.length));
readySheet.getRange(`H2:I${readyProducts.length + 1}`).format.numberFormat = '$#,##0.00';
readySheet.getRange(`A1:K${readyProducts.length + 1}`).format.borders = { preset: 'outside', style: 'thin', color: '#D5DFDD' };
readySheet.getRange('A:A').format.columnWidth = 11;
readySheet.getRange('B:B').format.columnWidth = 20;
readySheet.getRange('C:C').format.columnWidth = 44;
readySheet.getRange('D:D').format.columnWidth = 14;
readySheet.getRange('E:G').format.columnWidth = 27;
readySheet.getRange('H:J').format.columnWidth = 14;
readySheet.getRange('K:K').format.columnWidth = 58;
readySheet.tables.add(`A1:K${readyProducts.length + 1}`, true, 'ReadyAudioHolderProducts').style = 'TableStyleMedium4';

const existingHeaders = ['Item ID', 'Current SKU', 'Current Product Name', 'Current Cost', 'Current Retail', 'POS Main Category', 'POS Subcategory', 'Current Image URL'];
existingSheet.getRangeByIndexes(0, 0, 1, existingHeaders.length).values = [existingHeaders];
existingSheet.getRangeByIndexes(1, 0, existingProducts.length, existingHeaders.length).values = existingProducts.map((product) => [
  product.item_id,
  product.sku,
  product.name,
  product.final_cost,
  product.current_retail_price,
  product.pos_main_category,
  product.pos_subcategory,
  product.image_url,
]);
styleSheet(existingSheet, existingSheet.getRangeByIndexes(0, 0, existingProducts.length + 1, existingHeaders.length));
setSheetHeader(existingSheet.getRangeByIndexes(0, 0, 1, existingHeaders.length));
existingSheet.getRange(`D2:E${existingProducts.length + 1}`).format.numberFormat = '$#,##0.00';
existingSheet.getRange('A:A').format.columnWidth = 11;
existingSheet.getRange('B:B').format.columnWidth = 20;
existingSheet.getRange('C:C').format.columnWidth = 46;
existingSheet.getRange('D:E').format.columnWidth = 15;
existingSheet.getRange('F:G').format.columnWidth = 28;
existingSheet.getRange('H:H').format.columnWidth = 58;
existingSheet.tables.add(`A1:H${existingProducts.length + 1}`, true, 'ExistingAudioProducts').style = 'TableStyleMedium4';

const costHeaders = ['Item ID', 'Product Name', 'Record Type', 'Source Category', 'POS Category', 'Current Cost', 'Final Cost (INPUT)', 'Retail Price', 'Image URL', 'Notes'];
costSheet.getRangeByIndexes(0, 0, 1, costHeaders.length).values = [costHeaders];
costSheet.getRangeByIndexes(1, 0, costRequired.length, costHeaders.length).values = costRequired.map((product) => [
  product.item_id,
  product.name,
  product.existing_product_id ? 'Existing' : 'New - waiting',
  product.source_category,
  `${product.pos_main_category} > ${product.pos_subcategory}`,
  product.final_cost,
  null,
  product.current_retail_price,
  product.image_url,
  product.existing_product_id ? 'Already in POS; cost is currently 0.' : 'Will be imported after a valid cost is supplied.',
]);
styleSheet(costSheet, costSheet.getRangeByIndexes(0, 0, costRequired.length + 1, costHeaders.length));
setSheetHeader(costSheet.getRangeByIndexes(0, 0, 1, costHeaders.length));
costSheet.getRange(`F2:H${costRequired.length + 1}`).format.numberFormat = '$#,##0.00';
costSheet.getRange(`G2:G${costRequired.length + 1}`).format.fill = '#FFF2CC';
costSheet.getRange(`G2:G${costRequired.length + 1}`).format.font = { bold: true, color: '#7A4B00' };
costSheet.getRange(`G2:G${costRequired.length + 1}`).conditionalFormats.add('cellIs', {
  operator: 'lessThanOrEqual',
  formula: 0,
  format: { fill: '#FDE9E7', font: { color: '#B42318', bold: true } },
});
costSheet.getRange('A:A').format.columnWidth = 11;
costSheet.getRange('B:B').format.columnWidth = 44;
costSheet.getRange('C:C').format.columnWidth = 18;
costSheet.getRange('D:E').format.columnWidth = 34;
costSheet.getRange('F:H').format.columnWidth = 17;
costSheet.getRange('I:I').format.columnWidth = 58;
costSheet.getRange('J:J').format.columnWidth = 42;
costSheet.getRange(`A1:J${costRequired.length + 1}`).format.wrapText = true;
costSheet.tables.add(`A1:J${costRequired.length + 1}`, true, 'AudioHolderCostReview').style = 'TableStyleMedium4';

const summaryPreview = await workbook.render({ sheetName: 'Import Summary', range: 'A1:H15', scale: 1.5, format: 'png' });
await fs.writeFile(`${previewDir}/summary.png`, new Uint8Array(await summaryPreview.arrayBuffer()));
const costPreview = await workbook.render({ sheetName: 'Cost Required', range: `A1:J${costRequired.length + 1}`, scale: 1.25, format: 'png' });
await fs.writeFile(`${previewDir}/cost-required.png`, new Uint8Array(await costPreview.arrayBuffer()));

const exportBlob = await SpreadsheetFile.exportXlsx(workbook);
await exportBlob.save(reviewWorkbookPath);

const inspect = await workbook.inspect({
  kind: 'table',
  range: `Cost Required!A1:J${costRequired.length + 1}`,
  include: 'values,formulas',
  tableMaxRows: 12,
  tableMaxCols: 10,
  maxChars: 8000,
});
const formulaErrors = await workbook.inspect({
  kind: 'match',
  searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A',
  options: { useRegex: true, maxResults: 100 },
  summary: 'final formula error scan',
  maxChars: 3000,
});

console.log(JSON.stringify({
  source_products: reviewedProducts.length,
  new_products_ready: readyProducts.length,
  existing_products_preserved: existingProducts.length,
  cost_required: costRequired.length,
  image_urls_validated: reviewedProducts.length,
  review_workbook: reviewWorkbookPath,
  migration: migrationPath,
  cost_sheet_inspect: inspect.ndjson,
  formula_errors: formulaErrors.ndjson,
}, null, 2));
