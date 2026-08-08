import fs from 'node:fs/promises';
import { FileBlob, SpreadsheetFile, Workbook } from '@oai/artifact-tool';

const sourcePath = process.argv[2];
if (!sourcePath) {
  throw new Error('Pass the RepairDesk product workbook path as the first argument.');
}

const outputDir = 'D:/program/TECHM8 PRICE LIST/outputs/cable-catalog-rebuild';
const previewDir = 'C:/Users/User/AppData/Local/Temp/codex-cable-catalog/previews';
const temporaryRawImagePath = 'C:/Users/User/AppData/Local/Temp/repairdesk-cable-images-raw.json';
const temporaryExistingProductsPath = 'C:/Users/User/AppData/Local/Temp/existing-cable-products.json';
const cleanImagePath = `${outputDir}/RepairDesk_Cable_Images.json`;
const existingSnapshotPath = `${outputDir}/Existing_Cable_Products_Snapshot.json`;
const costOverridePath = `${outputDir}/Cable_Cost_Overrides.json`;
const reviewWorkbookPath = `${outputDir}/TECHM8_Cable_Catalog_Import_Review.xlsx`;
const costWorkbookPath = `${outputDir}/TECHM8_Cable_Costs_To_Complete.xlsx`;
const importJsonPath = `${outputDir}/TECHM8_Cable_Draft_Import.json`;
const importSqlPath = `${outputDir}/TECHM8_Cable_Draft_Import.sql`;

await fs.mkdir(outputDir, { recursive: true });
await fs.mkdir(previewDir, { recursive: true });

const pathExists = async (path) => fs.access(path).then(() => true).catch(() => false);
const rawImagePath = process.argv[3]
  ?? (await pathExists(temporaryRawImagePath) ? temporaryRawImagePath : cleanImagePath);
const existingProductsPath = process.argv[4]
  ?? (await pathExists(temporaryExistingProductsPath) ? temporaryExistingProductsPath : existingSnapshotPath);

const normalizeKey = (value) => String(value ?? '')
  .trim()
  .toLowerCase()
  .replace(/\s+/g, ' ');

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
  const body = `2987${digits}`;
  let sum = 0;
  for (let index = 0; index < body.length; index += 1) {
    sum += Number(body[index]) * (index % 2 === 0 ? 1 : 3);
  }
  return `${body}${(10 - (sum % 10)) % 10}`;
}

function validBarcode(value) {
  return /^\d{12,13}$/.test(String(value ?? '').trim());
}

function parseImageRows(rawText) {
  const rows = [];
  const pattern = /\{\s*"name"\s*:\s*"((?:\\.|[^"\\])*)"\s*,\s*"image_url"\s*:\s*"([\s\S]*?)"\s*\}/g;
  for (const match of rawText.matchAll(pattern)) {
    let name = match[1];
    try {
      name = JSON.parse(`"${name}"`);
    } catch {
      name = name.replace(/\\"/g, '"');
    }
    rows.push({
      name: String(name).trim(),
      image_url: match[2].replace(/\s+/g, ''),
    });
  }

  // This one RepairDesk label is malformed in the page source, but its image URL is valid.
  rows.push({
    name: '2M High Quality Cable (Silicone)',
    image_url: 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1651793523.jpg',
  });
  return rows;
}

const sourceWorkbook = await SpreadsheetFile.importXlsx(await FileBlob.load(sourcePath));
const sourceSheet = sourceWorkbook.worksheets.getItem('Sheet1');
const sourceValues = sourceSheet.getUsedRange(true).values;
const sourceRows = sourceValues.slice(2).filter((row) => String(row[0] ?? '').trim());
const existingProducts = JSON.parse((await fs.readFile(existingProductsPath, 'utf8')).replace(/^\uFEFF/, ''));
const rawImageRows = parseImageRows(await fs.readFile(rawImagePath, 'utf8'));
const costOverridePayload = JSON.parse(await fs.readFile(costOverridePath, 'utf8'));
const confirmedCosts = new Map(Object.entries(costOverridePayload.confirmed_costs ?? {}).map(([sku, cost]) => [sku, numberValue(cost)]));
const removedSourceIds = new Set((costOverridePayload.removed_source_ids ?? []).map(String));
await fs.writeFile(existingSnapshotPath, JSON.stringify(existingProducts, null, 2), 'utf8');

const sourceNames = new Set(sourceRows.map((row) => normalizeKey(row[4])));
const cleanImageRows = rawImageRows
  .filter((row) => sourceNames.has(normalizeKey(row.name)))
  .filter((row, index, rows) => rows.findIndex((candidate) => normalizeKey(candidate.name) === normalizeKey(row.name)) === index)
  .sort((left, right) => left.name.localeCompare(right.name));
await fs.writeFile(cleanImagePath, JSON.stringify(cleanImageRows, null, 2), 'utf8');

const imageByName = new Map(cleanImageRows.map((row) => [normalizeKey(row.name), row.image_url]));
const existingByName = new Map(existingProducts.map((product) => [normalizeKey(product.name), product]));
const existingBySku = new Map(existingProducts.map((product) => [String(product.sku ?? '').trim(), product]));
const existingByBarcode = new Map(existingProducts
  .filter((product) => validBarcode(product.barcode))
  .map((product) => [String(product.barcode).trim(), product]));
const sourceSkuCounts = new Map();
for (const row of sourceRows) {
  const sourceSku = String(row[8] ?? '').trim();
  sourceSkuCounts.set(sourceSku, (sourceSkuCounts.get(sourceSku) ?? 0) + 1);
}

const nameOverrides = new Map([
  ['10260', 'WEKOME WDC-58i Lightning to USB Charging Data Cable'],
  ['9669', 'GS06 Mini USB-C to USB OTG Card Reader Adapter'],
  ['9622', '2M Ultra Tough USB-C to USB-C Cable'],
  ['9618', '2M USB-C to Lightning Cable'],
  ['8112', 'RC-124TH 3-in-1 Charging Cable'],
  ['8013', '25cm USB-C Cable'],
  ['8012', '25cm Lightning Cable'],
  ['7646', '1M High Quality USB-C to USB-C Cable'],
  ['6675', '2M High Quality Silicone Lightning Cable'],
  ['6674', '1M High Quality USB-C Cable'],
  ['6673', '1M High Quality Lightning Cable'],
  ['6559', '2M 5-Pin USB Mini-B Cable'],
  ['6537', 'Remax 25cm Lightning Cable - Black'],
  ['6536', 'Remax 25cm Micro-USB Cable - White'],
  ['6535', 'Remax 25cm USB-C Cable - White'],
  ['6534', 'Remax 25cm USB-C Cable - Black'],
  ['6478', 'Apple 30-pin Dock Connector to USB Cable'],
  ['6089', 'Remax Micro-USB to USB OTG Adapter'],
  ['5944', '3M Ultra Tough Micro-USB Cable'],
  ['5943', '3M Ultra Tough USB-C Cable'],
  ['5942', '3M Ultra Tough Lightning Cable'],
  ['5941', '2M Ultra Tough Micro-USB Cable'],
  ['5940', '2M Ultra Tough USB-C Cable'],
  ['5929', '2M Ultra Tough Lightning Cable'],
  ['5908', '1M Ultra Tough Micro-USB Cable'],
  ['5907', '1M Ultra Tough USB-C Cable'],
]);

function brandFromName(name) {
  if (/^wekome\b/i.test(name)) return 'WEKOME';
  if (/^remax\b/i.test(name)) return 'Remax';
  return 'Generic';
}

function cableTypeFromName(name) {
  const normalizedName = name.replace(/\blighting\b/gi, 'Lightning');
  if (/otg|card reader/i.test(normalizedName)) return 'OTG Adapter';
  if (/3[- ]?in[- ]?1|3 n 1|wdc-50/i.test(normalizedName)) return 'Multi-Connector Cable';
  if (/mini[- ]?b/i.test(normalizedName)) return 'USB Mini-B Cable';
  if (/30-pin|dock connector/i.test(normalizedName)) return 'Apple 30-pin Cable';
  if (/usb-c to lightning|lightning to (usb-c|typec)|type c to lightning/i.test(normalizedName)) return 'USB-C to Lightning Cable';
  if (/usb-c to usb-c|type c to type c|type-c-c/i.test(normalizedName)) return 'USB-C to USB-C Cable';
  if (/micro[- ]?usb/i.test(normalizedName)) return 'USB-A to Micro-USB Cable';
  if (/lightning/i.test(normalizedName)) return 'USB-A to Lightning Cable';
  if (/usb-c|type[- ]?c/i.test(normalizedName)) return 'USB-A to USB-C Cable';
  return 'Charging Cable - Connector Unspecified';
}

function lengthFromProduct(name, sourceCategory) {
  const combined = `${name} ${sourceCategory}`;
  const lengthMatch = combined.match(/\b(25\s*cm|1\s*m|2\s*m|3\s*m)\b/i);
  return lengthMatch ? lengthMatch[1].replace(/\s+/g, '').toLowerCase() : null;
}

function findExistingProduct(row) {
  const originalName = String(row[4] ?? '').trim();
  const sourceSku = String(row[8] ?? '').trim();
  const sourceUpc = String(row[11] ?? '').trim();
  const exactNameMatch = existingByName.get(normalizeKey(originalName));
  if (exactNameMatch) return exactNameMatch;
  if (sourceSku && sourceSkuCounts.get(sourceSku) === 1 && existingBySku.has(sourceSku)) {
    return existingBySku.get(sourceSku);
  }
  if (validBarcode(sourceUpc) && existingByBarcode.has(sourceUpc)) {
    return existingByBarcode.get(sourceUpc);
  }
  return null;
}

const usedBarcodes = new Set(existingProducts
  .map((product) => String(product.barcode ?? '').trim())
  .filter(Boolean));

const products = sourceRows.map((row) => {
  const sourceId = String(row[0]).trim();
  const originalName = String(row[4] ?? '').trim();
  const sourceCategory = String(row[3] ?? '').trim();
  const sourceSku = String(row[8] ?? '').trim();
  const sourceUpc = String(row[11] ?? '').trim();
  const existing = findExistingProduct(row);
  const sku = existing?.sku ?? `TM8-CBL-${sourceId}`;
  const proposedName = existing?.name ?? nameOverrides.get(sourceId) ?? originalName;
  const cableType = cableTypeFromName(proposedName);
  const length = lengthFromProduct(proposedName, sourceCategory);
  const sourceCost = numberValue(row[17]);
  const retailPrice = numberValue(row[19]);
  const overrideCost = confirmedCosts.get(sku);
  const confirmedCost = existing?.cost_price
    ?? (overrideCost > 0 ? overrideCost : sourceCost);
  const costIssue = !existing && confirmedCost <= 0
    ? 'Cost required'
    : !existing && confirmedCost >= retailPrice
      ? 'Cost must be below retail price'
      : '';
  const repairDeskImage = imageByName.get(normalizeKey(originalName)) ?? '';
  const imageUrl = existing?.image_url ?? repairDeskImage;
  let barcode = existing?.barcode ?? '';
  if (!existing) {
    barcode = validBarcode(sourceUpc) && !usedBarcodes.has(sourceUpc)
      ? sourceUpc
      : ean13FromSourceId(sourceId);
    if (usedBarcodes.has(barcode)) {
      throw new Error(`Barcode collision for source item ${sourceId}: ${barcode}`);
    }
    usedBarcodes.add(barcode);
  }
  const removedFromCatalog = !existing && removedSourceIds.has(sourceId);
  const isReady = Boolean(existing || (!removedFromCatalog && !costIssue && imageUrl));
  return {
    sourceId,
    existing,
    sku,
    barcode,
    originalName,
    proposedName,
    brand: existing?.brand ?? brandFromName(proposedName),
    cableType,
    length,
    sourceCategory,
    sourceSku,
    sourceUpc,
    sourceQuantity: numberValue(row[15]),
    sourceCost,
    overrideCost: overrideCost > 0 ? overrideCost : null,
    confirmedCost,
    retailPrice: existing?.sale_price ?? retailPrice,
    sourcePosVisible: String(row[35] ?? '').trim().toUpperCase() === 'YES',
    imageUrl,
    costIssue,
    removedFromCatalog,
    isReady,
  };
});

const existingMatches = products.filter((product) => product.existing);
const removedProducts = products.filter((product) => product.removedFromCatalog);
const newProducts = products.filter((product) => !product.existing && !product.removedFromCatalog);
const readyNewProducts = newProducts.filter((product) => product.isReady);
const blockedNewProducts = newProducts.filter((product) => !product.isReady);
const costReviewProducts = newProducts.filter((product) => product.costIssue);
const missingImageProducts = products.filter((product) => !product.existing && !product.imageUrl);

const importPayload = {
  generated_at: new Date().toISOString(),
  source_file: 'products (16).xlsx',
  category: { slug: 'cable', name: 'Cable' },
  release_policy: {
    existing_products_unchanged: true,
    inventory_imported: false,
    zero_stock_checkout_allowed: true,
    online_visible: false,
    invalid_cost_blocked: true,
    missing_image_products_removed: true,
  },
  products: newProducts.map((product) => ({
    sku: product.sku,
    slug: slugify(product.sku),
    name: product.proposedName,
    brand: product.brand,
    model: product.cableType,
    short_description: [product.cableType, product.length ? `Length: ${product.length}.` : null]
      .filter(Boolean)
      .join('. ')
      .replace('..', '.'),
    condition_label: 'Brand New',
    compatibility: product.cableType,
    cost_price: product.costIssue ? null : product.confirmedCost,
    retail_price: product.retailPrice,
    image_url: product.imageUrl,
    stock_quantity: 0,
    is_visible: false,
    is_pos_visible: product.isReady,
    upc: product.barcode,
    variant_name: product.length,
    variant_color: null,
    source_system: 'repairdesk_cables',
    source_external_id: product.sourceId,
    source_category_path: product.sourceCategory.startsWith('1. Phone Cables & OTG Adapter')
      ? product.sourceCategory
      : `1. Phone Cables & OTG Adapter > ${product.sourceCategory}`,
    import_status: product.isReady ? 'active' : 'blocked',
    source_metadata: {
      original_name: product.originalName,
      original_sku: product.sourceSku,
      original_upc: product.sourceUpc,
      source_stock: product.sourceQuantity,
      proposed_stock: 0,
      inventory_assignment: 'none',
      source_pos_visible: product.sourcePosVisible,
      cable_type: product.cableType,
      cable_length: product.length,
      cost_status: product.costIssue || 'valid',
      cost_source: product.overrideCost ? 'owner_override' : 'repairdesk_source',
      image_status: product.imageUrl ? 'available' : 'missing',
    },
  })),
  existing_products_unchanged: existingMatches.map((product) => ({
    source_external_id: product.sourceId,
    product_id: product.existing.id,
    sku: product.existing.sku,
    name: product.existing.name,
  })),
  removed_products: removedProducts.map((product) => ({
    source_external_id: product.sourceId,
    sku: product.sku,
    name: product.proposedName,
    reason: costOverridePayload.removal_reason,
  })),
};

const workbook = Workbook.create();
const summarySheet = workbook.worksheets.add('Import Summary');
const productSheet = workbook.worksheets.add('Product Review');
const categorySheet = workbook.worksheets.add('Category Plan');
const costSheet = workbook.worksheets.add('Cost Review');
const imageSheet = workbook.worksheets.add('Missing Images');
for (const sheet of workbook.worksheets.items) sheet.showGridLines = false;

summarySheet.getRange('A1:H1').merge();
summarySheet.getRange('A1').values = [['TECHM8 Cable Catalog Import Review']];
summarySheet.getRange('A1:H1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF', size: 18 }, verticalAlignment: 'center' };
summarySheet.getRange('A1:H1').format.rowHeight = 34;
summarySheet.getRange('A3:B11').values = [
  ['Metric', 'Value'],
  ['Source products', products.length],
  ['Existing POS products left unchanged', existingMatches.length],
  ['New product records', newProducts.length],
  ['New products active in POS', readyNewProducts.length],
  ['New products blocked pending review', blockedNewProducts.length],
  ['New products needing cost correction', costReviewProducts.length],
  ['Products removed because image is missing', removedProducts.length],
  ['Source stock imported', 0],
];
summarySheet.getRange('A3:B3').format = { fill: '#DFF4EF', font: { bold: true, color: '#075E54' } };
summarySheet.getRange('B4:B11').format.numberFormat = '0';
summarySheet.getRange('D3:H3').merge();
summarySheet.getRange('D3').values = [['Catalog Rules']];
summarySheet.getRange('D3:H3').format = { fill: '#EAF2FF', font: { bold: true, color: '#204B7A' } };
summarySheet.getRange('D4:H10').merge(true);
summarySheet.getRange('D4:H10').values = [
  ['Keep one employee-facing top-level category: Cable.'],
  ['Save connector type and length as product metadata.'],
  ['Do not change any existing SKU, name, price, image, or inventory.'],
  ['Generate a TECHM8 SKU only for products missing from the new POS.'],
  ['All new store and website stock starts at zero.'],
  ['Zero stock remains available for checkout.'],
  ['Remove products without a source image; block only invalid costs.'],
];
summarySheet.getRange('D4:H10').format = { wrapText: true, fill: '#F7FAFC', font: { color: '#243640' } };
summarySheet.getRange('A13:H13').merge();
summarySheet.getRange('A13').values = [[costReviewProducts.length
  ? 'Use the separate cost workbook to correct blocked costs. Existing products are intentionally excluded from that workbook.'
  : 'All retained products have a confirmed cost and image and are ready for the POS.']];
summarySheet.getRange('A13:H13').format = { fill: costReviewProducts.length ? '#FFF1B8' : '#DFF4EF', font: { bold: true, color: costReviewProducts.length ? '#6B4F00' : '#075E54' }, wrapText: true };
summarySheet.getRange('A:H').format.columnWidth = 16;
summarySheet.getRange('A:A').format.columnWidth = 44;
summarySheet.getRange('D:H').format.columnWidth = 19;

const productHeaders = [
  'Source Item ID', 'Status', 'POS SKU', 'Barcode', 'Original Name', 'POS Product Name', 'Cable Type', 'Length',
  'Source Category', 'Cost', 'Retail', 'Image URL', 'Source Qty', 'Source POS Visible', 'New POS Visible',
  'Online Visible', 'Original SKU', 'Original UPC', 'Review Notes',
];
productSheet.getRange('A1:S1').values = [productHeaders];
productSheet.getRange(`A2:S${products.length + 1}`).values = products.map((product) => [
  product.sourceId,
  product.existing ? 'Existing - unchanged' : product.removedFromCatalog ? 'Removed - no image' : product.isReady ? 'New - active' : 'New - blocked',
  product.sku,
  product.barcode,
  product.originalName,
  product.proposedName,
  product.cableType,
  product.length,
  product.sourceCategory,
  product.existing ? product.existing.cost_price : product.confirmedCost || null,
  product.retailPrice,
  product.imageUrl,
  product.sourceQuantity,
  product.sourcePosVisible ? 'YES' : 'NO',
  product.existing ? (product.existing.is_pos_visible ? 'YES' : 'NO') : product.isReady ? 'YES' : 'NO',
  'NO',
  product.sourceSku,
  product.sourceUpc,
  product.existing
    ? 'Existing record preserved exactly.'
    : product.removedFromCatalog
      ? costOverridePayload.removal_reason
      : [product.costIssue, !product.imageUrl ? 'Image required' : '', product.overrideCost ? 'Owner-confirmed cost applied' : '', product.sourceQuantity !== 0 ? 'Source stock reset to zero' : '']
      .filter(Boolean)
      .join('; '),
]);
productSheet.tables.add(`A1:S${products.length + 1}`, true, 'CableCatalogReview');
productSheet.freezePanes.freezeRows(1);
productSheet.getRange('A1:S1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
productSheet.getRange(`A2:S${products.length + 1}`).format.wrapText = true;
productSheet.getRange('A:D').format.columnWidth = 18;
productSheet.getRange('E:F').format.columnWidth = 38;
productSheet.getRange('G:I').format.columnWidth = 24;
productSheet.getRange('J:K').format.columnWidth = 14;
productSheet.getRange('L:L').format.columnWidth = 48;
productSheet.getRange('M:S').format.columnWidth = 18;
productSheet.getRange(`D2:D${products.length + 1}`).format.numberFormat = '0';
productSheet.getRange(`J2:K${products.length + 1}`).format.numberFormat = '$#,##0.00';
productSheet.getRange(`M2:M${products.length + 1}`).format.numberFormat = '0';

const categoryCounts = new Map();
for (const product of products.filter((product) => !product.removedFromCatalog)) {
  const key = `${product.cableType}|${product.length ?? 'Not stated'}`;
  categoryCounts.set(key, (categoryCounts.get(key) ?? 0) + 1);
}
const categoryRows = [...categoryCounts.entries()]
  .map(([key, count]) => {
    const [type, length] = key.split('|');
    return ['Cable', type, length, count, 'Keep under Cable; use type and length as metadata/search terms.'];
  })
  .sort((left, right) => left[1].localeCompare(right[1]) || left[2].localeCompare(right[2]));
categorySheet.getRange('A1:E1').values = [['Top-Level POS Category', 'Cable Type', 'Length', 'Product Count', 'Recommendation']];
categorySheet.getRange(`A2:E${categoryRows.length + 1}`).values = categoryRows;
categorySheet.tables.add(`A1:E${categoryRows.length + 1}`, true, 'CableCategoryPlan');
categorySheet.freezePanes.freezeRows(1);
categorySheet.getRange('A1:E1').format = { fill: '#204B7A', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
categorySheet.getRange(`A2:E${categoryRows.length + 1}`).format.wrapText = true;
categorySheet.getRange('A:D').format.columnWidth = 24;
categorySheet.getRange('E:E').format.columnWidth = 58;

const costHeaders = ['Source Item ID', 'New SKU', 'Product Name', 'Cable Type', 'Length', 'Retail Price', 'Current Cost', 'Cost To Enter', 'Reason'];
costSheet.getRange('A1:I1').values = [costHeaders];
if (costReviewProducts.length) {
  costSheet.getRange(`A2:I${costReviewProducts.length + 1}`).values = costReviewProducts.map((product) => [
    product.sourceId, product.sku, product.proposedName, product.cableType, product.length,
    product.retailPrice, product.sourceCost || null, null, product.costIssue,
  ]);
  costSheet.tables.add(`A1:I${costReviewProducts.length + 1}`, true, 'CableCostReview');
  costSheet.getRange(`A2:I${costReviewProducts.length + 1}`).format.wrapText = true;
  costSheet.getRange(`H2:H${costReviewProducts.length + 1}`).format = { fill: '#FFF1B8', font: { bold: true, color: '#6B4F00' } };
  costSheet.getRange(`F2:H${costReviewProducts.length + 1}`).format.numberFormat = '$#,##0.00';
}
costSheet.freezePanes.freezeRows(1);
costSheet.getRange('A1:I1').format = { fill: '#9C2F22', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
costSheet.getRange('A:B').format.columnWidth = 18;
costSheet.getRange('C:D').format.columnWidth = 36;
costSheet.getRange('E:I').format.columnWidth = 18;

const imageHeaders = ['Source Item ID', 'New SKU', 'Product Name', 'Source POS Visible', 'Cost Status', 'Reason'];
imageSheet.getRange('A1:F1').values = [imageHeaders];
if (missingImageProducts.length) {
  imageSheet.getRange(`A2:F${missingImageProducts.length + 1}`).values = missingImageProducts.map((product) => [
    product.sourceId, product.sku, product.proposedName, product.sourcePosVisible ? 'YES' : 'NO', product.costIssue || 'Valid', product.removedFromCatalog ? costOverridePayload.removal_reason : 'No product image found in RepairDesk POS.',
  ]);
  imageSheet.tables.add(`A1:F${missingImageProducts.length + 1}`, true, 'CableMissingImages');
  imageSheet.getRange(`A2:F${missingImageProducts.length + 1}`).format.wrapText = true;
}
imageSheet.freezePanes.freezeRows(1);
imageSheet.getRange('A1:F1').format = { fill: '#59636B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
imageSheet.getRange('A:B').format.columnWidth = 18;
imageSheet.getRange('C:C').format.columnWidth = 42;
imageSheet.getRange('D:F').format.columnWidth = 24;

const costWorkbook = Workbook.create();
const costInputSheet = costWorkbook.worksheets.add('Costs To Complete');
costInputSheet.showGridLines = false;
costInputSheet.getRange('A1:I1').merge();
costInputSheet.getRange('A1').values = [['TECHM8 Cables - Costs To Complete']];
costInputSheet.getRange('A1:I1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF', size: 18 }, verticalAlignment: 'center' };
costInputSheet.getRange('A1:I1').format.rowHeight = 34;
costInputSheet.getRange('A2:I2').merge();
costInputSheet.getRange('A2').values = [['Enter the unit cost in the yellow Cost To Enter column. Existing POS products are not included and will not be changed.']];
costInputSheet.getRange('A2:I2').format = { fill: '#EAF2FF', font: { bold: true, color: '#204B7A' }, wrapText: true };
costInputSheet.getRange('A4:I4').values = [costHeaders];
costInputSheet.freezePanes.freezeRows(4);
costInputSheet.getRange('A4:I4').format = { fill: '#9C2F22', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
if (costReviewProducts.length) {
  costInputSheet.getRange(`A5:I${costReviewProducts.length + 4}`).values = costReviewProducts.map((product) => [
    product.sourceId, product.sku, product.proposedName, product.cableType, product.length,
    product.retailPrice, product.sourceCost || null, null, product.costIssue,
  ]);
  costInputSheet.tables.add(`A4:I${costReviewProducts.length + 4}`, true, 'CableCostsToComplete');
  costInputSheet.getRange(`A5:I${costReviewProducts.length + 4}`).format.wrapText = true;
  costInputSheet.getRange(`H5:H${costReviewProducts.length + 4}`).format = { fill: '#FFF1B8', font: { bold: true, color: '#6B4F00' } };
  costInputSheet.getRange(`F5:H${costReviewProducts.length + 4}`).format.numberFormat = '$#,##0.00';
} else {
  costInputSheet.getRange('A5:I5').merge();
  costInputSheet.getRange('A5').values = [['No cost updates are outstanding.']];
  costInputSheet.getRange('A5:I5').format = { fill: '#DFF4EF', font: { bold: true, color: '#075E54' } };
}
costInputSheet.getRange('A:B').format.columnWidth = 18;
costInputSheet.getRange('C:D').format.columnWidth = 36;
costInputSheet.getRange('E:I').format.columnWidth = 18;

const summaryInspection = await workbook.inspect({
  kind: 'table', sheetId: 'Import Summary', range: 'A1:H13', include: 'values,formulas', tableMaxRows: 20, tableMaxCols: 10,
});
const formulaErrors = await workbook.inspect({
  kind: 'match', searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A', options: { useRegex: true, maxResults: 200 }, summary: 'cable catalog formula error scan',
});
const costFormulaErrors = await costWorkbook.inspect({
  kind: 'match', searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A', options: { useRegex: true, maxResults: 200 }, summary: 'cable cost formula error scan',
});

const previews = [
  [workbook, 'Import Summary', 'A1:H13', 'summary.png'],
  [workbook, 'Product Review', `A1:S${products.length + 1}`, 'products.png'],
  [workbook, 'Category Plan', `A1:E${categoryRows.length + 1}`, 'category-plan.png'],
  [workbook, 'Cost Review', `A1:I${Math.max(2, costReviewProducts.length + 1)}`, 'cost-review.png'],
  [workbook, 'Missing Images', `A1:F${Math.max(2, missingImageProducts.length + 1)}`, 'missing-images.png'],
  [costWorkbook, 'Costs To Complete', `A1:I${Math.max(5, costReviewProducts.length + 4)}`, 'costs-to-complete.png'],
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
join public.categories category on category.slug = 'cable'
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
    stock_quantity = 0,
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

delete from public.products
where source_system = 'repairdesk_cables'
  and source_external_id in (
    select jsonb_array_elements_text(${jsonLiteral(importPayload.removed_products.map((product) => product.source_external_id))})
  );

commit;

select
  count(*) as imported_products,
  count(*) filter (where import_status = 'active' and is_pos_visible) as active_pos_products,
  count(*) filter (where import_status = 'blocked') as blocked_products,
  count(*) filter (where stock_quantity <> 0) as products_with_stock
from public.products
where source_system = 'repairdesk_cables';
`;
await fs.writeFile(importSqlPath, importSql, 'utf8');

console.log(JSON.stringify({
  sourceProducts: products.length,
  existingProductsUnchanged: existingMatches.length,
  newProducts: newProducts.length,
  readyNewProducts: readyNewProducts.length,
  blockedNewProducts: blockedNewProducts.length,
  removedProducts: removedProducts.length,
  costReviewProducts: costReviewProducts.length,
  missingImageProducts: missingImageProducts.length,
  cleanedImages: cleanImageRows.length,
  reviewWorkbookPath,
  costWorkbookPath,
  importJsonPath,
  importSqlPath,
  previewDir,
  summaryInspection: summaryInspection.ndjson,
  formulaErrors: formulaErrors.ndjson,
  costFormulaErrors: costFormulaErrors.ndjson,
}, null, 2));
