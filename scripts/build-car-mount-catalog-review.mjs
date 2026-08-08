import fs from 'node:fs/promises';
import { FileBlob, SpreadsheetFile, Workbook } from '@oai/artifact-tool';

const sourcePath = process.argv[2];
if (!sourcePath) {
  throw new Error('Pass the RepairDesk product workbook path as the first argument.');
}

const outputDir = 'D:/program/TECHM8 PRICE LIST/outputs/car-mount-catalog-rebuild';
const previewDir = 'C:/Users/User/AppData/Local/Temp/codex-car-mount-catalog/previews';
const imageMapPath = `${outputDir}/RepairDesk_Car_Mount_Images.json`;
const costOverridePath = `${outputDir}/Car_Mount_Cost_Overrides.json`;
const reviewWorkbookPath = `${outputDir}/TECHM8_Car_Mounts_Import_Review.xlsx`;
const costWorkbookPath = `${outputDir}/TECHM8_Car_Mounts_Costs_To_Complete.xlsx`;
const importJsonPath = `${outputDir}/TECHM8_Car_Mounts_Draft_Import.json`;
const importSqlPath = `${outputDir}/TECHM8_Car_Mounts_Draft_Import.sql`;

await fs.mkdir(outputDir, { recursive: true });
await fs.mkdir(previewDir, { recursive: true });

const sourceWorkbook = await SpreadsheetFile.importXlsx(await FileBlob.load(sourcePath));
const sourceSheet = sourceWorkbook.worksheets.getItem('Sheet1');
const sourceValues = sourceSheet.getUsedRange(true).values;
const sourceRows = sourceValues.slice(2).filter((row) => String(row[0] ?? '').trim());
const imageRows = JSON.parse(await fs.readFile(imageMapPath, 'utf8'));
const overridePayload = JSON.parse(await fs.readFile(costOverridePath, 'utf8'));
const removedSourceIds = new Set((overridePayload.removed_source_ids ?? []).map(String));

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

function ean13FromSourceId(sourceId) {
  const digits = String(sourceId ?? '').replace(/\D/g, '').slice(-8).padStart(8, '0');
  const body = `2988${digits}`;
  let sum = 0;
  for (let index = 0; index < body.length; index += 1) {
    sum += Number(body[index]) * (index % 2 === 0 ? 1 : 3);
  }
  return `${body}${(10 - (sum % 10)) % 10}`;
}

const nameOverrides = new Map([
  ['11126', 'Remax RM-C42 Pro Magnetic Rotating Zinc Alloy Car Mount'],
  ['10834', 'Remax RM-C36 Rotatable Car Phone Holder'],
  ['10745', 'Remax RM-C01 15W MagSafe Magnetic Car Charging Mount - Black'],
  ['10742', 'WEKOME WP-U209 MagSafe Wireless Charging Car Holder'],
  ['10362', 'Bike Phone Holder Z02 + MT01'],
  ['9977', 'Magnetic Stick-On Car Phone Holder'],
  ['9976', 'Magnetic Air Vent Hook Car Phone Holder'],
  ['9253', 'WEKOME WP-U206 Suction Cup Car Phone Holder'],
  ['9104', 'BOROFONE BH-201 Magnetic Car Phone Holder'],
  ['8866', 'Tesla Model 3/Y Mobile Phone Holder Adapter'],
  ['8154', 'MagSafe Car Phone Holder'],
  ['7816', 'WEKOME WP-U202 Car Phone Holder'],
  ['7616', 'Bicycle Phone Holder'],
  ['7583', 'HL-69 Waterproof Phone Holder Case'],
  ['7582', 'JXCH Car Phone Holder'],
  ['6989', 'Car Phone Holder 2'],
  ['6671', 'Car Back Seat Phone Mount'],
  ['6661', '3-in-1 Car Phone Holder'],
  ['6660', 'Magnetic Dashboard and Air Vent Car Phone Holder'],
  ['6659', 'Metal Motorcycle Phone Holder'],
  ['6606', 'WEKOME WP-U203 Car Phone Holder'],
  ['6582', 'Magnetic Car Phone Holder'],
  ['6581', 'Car Phone Holder 7'],
  ['6580', 'Car Phone Holder 5'],
  ['6578', 'Car Phone Holder 3'],
  ['6576', 'Car Phone Holder 3'],
  ['6034', 'Replacement Metal Plate for Magnetic Phone Holders'],
]);

const compatibilityOverrides = new Map([
  ['10362', 'Bicycle handlebars'],
  ['8866', 'Tesla Model 3 and Model Y'],
  ['7583', 'Bicycles and motorcycles; universal smartphones'],
  ['6671', 'Vehicle headrests; universal smartphones'],
  ['6659', 'Motorcycle handlebars; universal smartphones'],
  ['6034', 'Magnetic phone holders'],
]);

const imageByName = new Map(imageRows.map((row) => [normalizeKey(row.name), row.image_url]));
const costOverrides = new Map(
  Object.entries(overridePayload.confirmed_costs ?? {}).map(([sku, cost]) => [sku, Number(cost)]),
);

function brandFromName(name) {
  if (/^remax\b/i.test(name)) return 'Remax';
  if (/^wekome\b/i.test(name)) return 'WEKOME';
  if (/^borofone\b/i.test(name)) return 'BOROFONE';
  if (/^tesla\b/i.test(name)) return 'Tesla Compatible';
  return 'Generic';
}

function mountTypeFromName(name) {
  if (/metal plate/i.test(name)) return 'Mount Accessory';
  if (/wireless charging|15w/i.test(name)) return 'Wireless Charging Mount';
  if (/back seat|headrest/i.test(name)) return 'Back Seat Mount';
  if (/bike|bicycle/i.test(name)) return 'Bicycle Mount';
  if (/motorcycle/i.test(name)) return 'Motorcycle Mount';
  if (/tesla/i.test(name)) return 'Vehicle-Specific Adapter';
  if (/suction/i.test(name)) return 'Suction Cup Mount';
  if (/magnetic|magsafe|\bmag\b/i.test(name)) return 'Magnetic Mount';
  return 'Car Phone Holder';
}

const allProducts = sourceRows.map((row) => {
  const sourceId = String(row[0]).trim();
  const originalName = String(row[4] ?? '').trim();
  const sku = `TM8-CAR-${sourceId}`;
  const sourceCost = numberValue(row[17]);
  const overrideCost = costOverrides.get(sku);
  const confirmedCost = Number.isFinite(overrideCost) && overrideCost > 0
    ? overrideCost
    : sourceCost > 0 ? sourceCost : null;
  const proposedName = nameOverrides.get(sourceId) ?? originalName;
  return {
    sourceId,
    sku,
    barcode: ean13FromSourceId(sourceId),
    originalName,
    proposedName,
    brand: brandFromName(proposedName),
    mountType: mountTypeFromName(proposedName),
    compatibility: compatibilityOverrides.get(sourceId) ?? 'Universal smartphones',
    sourceCategory: String(row[3] ?? '').trim(),
    sourceSku: String(row[8] ?? '').trim(),
    sourceUpc: String(row[11] ?? '').trim(),
    sourceQuantity: numberValue(row[15]),
    sourceCost,
    overrideCost: Number.isFinite(overrideCost) && overrideCost > 0 ? overrideCost : null,
    confirmedCost,
    retailPrice: numberValue(row[19]),
    sourcePosVisible: String(row[35] ?? '').trim().toUpperCase() === 'YES',
    removedFromCatalog: removedSourceIds.has(sourceId),
    imageUrl: imageByName.get(normalizeKey(originalName)) ?? '',
  };
});

const excludedProducts = allProducts.filter((product) => !product.sourcePosVisible || product.removedFromCatalog);
const candidateProducts = allProducts.filter((product) => product.sourcePosVisible && !product.removedFromCatalog);
const missingCostProducts = candidateProducts.filter((product) => !product.confirmedCost);
const missingImageProducts = candidateProducts.filter((product) => !product.imageUrl);
const readyProducts = candidateProducts.filter((product) => product.confirmedCost && product.imageUrl);

const importPayload = {
  generated_at: new Date().toISOString(),
  source_file: 'products (15).xlsx',
  category: { slug: 'holder-car-play-charger', name: 'Car Holders' },
  release_policy: {
    inventory_imported: false,
    source_pos_hidden_excluded: true,
    missing_cost_products_removed: true,
    zero_stock_checkout_allowed: true,
    online_visible: false,
  },
  products: candidateProducts.map((product) => {
    const isReady = Boolean(product.confirmedCost && product.imageUrl);
    return {
      sku: product.sku,
      slug: slugify(product.sku),
      name: product.proposedName,
      brand: product.brand,
      model: product.mountType,
      short_description: `${product.mountType}. ${product.compatibility}.`,
      condition_label: 'Brand New',
      compatibility: product.compatibility,
      cost_price: product.confirmedCost,
      retail_price: product.retailPrice,
      image_url: product.imageUrl,
      stock_quantity: 0,
      is_visible: false,
      is_pos_visible: isReady,
      upc: product.barcode,
      variant_name: null,
      variant_color: /black/i.test(product.proposedName) ? 'Black' : null,
      source_system: 'repairdesk_car_mounts',
      source_external_id: product.sourceId,
      source_category_path: product.sourceCategory,
      import_status: isReady ? 'active' : 'blocked',
      source_metadata: {
        original_name: product.originalName,
        original_sku: product.sourceSku,
        original_upc: product.sourceUpc,
        source_stock: product.sourceQuantity,
        proposed_stock: 0,
        inventory_assignment: 'none',
        source_pos_visible: product.sourcePosVisible,
        cost_source: product.overrideCost ? 'owner_override' : product.sourceCost > 0 ? 'repairdesk_source' : 'missing',
      },
    };
  }),
  excluded_products: excludedProducts.map((product) => ({
    source_external_id: product.sourceId,
    original_name: product.originalName,
    proposed_name: product.proposedName,
    reason: product.removedFromCatalog
      ? 'Removed from catalog because the product no longer exists.'
      : product.sourceId === '6578'
        ? 'RepairDesk POS hidden duplicate; TM8-CAR-6576 is retained.'
        : 'RepairDesk Display On Point of Sale is NO.',
  })),
};

const workbook = Workbook.create();
const summarySheet = workbook.worksheets.add('Import Summary');
const productsSheet = workbook.worksheets.add('POS Products');
const costsSheet = workbook.worksheets.add('Cost Updates');
const excludedSheet = workbook.worksheets.add('Excluded Products');

for (const sheet of workbook.worksheets.items) sheet.showGridLines = false;

summarySheet.getRange('A1:H1').merge();
summarySheet.getRange('A1').values = [['TECHM8 Car Mount POS Import Review']];
summarySheet.getRange('A1:H1').format = {
  fill: '#087F6B',
  font: { bold: true, color: '#FFFFFF', size: 18 },
  verticalAlignment: 'center',
};
summarySheet.getRange('A1:H1').format.rowHeight = 34;
summarySheet.getRange('A3:B11').values = [
  ['Metric', 'Value'],
  ['Source products', allProducts.length],
  ['Current RepairDesk POS products', candidateProducts.length],
  ['Ready for new POS', readyProducts.length],
  ['Blocked until cost is entered', missingCostProducts.length],
  ['Blocked because image is missing', missingImageProducts.length],
  ['Excluded or removed from the catalog', excludedProducts.length],
  ['Products with generated SKU and EAN-13', candidateProducts.length],
  ['Products importing source stock', 0],
];
summarySheet.getRange('A3:B3').format = { fill: '#DFF4EF', font: { bold: true, color: '#075E54' } };
summarySheet.getRange('B4:B11').format.numberFormat = '0';
summarySheet.getRange('D3:H3').merge();
summarySheet.getRange('D3').values = [['Release Rules']];
summarySheet.getRange('D3:H3').format = { fill: '#FDE7E3', font: { bold: true, color: '#9C2F22' } };
summarySheet.getRange('D4:H9').merge(true);
summarySheet.getRange('D4:H9').values = [
  ['Products with valid cost and image are active in POS.'],
  ['Products without a confirmed cost are removed from the active catalog.'],
  ['All stores and the online store start at zero stock.'],
  ['Zero stock does not prevent POS checkout.'],
  ['RepairDesk source SKU and UPC are replaced with new TECHM8 identifiers.'],
  ['Online visibility remains off until a separate website review.'],
];
summarySheet.getRange('D4:H9').format = { wrapText: true, fill: '#FFF8F0', font: { color: '#4A332A' } };
summarySheet.getRange('A13:H13').merge();
summarySheet.getRange('A13').values = [[missingCostProducts.length
  ? 'Fill the Cost To Enter column in the separate cost workbook. Return that file to activate the remaining products.'
  : 'All retained POS products now have a confirmed cost and image.']];
summarySheet.getRange('A13:H13').format = { wrapText: true, fill: '#EAF2FF', font: { bold: true, color: '#204B7A' } };
summarySheet.getRange('A:H').format.columnWidth = 16;
summarySheet.getRange('A:A').format.columnWidth = 42;
summarySheet.getRange('D:H').format.columnWidth = 18;

const productHeaders = [
  'Source Item ID', 'New SKU', 'New Barcode', 'Original Name', 'POS Product Name', 'Brand',
  'Mount Type', 'Compatibility', 'Source Category', 'Image URL', 'Source Cost', 'Override Cost',
  'Cost To Use', 'Retail Price', 'Source Qty', 'POS Visible', 'Online Visible', 'Import Status',
  'Original SKU', 'Original UPC', 'Notes',
];
productsSheet.getRange('A1:U1').values = [productHeaders];
productsSheet.getRange(`A2:U${candidateProducts.length + 1}`).values = candidateProducts.map((product) => [
  product.sourceId,
  product.sku,
  product.barcode,
  product.originalName,
  product.proposedName,
  product.brand,
  product.mountType,
  product.compatibility,
  product.sourceCategory,
  product.imageUrl,
  product.sourceCost || null,
  product.overrideCost,
  product.confirmedCost,
  product.retailPrice,
  product.sourceQuantity,
  product.confirmedCost && product.imageUrl ? 'YES' : 'NO',
  'NO',
  product.confirmedCost && product.imageUrl ? 'Active' : 'Blocked',
  product.sourceSku,
  product.sourceUpc,
  product.sourceQuantity < 0 ? 'Negative source stock clipped to zero.' : '',
]);
productsSheet.tables.add(`A1:U${candidateProducts.length + 1}`, true, 'CarMountProductsReview');
productsSheet.freezePanes.freezeRows(1);
productsSheet.getRange('A1:U1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
productsSheet.getRange(`A2:U${candidateProducts.length + 1}`).format.wrapText = true;
productsSheet.getRange('A:C').format.columnWidth = 18;
productsSheet.getRange(`C2:C${candidateProducts.length + 1}`).format.numberFormat = '0';
productsSheet.getRange('D:E').format.columnWidth = 34;
productsSheet.getRange('F:H').format.columnWidth = 22;
productsSheet.getRange('I:J').format.columnWidth = 38;
productsSheet.getRange('K:N').format.columnWidth = 14;
productsSheet.getRange('O:U').format.columnWidth = 16;
productsSheet.getRange(`T2:T${candidateProducts.length + 1}`).format.numberFormat = '0';
productsSheet.getRange(`K2:N${candidateProducts.length + 1}`).format.numberFormat = '$#,##0.00';
productsSheet.getRange(`O2:O${candidateProducts.length + 1}`).format.numberFormat = '0';

const costHeaders = ['Source Item ID', 'New SKU', 'Product Name', 'Mount Type', 'Retail Price', 'Current Cost', 'Cost To Enter', 'Status', 'Image URL'];
costsSheet.getRange('A1:I1').values = [costHeaders];
costsSheet.freezePanes.freezeRows(1);
costsSheet.getRange('A1:I1').format = { fill: '#9C2F22', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
if (missingCostProducts.length) {
  costsSheet.getRange(`A2:I${missingCostProducts.length + 1}`).values = missingCostProducts.map((product) => [
    product.sourceId,
    product.sku,
    product.proposedName,
    product.mountType,
    product.retailPrice,
    product.sourceCost || null,
    product.overrideCost,
    product.overrideCost ? 'Ready' : 'Cost required',
    product.imageUrl,
  ]);
  costsSheet.tables.add(`A1:I${missingCostProducts.length + 1}`, true, 'CarMountCostUpdates');
  costsSheet.getRange(`A2:I${missingCostProducts.length + 1}`).format.wrapText = true;
  costsSheet.getRange(`G2:G${missingCostProducts.length + 1}`).format = { fill: '#FFF1B8', font: { bold: true, color: '#6B4F00' } };
  costsSheet.getRange(`E2:G${missingCostProducts.length + 1}`).format.numberFormat = '$#,##0.00';
} else {
  costsSheet.getRange('A2:I2').merge();
  costsSheet.getRange('A2').values = [['No cost updates are outstanding.']];
  costsSheet.getRange('A2:I2').format = { fill: '#EAF6F2', font: { bold: true, color: '#075E54' } };
}
costsSheet.getRange('A:B').format.columnWidth = 18;
costsSheet.getRange('C:D').format.columnWidth = 34;
costsSheet.getRange('E:H').format.columnWidth = 16;
costsSheet.getRange('I:I').format.columnWidth = 46;

const excludedHeaders = ['Source Item ID', 'New SKU Reserved', 'Original Name', 'Proposed Name', 'Source Qty', 'Source Cost', 'Retail Price', 'Reason Excluded'];
excludedSheet.getRange('A1:H1').values = [excludedHeaders];
excludedSheet.getRange(`A2:H${excludedProducts.length + 1}`).values = excludedProducts.map((product) => [
  product.sourceId,
  product.sku,
  product.originalName,
  product.proposedName,
  product.sourceQuantity,
  product.sourceCost || null,
  product.retailPrice,
  product.removedFromCatalog
    ? 'Removed from catalog because the product no longer exists.'
    : product.sourceId === '6578'
      ? 'RepairDesk POS hidden duplicate; TM8-CAR-6576 is retained.'
      : 'RepairDesk Display On Point of Sale is NO.',
]);
excludedSheet.tables.add(`A1:H${excludedProducts.length + 1}`, true, 'CarMountExcludedProducts');
excludedSheet.freezePanes.freezeRows(1);
excludedSheet.getRange('A1:H1').format = { fill: '#59636B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
excludedSheet.getRange(`A2:H${excludedProducts.length + 1}`).format.wrapText = true;
excludedSheet.getRange('A:B').format.columnWidth = 18;
excludedSheet.getRange('C:D').format.columnWidth = 34;
excludedSheet.getRange('E:G').format.columnWidth = 14;
excludedSheet.getRange('H:H').format.columnWidth = 48;
excludedSheet.getRange(`F2:G${excludedProducts.length + 1}`).format.numberFormat = '$#,##0.00';

const costWorkbook = Workbook.create();
const costInputSheet = costWorkbook.worksheets.add('Costs To Complete');
costInputSheet.showGridLines = false;
costInputSheet.getRange('A1:I1').merge();
costInputSheet.getRange('A1').values = [['TECHM8 Car Mounts - Costs To Complete']];
costInputSheet.getRange('A1:I1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF', size: 18 }, verticalAlignment: 'center' };
costInputSheet.getRange('A1:I1').format.rowHeight = 34;
costInputSheet.getRange('A2:I2').merge();
costInputSheet.getRange('A2').values = [['Enter the unit cost in the yellow Cost To Enter column. Do not change Source Item ID or New SKU.']];
costInputSheet.getRange('A2:I2').format = { fill: '#EAF2FF', font: { bold: true, color: '#204B7A' }, wrapText: true };
costInputSheet.getRange('A4:I4').values = [costHeaders];
costInputSheet.freezePanes.freezeRows(4);
costInputSheet.getRange('A4:I4').format = { fill: '#9C2F22', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
if (missingCostProducts.length) {
  costInputSheet.getRange(`A5:I${missingCostProducts.length + 4}`).values = missingCostProducts.map((product) => [
    product.sourceId,
    product.sku,
    product.proposedName,
    product.mountType,
    product.retailPrice,
    product.sourceCost || null,
    product.overrideCost,
    product.overrideCost ? 'Ready' : 'Cost required',
    product.imageUrl,
  ]);
  costInputSheet.tables.add(`A4:I${missingCostProducts.length + 4}`, true, 'CarMountMissingCosts');
  costInputSheet.getRange(`A5:I${missingCostProducts.length + 4}`).format.wrapText = true;
  costInputSheet.getRange(`G5:G${missingCostProducts.length + 4}`).format = { fill: '#FFF1B8', font: { bold: true, color: '#6B4F00' } };
  costInputSheet.getRange(`E5:G${missingCostProducts.length + 4}`).format.numberFormat = '$#,##0.00';
} else {
  costInputSheet.getRange('A5:I5').merge();
  costInputSheet.getRange('A5').values = [['No cost updates are outstanding.']];
  costInputSheet.getRange('A5:I5').format = { fill: '#EAF6F2', font: { bold: true, color: '#075E54' } };
}
costInputSheet.getRange('A:B').format.columnWidth = 18;
costInputSheet.getRange('C:D').format.columnWidth = 34;
costInputSheet.getRange('E:H').format.columnWidth = 16;
costInputSheet.getRange('I:I').format.columnWidth = 46;

const summaryInspection = await workbook.inspect({
  kind: 'table',
  sheetId: 'Import Summary',
  range: 'A1:H13',
  include: 'values,formulas',
  tableMaxRows: 20,
  tableMaxCols: 10,
});
const formulaErrors = await workbook.inspect({
  kind: 'match',
  searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A',
  options: { useRegex: true, maxResults: 200 },
  summary: 'car mount review formula error scan',
});
const costFormulaErrors = await costWorkbook.inspect({
  kind: 'match',
  searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A',
  options: { useRegex: true, maxResults: 200 },
  summary: 'car mount cost formula error scan',
});

const previews = [
  [workbook, 'Import Summary', 'A1:H13', 'summary.png'],
  [workbook, 'POS Products', `A1:U${candidateProducts.length + 1}`, 'products.png'],
  [workbook, 'Cost Updates', `A1:I${Math.max(2, missingCostProducts.length + 1)}`, 'cost-updates.png'],
  [workbook, 'Excluded Products', `A1:H${excludedProducts.length + 1}`, 'excluded-products.png'],
  [costWorkbook, 'Costs To Complete', `A1:I${Math.max(5, missingCostProducts.length + 4)}`, 'costs-to-complete.png'],
];
for (const [previewWorkbook, sheetName, range, fileName] of previews) {
  const preview = await previewWorkbook.render({ sheetName, range, scale: 1, format: 'png' });
  await fs.writeFile(`${previewDir}/${fileName}`, new Uint8Array(await preview.arrayBuffer()));
}

const reviewOutput = await SpreadsheetFile.exportXlsx(workbook);
await reviewOutput.save(reviewWorkbookPath);
const costOutput = await SpreadsheetFile.exportXlsx(costWorkbook);
await costOutput.save(costWorkbookPath);
await fs.writeFile(importJsonPath, JSON.stringify(importPayload, null, 2), 'utf8');

const jsonLiteral = (value) => `$catalog$${JSON.stringify(value)}$catalog$::jsonb`;
const importSql = `begin;

with input as (
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
  input.is_pos_visible,
  input.upc,
  null,
  input.variant_name,
  input.variant_color,
  input.source_system,
  input.source_external_id,
  input.source_category_path,
  input.import_status,
  input.source_metadata
from input
join public.categories category on category.slug = 'holder-car-play-charger'
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
    is_visible = false,
    is_pos_visible = excluded.is_pos_visible,
    upc = excluded.upc,
    product_group_id = null,
    variant_name = excluded.variant_name,
    variant_color = excluded.variant_color,
    source_system = excluded.source_system,
    source_external_id = excluded.source_external_id,
    source_category_path = excluded.source_category_path,
    import_status = excluded.import_status,
    source_metadata = excluded.source_metadata,
    updated_at = timezone('utc'::text, now());

commit;

select
  count(*) as imported_products,
  count(*) filter (where import_status = 'active' and is_pos_visible) as active_pos_products,
  count(*) filter (where import_status = 'blocked') as blocked_products,
  count(*) filter (where stock_quantity <> 0) as products_with_stock
from public.products
where source_system = 'repairdesk_car_mounts';
`;
await fs.writeFile(importSqlPath, importSql, 'utf8');

console.log(JSON.stringify({
  sourceProducts: allProducts.length,
  candidateProducts: candidateProducts.length,
  readyProducts: readyProducts.length,
  missingCostProducts: missingCostProducts.length,
  missingImageProducts: missingImageProducts.length,
  excludedProducts: excludedProducts.length,
  reviewWorkbookPath,
  costWorkbookPath,
  importJsonPath,
  importSqlPath,
  previewDir,
  summaryInspection: summaryInspection.ndjson,
  formulaErrors: formulaErrors.ndjson,
  costFormulaErrors: costFormulaErrors.ndjson,
}, null, 2));
