import fs from 'node:fs/promises';
import path from 'node:path';
import { FileBlob, SpreadsheetFile } from '@oai/artifact-tool';

const workspaceRoot = 'D:/program/TECHM8 PRICE LIST';
const sourcePath = 'E:/ontimefile/products (28).xlsx';
const reviewPath = `${workspaceRoot}/outputs/product-28-catalog-review-20260813/TECHM8_Products_28_Review.xlsx`;
const imageMapPath = `${workspaceRoot}/.codex-temp/products-28-import/repairdesk-images.json`;
const outputDir = `${workspaceRoot}/outputs/product-28-catalog-review-20260813`;
const importJsonPath = `${outputDir}/TECHM8_Products_28_Final_Import.json`;
const migrationPath = `${workspaceRoot}/supabase/website-migrations/20260814004500_import_repairdesk_misc_accessory_catalog.sql`;

const text = (value) => String(value ?? '').trim();
const numberValue = (value) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};
const slugify = (value) => text(value)
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, '-')
  .replace(/^-+|-+$/g, '')
  .slice(0, 90);

function ean13FromSourceId(sourceId) {
  const digits = text(sourceId).replace(/\D/g, '').slice(-8).padStart(8, '0');
  const body = `2996${digits}`;
  let sum = 0;
  for (let index = 0; index < body.length; index += 1) {
    sum += Number(body[index]) * (index % 2 === 0 ? 1 : 3);
  }
  return `${body}${(10 - (sum % 10)) % 10}`;
}

const productPlan = {
  '10888': ['MagSafe Stand Wallet - Black', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', null, 'Black'],
  '10857': ['MagSafe Silicone Phone Grip - Purple', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-SILICONE-GRIP', 'Purple'],
  '10856': ['MagSafe Silicone Phone Grip - Pink', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-SILICONE-GRIP', 'Pink'],
  '10855': ['MagSafe Silicone Phone Grip - Sky Blue', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-SILICONE-GRIP', 'Sky Blue'],
  '10854': ['MagSafe Silicone Phone Grip - Black', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-SILICONE-GRIP', 'Black'],
  '10853': ['MagSafe Multi-Wallet - Brown', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-MULTI-WALLET', 'Brown'],
  '10852': ['MagSafe Multi-Wallet - Black', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-MULTI-WALLET', 'Black'],
  '10851': ['MagSafe Multi-Wallet - Grey', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-MULTI-WALLET', 'Grey'],
  '10322': ['CTF Earbuds Pouch', 'CTF', 'accessories', 'Other Electronics', 'Earbud Cases', null, null],
  '10321': ['CTF Car Holder & Grip MagSafe Stand', 'CTF', 'accessories', 'Uncategorized', 'Uncategorized', null, null],
  '8974': ['Card Strap Holder', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', null, null],
  '8633': ['TechM8 Small Bag', 'TechM8', 'accessories', 'Uncategorized', 'Uncategorized', null, null],
  '8632': ['TechM8 Big Bag', 'TechM8', 'accessories', 'Uncategorized', 'Uncategorized', null, null],
  '8483': ['Drone Map', 'OZTECHM8', 'accessories', 'Other Electronics', 'Drones & Accessories', null, null],
  '8416': ['Special Order', 'OZTECHM8', 'accessories', 'Uncategorized', 'Uncategorized', null, null],
  '8412': ['Phone Strap Adapter Patch', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', null, null],
  '8411': ['Phone Lanyard Strap', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', null, null],
  '8263': ['FIMI X8 Mini V2 Drone', 'FIMI', 'accessories', 'Other Electronics', 'Drones & Accessories', null, null],
  '8041': ['MagSafe Card Wallet - Navy', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-CARD-WALLET', 'Navy'],
  '8040': ['MagSafe Card Wallet - Orange', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-CARD-WALLET', 'Orange'],
  '8039': ['MagSafe Card Wallet - Red', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-CARD-WALLET', 'Red'],
  '8038': ['MagSafe Card Wallet - Green', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-CARD-WALLET', 'Green'],
  '8036': ['MagSafe Card Wallet - Brown', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-MAGSAFE-CARD-WALLET', 'Brown'],
  '7763': ['Phone Tag', 'OZTECHM8', 'accessories', 'Uncategorized', 'Uncategorized', null, null],
  '7148': ['Adhesive Silicone Card Holder - Black', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-ADHESIVE-CARD-HOLDER', 'Black'],
  '7147': ['Adhesive Silicone Card Holder - Green', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-ADHESIVE-CARD-HOLDER', 'Green'],
  '7146': ['Adhesive Silicone Card Holder - Yellow', 'OZTECHM8', 'holder-car-play-charger', 'Mounts & Holders', 'Wallets, Card Holders & Grips', 'TM8-GRP-MISC-ADHESIVE-CARD-HOLDER', 'Yellow'],
  '6769': ['Shop Credit', 'OZTECHM8', 'accessories', 'Uncategorized', 'Uncategorized', null, null],
  '6062': ['RGB Digital Clock', 'OZTECHM8', 'accessories', 'Other Electronics', 'Lighting & Clocks', null, null],
  '6061': ['Music-Reactive RGB Light', 'OZTECHM8', 'accessories', 'Other Electronics', 'Lighting & Clocks', null, null],
  '6021': ['Special', 'OZTECHM8', 'accessories', 'Uncategorized', 'Uncategorized', null, null],
  '5995': ['Paragon Stylus Pen', 'Paragon', 'accessories', 'Other Electronics', 'Other Electronics', null, null],
  '5957': ['Miscellaneous & Other Products', 'OZTECHM8', 'accessories', 'Uncategorized', 'Uncategorized', null, null],
  '5934': ['$2 SIM', 'OZTECHM8', 'accessories', 'Other Electronics', 'Other Electronics', null, null],
};

const groupPlan = {
  'TM8-GRP-MISC-MAGSAFE-SILICONE-GRIP': ['MagSafe Silicone Phone Grip', '10854'],
  'TM8-GRP-MISC-MAGSAFE-MULTI-WALLET': ['MagSafe Multi-Wallet', '10852'],
  'TM8-GRP-MISC-MAGSAFE-CARD-WALLET': ['MagSafe Card Wallet', '8041'],
  'TM8-GRP-MISC-ADHESIVE-CARD-HOLDER': ['Adhesive Silicone Card Holder', '7148'],
};

const skuOverrides = {
  '10322': 'TM8-MISC-10322',
  '10321': 'TM8-MISC-10321',
  '6021': 'TM8-MISC-6021',
  '5957': 'TM8-MISC-5957',
};

async function readSheet(filePath, sheetName = 'Sheet1') {
  const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(filePath));
  const sheet = workbook.worksheets.getItem(sheetName);
  return sheet.getUsedRange(true).values;
}

function recordsFromRows(rows, headerRow = 0, dataStart = 2) {
  const headers = rows[headerRow].map(text);
  return rows.slice(dataStart).filter((row) => text(row[0])).map((row) => (
    Object.fromEntries(headers.map((header, index) => [header, row[index]]))
  ));
}

async function validateImageUrls(products) {
  const failures = [];
  const queue = [...products];
  const workers = Array.from({ length: 8 }, async () => {
    while (queue.length) {
      const product = queue.shift();
      try {
        const response = await fetch(product.image_url, { method: 'GET', redirect: 'follow' });
        const contentType = String(response.headers.get('content-type') || '');
        if (!response.ok || !contentType.startsWith('image/')) {
          failures.push({ source_external_id: product.source_external_id, status: response.status, content_type: contentType });
        }
        await response.body?.cancel();
      } catch (error) {
        failures.push({ source_external_id: product.source_external_id, error: error.message });
      }
    }
  });
  await Promise.all(workers);
  if (failures.length) throw new Error(`Image validation failed: ${JSON.stringify(failures)}`);
}

await fs.mkdir(outputDir, { recursive: true });

const sourceRecords = recordsFromRows(await readSheet(sourcePath));
const reviewRows = await readSheet(reviewPath, 'Product Review');
const reviewRecords = recordsFromRows(reviewRows, 0, 1);
const images = JSON.parse(await fs.readFile(imageMapPath, 'utf8'));
const reviewById = new Map(reviewRecords.map((row) => [text(row['Item ID']), row]));
const imageById = new Map(images.map((row) => [text(row.id), row]));

const products = sourceRecords.map((source) => {
  const sourceExternalId = text(source['Item ID']);
  const review = reviewById.get(sourceExternalId);
  const image = imageById.get(sourceExternalId);
  const plan = productPlan[sourceExternalId];
  if (!review || !image?.image_url || !plan) throw new Error(`Incomplete import plan for ${sourceExternalId}`);

  const [name, brand, databaseCategorySlug, posMainCategory, posSubcategory, productGroupCode, variantColor] = plan;
  const finalCost = numberValue(review['Final Cost']);
  const finalRetail = numberValue(review['Final Retail']);
  const sourceSku = text(source.SKU);
  const sku = skuOverrides[sourceExternalId] || sourceSku;

  return {
    sku,
    slug: `repairdesk-misc-${sourceExternalId}-${slugify(name)}`,
    name,
    brand,
    model: productGroupCode ? groupPlan[productGroupCode][0] : null,
    database_category_slug: databaseCategorySlug,
    pos_main_category: posMainCategory,
    pos_subcategory: posSubcategory,
    short_description: posSubcategory,
    condition_label: 'Brand New',
    compatibility: null,
    cost_price: finalCost,
    retail_price: finalRetail,
    image_url: image.image_url,
    stock_quantity: 0,
    is_visible: false,
    is_pos_visible: true,
    upc: ean13FromSourceId(sourceExternalId),
    product_group_code: productGroupCode,
    variant_name: variantColor,
    variant_color: variantColor,
    source_system: 'repairdesk_misc_accessories',
    source_external_id: sourceExternalId,
    source_category_path: text(source.Category),
    import_status: 'active',
    source_metadata: {
      original_name: text(source['Item Name']),
      original_sku: sourceSku,
      original_upc: text(source.UPC),
      source_stock: numberValue(source['On Hand Qty']),
      proposed_stock: 0,
      inventory_assignment: 'none',
      owner_confirmed_cost: finalCost,
      owner_confirmed_retail: finalRetail,
      owner_confirmed_at: '2026-08-14',
      image_source: 'repairdesk_pos',
      pos_main_category: posMainCategory,
      pos_subcategory: posSubcategory,
    },
  };
});

if (products.length !== 34) throw new Error(`Expected 34 products, received ${products.length}`);
if (new Set(products.map((product) => product.sku)).size !== products.length) throw new Error('Generated SKU values are not unique');
if (new Set(products.map((product) => product.upc)).size !== products.length) throw new Error('Generated barcode values are not unique');
if (new Set(products.map((product) => product.source_external_id)).size !== products.length) throw new Error('Source item IDs are not unique');

const zeroCostIds = products.filter((product) => product.cost_price === 0).map((product) => product.source_external_id).sort();
const zeroRetailIds = products.filter((product) => product.retail_price === 0).map((product) => product.source_external_id).sort();
if (JSON.stringify(zeroCostIds) !== JSON.stringify(['5934', '5957', '6769', '8416'])) {
  throw new Error(`Unexpected zero-cost products: ${JSON.stringify(zeroCostIds)}`);
}
if (JSON.stringify(zeroRetailIds) !== JSON.stringify(['5957', '6769', '8416', '8632', '8633'])) {
  throw new Error(`Unexpected zero-retail products: ${JSON.stringify(zeroRetailIds)}`);
}

await validateImageUrls(products);

const productById = new Map(products.map((product) => [product.source_external_id, product]));
const groups = Object.entries(groupPlan).map(([code, [name, mainImageSourceId]]) => {
  const mainProduct = productById.get(mainImageSourceId);
  return {
    code,
    slug: slugify(code),
    name,
    database_category_slug: mainProduct.database_category_slug,
    pos_main_category: mainProduct.pos_main_category,
    pos_subcategory: mainProduct.pos_subcategory,
    product_family: 'phone_accessory',
    main_image_url: mainProduct.image_url,
  };
});

for (const group of groups) {
  const variants = products.filter((product) => product.product_group_code === group.code);
  if (variants.length < 2 || variants.some((product) => !product.variant_name || !product.variant_color)) {
    throw new Error(`Invalid product group ${group.code}`);
  }
}

const json = (value) => JSON.stringify(value).replaceAll('$catalog$', '$ catalog $');
const productJson = json(products);
const groupJson = json(groups);

const migration = `begin;

insert into public.pos_category_taxonomy (
  category_name, subcategory_name, category_sort, subcategory_sort, active
)
values ('Uncategorized', 'Uncategorized', 110, 10, true)
on conflict (category_name, subcategory_name) do update
set category_sort = excluded.category_sort,
    subcategory_sort = excluded.subcategory_sort,
    active = true,
    updated_at = now();

create temporary table misc_accessory_group_input on commit drop as
select *
from jsonb_to_recordset($groups$${groupJson}$groups$::jsonb) as x(
  code text,
  slug text,
  name text,
  database_category_slug text,
  pos_main_category text,
  pos_subcategory text,
  product_family text,
  main_image_url text
);

create temporary table misc_accessory_product_input on commit drop as
select *
from jsonb_to_recordset($catalog$${productJson}$catalog$::jsonb) as x(
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
  product_group_code text,
  variant_name text,
  variant_color text,
  source_system text,
  source_external_id text,
  source_category_path text,
  import_status text,
  source_metadata jsonb
);

do $$
begin
  if (select count(*) from misc_accessory_product_input) <> 34 then
    raise exception 'Expected 34 miscellaneous accessory products.';
  end if;

  if (select count(*) from misc_accessory_group_input) <> 4 then
    raise exception 'Expected four grouped accessory styles.';
  end if;

  if exists (
    select 1
    from misc_accessory_product_input input
    left join public.categories category on category.slug = input.database_category_slug
    left join public.pos_category_taxonomy taxonomy
      on taxonomy.category_name = input.pos_main_category
     and taxonomy.subcategory_name = input.pos_subcategory
     and taxonomy.active
    where category.id is null or taxonomy.id is null
  ) then
    raise exception 'An import product references a missing category.';
  end if;

  if exists (
    select 1 from misc_accessory_product_input input
    where input.cost_price < 0
       or input.retail_price < 0
       or input.stock_quantity <> 0
       or input.is_visible
       or not input.is_pos_visible
       or coalesce(btrim(input.image_url), '') = ''
  ) then
    raise exception 'An import product has an invalid price, stock, visibility, or image.';
  end if;

  if exists (
    select 1 from misc_accessory_product_input input
    where input.cost_price = 0
      and input.source_external_id not in ('8416', '6769', '5957', '5934')
  ) or exists (
    select 1 from misc_accessory_product_input input
    where input.retail_price = 0
      and input.source_external_id not in ('8633', '8632', '8416', '6769', '5957')
  ) then
    raise exception 'Unexpected zero price found in import products.';
  end if;

  if exists (
    select input.sku from misc_accessory_product_input input group by input.sku having count(*) > 1
  ) or exists (
    select input.upc from misc_accessory_product_input input group by input.upc having count(*) > 1
  ) or exists (
    select input.source_external_id
    from misc_accessory_product_input input
    group by input.source_system, input.source_external_id
    having count(*) > 1
  ) then
    raise exception 'The import contains a duplicate SKU, barcode, or source item.';
  end if;

  if exists (
    select 1
    from misc_accessory_product_input input
    join public.products existing on existing.sku = input.sku
    where existing.source_system is distinct from input.source_system
       or existing.source_external_id is distinct from input.source_external_id
  ) or exists (
    select 1
    from misc_accessory_product_input input
    join public.products existing on existing.upc = input.upc
    where existing.source_system is distinct from input.source_system
       or existing.source_external_id is distinct from input.source_external_id
  ) then
    raise exception 'An import SKU or barcode is owned by another product.';
  end if;

  if exists (
    select 1
    from misc_accessory_product_input input
    join public.products existing
      on existing.source_system = input.source_system
     and existing.source_external_id = input.source_external_id
    where existing.sku <> input.sku
  ) then
    raise exception 'An import source item already has another SKU.';
  end if;
end
$$;

insert into public.product_groups (
  code, slug, name, category_id, product_family, main_image_url,
  status, is_pos_visible, is_visible, pos_category_id
)
select
  input.code,
  input.slug,
  input.name,
  category.id,
  input.product_family,
  input.main_image_url,
  'active',
  true,
  false,
  taxonomy.id
from misc_accessory_group_input input
join public.categories category on category.slug = input.database_category_slug
join public.pos_category_taxonomy taxonomy
  on taxonomy.category_name = input.pos_main_category
 and taxonomy.subcategory_name = input.pos_subcategory
 and taxonomy.active
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
    updated_at = timezone('utc'::text, now())
where public.product_groups.product_family = 'phone_accessory';

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
  product_group.id,
  input.variant_name,
  input.variant_color,
  input.source_system,
  input.source_external_id,
  input.source_category_path,
  input.import_status,
  input.source_metadata
from misc_accessory_product_input input
join public.categories category on category.slug = input.database_category_slug
join public.pos_category_taxonomy taxonomy
  on taxonomy.category_name = input.pos_main_category
 and taxonomy.subcategory_name = input.pos_subcategory
 and taxonomy.active
left join public.product_groups product_group on product_group.code = input.product_group_code
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
    join public.pos_category_taxonomy taxonomy on taxonomy.id = product.pos_category_id
    where product.source_system = 'repairdesk_misc_accessories'
      and product.source_external_id in (select source_external_id from misc_accessory_product_input)
      and product.import_status = 'active'
      and product.is_pos_visible
      and not product.is_visible
      and product.stock_quantity = 0
      and coalesce(btrim(product.image_url), '') <> ''
      and taxonomy.active
  ) <> 34 then
    raise exception 'Miscellaneous accessory product validation failed.';
  end if;

  if (
    select count(*)
    from public.product_groups product_group
    where product_group.code in (select code from misc_accessory_group_input)
      and product_group.product_family = 'phone_accessory'
      and product_group.status = 'active'
      and product_group.is_pos_visible
      and not product_group.is_visible
  ) <> 4 then
    raise exception 'Miscellaneous accessory group validation failed.';
  end if;

  if exists (
    select 1
    from public.product_store_inventory inventory
    join public.products product on product.id = inventory.product_id
    where product.source_system = 'repairdesk_misc_accessories'
      and product.source_external_id in (select source_external_id from misc_accessory_product_input)
  ) then
    raise exception 'New products must not begin with store inventory.';
  end if;
end
$$;

commit;
`;

await fs.writeFile(importJsonPath, `${JSON.stringify({ products, groups }, null, 2)}\n`);
await fs.writeFile(migrationPath, migration);

console.log(JSON.stringify({
  sourcePath,
  reviewPath,
  importJsonPath,
  migrationPath,
  products: products.length,
  groups: groups.length,
  groupedProducts: products.filter((product) => product.product_group_code).length,
  uncategorizedProducts: products.filter((product) => product.pos_main_category === 'Uncategorized').length,
  zeroCostIds,
  zeroRetailIds,
}, null, 2));
