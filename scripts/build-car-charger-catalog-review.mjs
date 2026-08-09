import fs from 'node:fs/promises';
import { FileBlob, SpreadsheetFile, Workbook } from '@oai/artifact-tool';

const sourcePath = process.argv[2];
if (!sourcePath) throw new Error('Pass the RepairDesk product workbook path as the first argument.');

const outputDir = 'D:/program/TECHM8 PRICE LIST/outputs/car-charger-catalog-rebuild';
const previewDir = 'C:/Users/User/AppData/Local/Temp/codex-car-charger-catalog/previews';
const imageMapPath = `${outputDir}/RepairDesk_Car_Charger_Images.json`;
const existingSnapshotPath = `${outputDir}/Existing_Car_Chargers_Snapshot.json`;
const reviewWorkbookPath = `${outputDir}/TECHM8_Car_Chargers_Import_Review.xlsx`;
const importJsonPath = `${outputDir}/TECHM8_Car_Chargers_Draft_Import.json`;
const importSqlPath = `${outputDir}/TECHM8_Car_Chargers_Draft_Import.sql`;

await fs.mkdir(outputDir, { recursive: true });
await fs.mkdir(previewDir, { recursive: true });

const sourceWorkbook = await SpreadsheetFile.importXlsx(await FileBlob.load(sourcePath));
const sourceSheet = sourceWorkbook.worksheets.getItem('Sheet1');
const sourceValues = sourceSheet.getUsedRange(true).values;
const sourceRows = sourceValues.slice(2).filter((row) => String(row[0] ?? '').trim());
const imageRows = JSON.parse(await fs.readFile(imageMapPath, 'utf8'));
const existingProducts = JSON.parse(await fs.readFile(existingSnapshotPath, 'utf8'));

const normalizeKey = (value) => String(value ?? '').trim().toLowerCase().replace(/\s+/g, ' ');
const numberValue = (value) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};
const slugify = (value) => String(value ?? '')
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, '-')
  .replace(/^-+|-+$/g, '')
  .slice(0, 120);
const displayIdentifier = (value) => String(value ?? '').replace(/\s+/g, '').replace(/(.{4})(?=.)/g, '$1 ');

function ean13FromSourceId(sourceId) {
  const digits = String(sourceId ?? '').replace(/\D/g, '').slice(-8).padStart(8, '0');
  const body = `2986${digits}`;
  let sum = 0;
  for (let index = 0; index < body.length; index += 1) {
    sum += Number(body[index]) * (index % 2 === 0 ? 1 : 3);
  }
  return `${body}${(10 - (sum % 10)) % 10}`;
}

const catalogRules = new Map([
  ['9322', {
    name: 'K28 USB-A + USB-C Car Charger',
    groupCode: 'TM8-GRP-CCH-K28',
    groupName: 'K28 USB-A + USB-C Car Charger',
    family: 'USB-A + USB-C Car Charger',
    model: 'K28',
    color: null,
  }],
  ['7588', {
    name: '35W USB-C + Dual USB-A Car Charger - White',
    groupCode: 'TM8-GRP-CCH-35W-3PORT',
    groupName: '35W USB-C + Dual USB-A Car Charger',
    family: '35W 3-Port Car Charger',
    model: '35W 3-Port',
    color: 'White',
  }],
  ['7152', {
    name: 'Dual Socket + USB Car Charger',
    groupCode: 'TM8-GRP-CCH-DUAL-SOCKET',
    groupName: 'Dual Socket + USB Car Charger',
    family: 'Dual Socket Car Charger',
    model: 'Dual Socket + USB',
    color: null,
  }],
  ['7151', {
    name: '45W Dual USB-C Car Charger - Black',
    groupCode: 'TM8-GRP-CCH-45W-2C',
    groupName: '45W Dual USB-C Car Charger',
    family: '45W Dual USB-C Car Charger',
    model: '45W Dual USB-C',
    color: 'Black',
  }],
  ['7150', {
    name: '45W Dual USB-C Car Charger - White',
    groupCode: 'TM8-GRP-CCH-45W-2C',
    groupName: '45W Dual USB-C Car Charger',
    family: '45W Dual USB-C Car Charger',
    model: '45W Dual USB-C',
    color: 'White',
  }],
  ['6575', {
    name: '35W USB-C + Dual USB-A Car Charger - Black',
    groupCode: 'TM8-GRP-CCH-35W-3PORT',
    groupName: '35W USB-C + Dual USB-A Car Charger',
    family: '35W 3-Port Car Charger',
    model: '35W 3-Port',
    color: 'Black',
  }],
]);

const imageByName = new Map(imageRows.map((row) => [normalizeKey(row.name), row.image_url]));

const products = sourceRows.map((row) => {
  const sourceId = String(row[0]).trim();
  const originalName = String(row[4] ?? '').trim();
  const rule = catalogRules.get(sourceId);
  if (!rule) throw new Error(`No catalog rule exists for source item ${sourceId}: ${originalName}`);
  return {
    sourceId,
    sku: `TM8-CCH-${sourceId}`,
    barcode: ean13FromSourceId(sourceId),
    originalName,
    sourceCategory: String(row[3] ?? '').trim(),
    sourceSku: String(row[8] ?? '').trim(),
    sourceUpc: String(row[11] ?? '').trim(),
    sourceQuantity: numberValue(row[15]),
    costPrice: numberValue(row[17]),
    retailPrice: numberValue(row[19]),
    sourcePosVisible: String(row[35] ?? '').trim().toUpperCase() === 'YES',
    imageUrl: imageByName.get(normalizeKey(originalName)) ?? '',
    ...rule,
  };
});

const invalidProducts = products.filter((product) => (
  !product.sourcePosVisible
  || !product.imageUrl
  || product.costPrice <= 0
  || product.retailPrice <= 0
  || product.costPrice >= product.retailPrice
));
if (invalidProducts.length) {
  throw new Error(`Invalid car charger rows: ${invalidProducts.map((product) => product.sourceId).join(', ')}`);
}

const groupMap = new Map();
for (const product of products) {
  if (!groupMap.has(product.groupCode)) {
    groupMap.set(product.groupCode, {
      code: product.groupCode,
      slug: slugify(product.groupCode),
      name: product.groupName,
      product_family: product.family,
      main_image_url: product.imageUrl,
      status: 'active',
      is_pos_visible: true,
      is_visible: false,
    });
  }
}
const groups = Array.from(groupMap.values());

const importPayload = {
  generated_at: new Date().toISOString(),
  source_file: 'products (17).xlsx',
  category: { slug: 'car-chargers', name: 'Car Chargers' },
  release_policy: {
    existing_products_unchanged: true,
    inventory_imported: false,
    zero_stock_checkout_allowed: true,
    online_visible: false,
    one_main_image_only: true,
  },
  product_groups: groups,
  products: products.map((product) => ({
    sku: product.sku,
    slug: slugify(product.sku),
    name: product.name,
    brand: 'Generic',
    model: product.model,
    short_description: `${product.family}. For standard 12V/24V vehicle power sockets.`,
    condition_label: 'Brand New',
    compatibility: 'Standard 12V/24V vehicle power sockets',
    cost_price: product.costPrice,
    retail_price: product.retailPrice,
    image_url: product.imageUrl,
    stock_quantity: 0,
    is_visible: false,
    is_pos_visible: true,
    upc: product.barcode,
    product_group_code: product.groupCode,
    variant_name: product.color,
    variant_color: product.color,
    source_system: 'repairdesk_car_chargers',
    source_external_id: product.sourceId,
    source_category_path: product.sourceCategory,
    import_status: 'active',
    source_metadata: {
      original_name: product.originalName,
      original_sku: product.sourceSku,
      original_upc: product.sourceUpc,
      source_stock: product.sourceQuantity,
      proposed_stock: 0,
      inventory_assignment: 'none',
      source_pos_visible: product.sourcePosVisible,
      cost_source: 'repairdesk_source',
      image_source: 'repairdesk_pos',
    },
  })),
  existing_products_preserved: existingProducts,
};

const workbook = Workbook.create();
const summarySheet = workbook.worksheets.add('Import Summary');
const productsSheet = workbook.worksheets.add('Import Plan');
const groupsSheet = workbook.worksheets.add('Product Groups');
const existingSheet = workbook.worksheets.add('Existing Preserved');
for (const sheet of workbook.worksheets.items) sheet.showGridLines = false;

summarySheet.getRange('A1:H1').merge();
summarySheet.getRange('A1').values = [['TECHM8 Car Chargers Import Review']];
summarySheet.getRange('A1:H1').format = {
  fill: '#087F6B', font: { bold: true, color: '#FFFFFF', size: 18 }, verticalAlignment: 'center',
};
summarySheet.getRange('A1:H1').format.rowHeight = 34;
summarySheet.getRange('A3:B11').values = [
  ['Metric', 'Value'],
  ['New sellable variants', null],
  ['New product groups', null],
  ['Rows ready for POS', null],
  ['Missing costs', null],
  ['Missing images', null],
  ['Existing products preserved', null],
  ['Initial stock for every new product', 0],
  ['Online visibility for new products', 'Hidden'],
];
summarySheet.getRange('B4').formulas = [[`=COUNTA('Import Plan'!A2:A${products.length + 1})`]];
summarySheet.getRange('B5').formulas = [[`=COUNTA('Product Groups'!A2:A${groups.length + 1})`]];
summarySheet.getRange('B6').formulas = [[`=COUNTIF('Import Plan'!P2:P${products.length + 1},"Ready")`]];
summarySheet.getRange('B7').formulas = [[`=COUNTIF('Import Plan'!P2:P${products.length + 1},"Cost required")`]];
summarySheet.getRange('B8').formulas = [[`=COUNTIF('Import Plan'!P2:P${products.length + 1},"Image required")`]];
summarySheet.getRange('B9').formulas = [[`=COUNTA('Existing Preserved'!A2:A${existingProducts.length + 1})`]];
summarySheet.getRange('A3:B3').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' } };
summarySheet.getRange('A4:A11').format.font = { bold: true, color: '#24343B' };
summarySheet.getRange('A3:B11').format.borders = { preset: 'inside', style: 'thin', color: '#D7E1E5' };
summarySheet.getRange('A:A').format.columnWidth = 38;
summarySheet.getRange('B:B').format.columnWidth = 22;
summarySheet.getRange('D3:H3').merge();
summarySheet.getRange('D3').values = [['Import rules applied']];
summarySheet.getRange('D3:H3').format = { fill: '#24343B', font: { bold: true, color: '#FFFFFF' } };
summarySheet.getRange('D4:H10').merge();
summarySheet.getRange('D4').values = [[
  'Existing Car Chargers products and SKUs are not changed. Only missing products receive new TECHM8 SKUs. Black and white versions share one product group, while each colour remains a separate sellable SKU. All new store and online inventory starts at zero, zero stock remains sellable, and website visibility stays off.',
]];
summarySheet.getRange('D4:H10').format = { fill: '#E7F5F1', font: { color: '#164D43' }, wrapText: true, verticalAlignment: 'top' };
summarySheet.getRange('D:H').format.columnWidth = 18;

const productHeaders = [
  'Source ID', 'New SKU', 'Barcode', 'Original Name', 'POS Product Name', 'Product Group', 'Colour',
  'Cost', 'Retail', 'Initial Stock', 'Website Visible', 'POS Visible', 'Main Image URL', 'Source SKU', 'Source UPC', 'Status',
];
productsSheet.getRange(`A1:P1`).values = [productHeaders];
productsSheet.getRange(`A2:P${products.length + 1}`).values = products.map((product) => [
  product.sourceId,
  product.sku,
  displayIdentifier(product.barcode),
  product.originalName,
  product.name,
  product.groupName,
  product.color,
  product.costPrice,
  product.retailPrice,
  0,
  'No',
  'Yes',
  product.imageUrl,
  product.sourceSku,
  product.sourceUpc,
  product.imageUrl ? (product.costPrice > 0 ? 'Ready' : 'Cost required') : 'Image required',
]);
productsSheet.tables.add(`A1:P${products.length + 1}`, true, 'CarChargerImportPlan');
productsSheet.freezePanes.freezeRows(1);
productsSheet.getRange('A1:P1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
productsSheet.getRange(`A2:P${products.length + 1}`).format.verticalAlignment = 'top';
productsSheet.getRange(`D2:G${products.length + 1}`).format.wrapText = true;
productsSheet.getRange(`A2:C${products.length + 1}`).format.numberFormat = '@';
productsSheet.getRange(`H2:I${products.length + 1}`).format.numberFormat = '$#,##0.00';
productsSheet.getRange(`J2:J${products.length + 1}`).format.numberFormat = '#,##0';
productsSheet.getRange(`N2:O${products.length + 1}`).format.numberFormat = '@';
productsSheet.getRange(`P2:P${products.length + 1}`).conditionalFormats.add('containsText', {
  text: 'Ready', format: { fill: '#DFF4EF', font: { bold: true, color: '#075E54' } },
});
productsSheet.getRange('A:C').format.columnWidth = 18;
productsSheet.getRange('D:F').format.columnWidth = 38;
productsSheet.getRange('G:L').format.columnWidth = 16;
productsSheet.getRange('M:M').format.columnWidth = 62;
productsSheet.getRange('N:P').format.columnWidth = 18;

groupsSheet.getRange('A1:J1').values = [[
  'Group Code', 'POS Group Name', 'Product Family', 'Variant Count', 'Colours', 'Retail Price',
  'Main Image URL', 'POS Visible', 'Website Visible', 'Status',
]];
groupsSheet.getRange(`A2:J${groups.length + 1}`).values = groups.map((group) => {
  const variants = products.filter((product) => product.groupCode === group.code);
  return [
    group.code,
    group.name,
    group.product_family,
    variants.length,
    variants.map((product) => product.color).filter(Boolean).join(', ') || 'Single option',
    variants[0].retailPrice,
    group.main_image_url,
    'Yes',
    'No',
    'Active',
  ];
});
groupsSheet.tables.add(`A1:J${groups.length + 1}`, true, 'CarChargerProductGroups');
groupsSheet.freezePanes.freezeRows(1);
groupsSheet.getRange('A1:J1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
groupsSheet.getRange(`A2:J${groups.length + 1}`).format.verticalAlignment = 'top';
groupsSheet.getRange(`B2:E${groups.length + 1}`).format.wrapText = true;
groupsSheet.getRange(`F2:F${groups.length + 1}`).format.numberFormat = '$#,##0.00';
groupsSheet.getRange('A:A').format.columnWidth = 28;
groupsSheet.getRange('B:C').format.columnWidth = 40;
groupsSheet.getRange('D:F').format.columnWidth = 18;
groupsSheet.getRange('G:G').format.columnWidth = 62;
groupsSheet.getRange('H:J').format.columnWidth = 18;

existingSheet.getRange('A1:K1').values = [[
  'Existing SKU', 'Product Name', 'Cost', 'Retail', 'Current Stock', 'UPC', 'Name Changed',
  'SKU Changed', 'Price Changed', 'Stock Changed', 'Import Action',
]];
existingSheet.getRange(`A2:K${existingProducts.length + 1}`).values = existingProducts.map((product) => [
  product.sku,
  product.name,
  product.cost_price,
  product.retail_price,
  product.stock_quantity,
  displayIdentifier(product.upc),
  'No',
  'No',
  'No',
  'No',
  'Preserve unchanged',
]);
existingSheet.tables.add(`A1:K${existingProducts.length + 1}`, true, 'ExistingCarChargersPreserved');
existingSheet.freezePanes.freezeRows(1);
existingSheet.getRange('A1:K1').format = { fill: '#59636B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
existingSheet.getRange(`A2:A${existingProducts.length + 1}`).format.numberFormat = '@';
existingSheet.getRange(`C2:D${existingProducts.length + 1}`).format.numberFormat = '$#,##0.00';
existingSheet.getRange(`E2:E${existingProducts.length + 1}`).format.numberFormat = '#,##0';
existingSheet.getRange(`F2:F${existingProducts.length + 1}`).format.numberFormat = '@';
existingSheet.getRange(`G2:K${existingProducts.length + 1}`).format = { fill: '#F2F6F7', font: { color: '#33454C' } };
existingSheet.getRange('A:A').format.columnWidth = 18;
existingSheet.getRange('B:B').format.columnWidth = 38;
existingSheet.getRange('C:K').format.columnWidth = 18;

const summaryInspection = await workbook.inspect({
  kind: 'table', sheetId: 'Import Summary', range: 'A1:H11', include: 'values,formulas', maxChars: 5000,
});
const formulaErrors = await workbook.inspect({
  kind: 'match', searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A',
  options: { useRegex: true, maxResults: 100 }, summary: 'final formula error scan',
});

for (const [sheetName, range, fileName] of [
  ['Import Summary', 'A1:H11', 'import-summary.png'],
  ['Import Plan', `A1:P${products.length + 1}`, 'import-plan.png'],
  ['Product Groups', `A1:J${groups.length + 1}`, 'product-groups.png'],
  ['Existing Preserved', `A1:K${existingProducts.length + 1}`, 'existing-preserved.png'],
]) {
  const preview = await workbook.render({ sheetName, range, scale: 1, format: 'png' });
  await fs.writeFile(`${previewDir}/${fileName}`, new Uint8Array(await preview.arrayBuffer()));
}

const reviewOutput = await SpreadsheetFile.exportXlsx(workbook);
await reviewOutput.save(reviewWorkbookPath);
await fs.writeFile(importJsonPath, JSON.stringify(importPayload, null, 2), 'utf8');

const jsonLiteral = (value) => `$catalog$${JSON.stringify(value)}$catalog$::jsonb`;
const importSql = `begin;

with input_groups as (
  select * from jsonb_to_recordset(${jsonLiteral(importPayload.product_groups)}) as x(
    code text,
    slug text,
    name text,
    product_family text,
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
  input_groups.code,
  input_groups.slug,
  input_groups.name,
  category.id,
  input_groups.product_family,
  null,
  input_groups.main_image_url,
  input_groups.status,
  input_groups.is_pos_visible,
  input_groups.is_visible
from input_groups
join public.categories category on category.slug = 'car-chargers'
on conflict (code) do update
set slug = excluded.slug,
    name = excluded.name,
    category_id = excluded.category_id,
    product_family = excluded.product_family,
    main_image_url = excluded.main_image_url,
    status = excluded.status,
    is_pos_visible = excluded.is_pos_visible,
    is_visible = excluded.is_visible,
    updated_at = timezone('utc'::text, now());

with input_products as (
  select * from jsonb_to_recordset(${jsonLiteral(importPayload.products)}) as x(
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
  input_products.sku,
  input_products.slug,
  input_products.name,
  input_products.brand,
  input_products.model,
  category.id,
  input_products.short_description,
  input_products.condition_label,
  input_products.compatibility,
  input_products.cost_price,
  input_products.retail_price,
  input_products.image_url,
  0,
  false,
  true,
  input_products.upc,
  product_group.id,
  input_products.variant_name,
  input_products.variant_color,
  input_products.source_system,
  input_products.source_external_id,
  input_products.source_category_path,
  input_products.import_status,
  input_products.source_metadata
from input_products
join public.categories category on category.slug = 'car-chargers'
join public.product_groups product_group on product_group.code = input_products.product_group_code
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
where public.products.source_system = 'repairdesk_car_chargers'
  and public.products.source_external_id = excluded.source_external_id;

commit;

select
  count(*) as imported_products,
  count(distinct product_group_id) as imported_groups,
  count(*) filter (where stock_quantity <> 0) as products_with_stock,
  count(*) filter (where is_visible) as website_visible_products,
  count(*) filter (where is_pos_visible and import_status = 'active') as active_pos_products
from public.products
where source_system = 'repairdesk_car_chargers';
`;
await fs.writeFile(importSqlPath, importSql, 'utf8');

console.log(JSON.stringify({
  sourceProducts: sourceRows.length,
  newProducts: products.length,
  productGroups: groups.length,
  existingPreserved: existingProducts.length,
  missingCosts: products.filter((product) => product.costPrice <= 0).length,
  missingImages: products.filter((product) => !product.imageUrl).length,
  reviewWorkbookPath,
  importJsonPath,
  importSqlPath,
  previewDir,
  summaryInspection: summaryInspection.ndjson,
  formulaErrors: formulaErrors.ndjson,
}, null, 2));
