import fs from 'node:fs/promises';
import { FileBlob, SpreadsheetFile, Workbook } from '@oai/artifact-tool';

const sourcePath = process.argv[2] || 'E:/垃圾箱/products (13).xlsx';
const imageMapPath = process.argv[3] || 'D:/program/TECHM8 PRICE LIST/outputs/product-catalog-rebuild/RepairDesk_Tablet_Case_Images.json';
const outputPath = 'D:/program/TECHM8 PRICE LIST/outputs/product-catalog-rebuild/TECHM8_Tablet_Cases_Import_Review.xlsx';
const missingCostOutputPath = 'D:/program/TECHM8 PRICE LIST/outputs/product-catalog-rebuild/TECHM8_Tablet_Cases_Missing_Costs_Remaining.xlsx';
const costOverridePath = 'D:/program/TECHM8 PRICE LIST/outputs/product-catalog-rebuild/TECHM8_Tablet_Case_Cost_Overrides.json';
const importJsonPath = 'D:/program/TECHM8 PRICE LIST/outputs/product-catalog-rebuild/TECHM8_Tablet_Cases_Draft_Import.json';
const previewDir = 'C:/Users/User/AppData/Local/Temp/codex-product-catalog-rebuild/previews';

const source = await SpreadsheetFile.importXlsx(await FileBlob.load(sourcePath));
const sourceSheet = source.worksheets.getItem('Sheet1');
const matrix = sourceSheet.getRange('A1:AL290').values;
const sourceRows = matrix.slice(2).filter((row) => row.some((value) => value !== null && value !== ''));
const scrapedCategories = JSON.parse(await fs.readFile(imageMapPath, 'utf8'));
const costOverridePayload = JSON.parse(await fs.readFile(costOverridePath, 'utf8'));
const costOverrides = new Map(
  Object.entries(costOverridePayload.confirmed_costs ?? {}).map(([sku, cost]) => [sku, Number(cost)])
);

const normalizeKey = (value) => String(value ?? '').trim().toLowerCase().replace(/\s+/g, ' ');
const categoryLeaf = (value) => String(value ?? '').split('>').pop().trim();
const numberValue = (value) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};
const titleCase = (value) => String(value ?? '')
  .toLowerCase()
  .replace(/\b\w/g, (letter) => letter.toUpperCase());
const codePart = (value) => String(value ?? '')
  .toUpperCase()
  .replace(/[^A-Z0-9]+/g, '-')
  .replace(/^-+|-+$/g, '')
  .slice(0, 36);

const colorPatterns = [
  ['Rose Gold', /\brose\s+gold\b/i],
  ['Navy Blue', /\bnavy\s+blue\b/i],
  ['Sky Blue', /\bsky\s+blue\b/i],
  ['Light Blue', /\blight\s+blue\b/i],
  ['Dark Green', /\bdark\s+green\b/i],
  ['Light Green', /\blight\s+green\b/i],
  ['Assorted', /\bany\s+colou?r\b/i],
  ['Rainbow', /\brainbow\b/i],
  ['Purple', /\bpurple\b/i],
  ['Yellow', /\byellow\b/i],
  ['Brown', /\bbrown\b/i],
  ['Black', /\bblack\b/i],
  ['White', /\bwhite\b/i],
  ['Green', /\bgreen\b/i],
  ['Pink', /\bpink\b/i],
  ['Grey', /\bgr(?:e|a)y\b/i],
  ['Blue', /\bblue\b/i],
  ['Gold', /\bgold\b/i],
  ['Mint', /\bmint\b/i],
  ['Red', /\bred\b/i],
];

function colorFromName(name) {
  const match = colorPatterns.find(([, pattern]) => pattern.test(String(name ?? '')));
  return match ? match[0] : 'Unspecified';
}

function familyFromName(name) {
  const value = String(name ?? '');
  if (/z[- ]?flip/i.test(value)) return 'Z-Flip Case';
  if (/z[- ]?fold/i.test(value)) return 'Z-Fold Case';
  if (/twist\s+leather/i.test(value)) return 'Twist Leather Case';
  if (/hard\s+case/i.test(value) && /bubble/i.test(value)) return 'Bubble Hard Case';
  if (/hard\s+case/i.test(value)) return 'Hard Case';
  if (/survivor/i.test(value)) return 'Survivor Case';
  if (/flip\s+(?:over\s+)?case|flip\s+over/i.test(value)) return 'Flip Case';
  if (/\bcase\b/i.test(value)) return 'Tablet Case';
  return 'Unclassified Case';
}

const baseProfiles = {
  'iPad 10.2 Inch': {
    code: 'IPAD-102-GEN789',
    name: 'iPad 10.2-inch (Gen 7/8/9)',
    models: 'iPad 7th Gen 10.2; iPad 8th Gen 10.2; iPad 9th Gen 10.2',
    status: 'Proposed',
    question: 'Confirm that every case in this category fits all Gen 7, 8 and 9 devices.',
  },
  'iPad 10.9 inch/Pro 11': {
    code: 'IPAD-109-PRO11-LEGACY',
    name: 'iPad Air 4/5 and iPad Pro 11 (2018-2022)',
    models: 'iPad Air 4; iPad Air 5; iPad Pro 11-inch (2018); iPad Pro 11-inch (2020); iPad Pro 11-inch (2021); iPad Pro 11-inch (2022)',
    status: 'Approved',
    question: 'Owner confirmed Air 4/5 and iPad Pro 11-inch models from 2018, 2020, 2021 and 2022.',
  },
  'iPad 10th Gen 10.9 Inch': {
    code: 'IPAD-10-GEN10',
    name: 'iPad 10th Gen 10.9-inch',
    models: 'iPad 10th Gen 10.9',
    status: 'Proposed',
    question: 'Confirm whether any newer iPad model can use these cases.',
  },
  'iPad 12.9 inch': {
    code: 'IPAD-129-LEGACY',
    name: 'iPad Pro 12.9-inch (2018-2022)',
    models: 'iPad Pro 12.9-inch (2018); iPad Pro 12.9-inch (2020); iPad Pro 12.9-inch (2021); iPad Pro 12.9-inch (2022)',
    status: 'Approved',
    question: 'Owner confirmed the 2018, 2020, 2021 and 2022 iPad Pro 12.9-inch models.',
  },
  'iPad 9.7 Inch': {
    code: 'IPAD-97-LEGACY',
    name: 'iPad 9.7-inch (Gen 5/6 and Air 1/2)',
    models: 'iPad 5th Gen 9.7; iPad 6th Gen 9.7; iPad Air 1 9.7; iPad Air 2 9.7',
    status: 'Approved',
    question: 'Owner confirmed iPad Gen 5, Gen 6, Air 1 and Air 2.',
  },
  'iPad Air 11-inch 2024(Air 6': {
    code: 'IPAD-AIR11-2024',
    name: 'iPad Air 11-inch (2024)',
    models: 'iPad Air 11-inch M2 (2024)',
    status: 'Proposed',
    question: 'Confirm which older Air/Pro models, if any, can use this newer case.',
  },
  'iPad Air 13-inch 2024 (Air 6)': {
    code: 'IPAD-AIR13-2024',
    name: 'iPad Air 13-inch (2024)',
    models: 'iPad Air 13-inch M2 (2024)',
    status: 'Proposed',
    question: 'Confirm whether the 2025/2026 Air 13-inch uses the same case.',
  },
  'iPad Air 4/5, Pro 11': {
    code: 'IPAD-AIR45-PRO11',
    name: 'iPad Air 4/5 and iPad Pro 11 (2018-2022)',
    models: 'iPad Air 4; iPad Air 5; iPad Pro 11-inch (2018); iPad Pro 11-inch (2020); iPad Pro 11-inch (2021); iPad Pro 11-inch (2022)',
    status: 'Approved',
    question: 'Owner confirmed Air 4/5 and iPad Pro 11-inch models from 2018, 2020, 2021 and 2022.',
  },
  'iPad mini 4/5': {
    code: 'IPAD-MINI45',
    name: 'iPad mini 4/5',
    models: 'iPad mini 4; iPad mini 5',
    status: 'Proposed',
    question: 'Confirm both mini 4 and mini 5 use every case in this profile.',
  },
  'iPad mini 6': {
    code: 'IPAD-MINI6',
    name: 'iPad mini 6',
    models: 'iPad mini 6',
    status: 'Proposed',
    question: 'Confirm whether mini 7/A17 Pro is also supported by these cases.',
  },
  'iPad Pro 11-inch 2024': {
    code: 'IPAD-PRO11-2024',
    name: 'iPad Pro 11-inch (2024)',
    models: 'iPad Pro 11-inch M4 (2024)',
    status: 'Proposed',
    question: 'Confirm which older Pro 11 models, if any, can use this newer case.',
  },
  'iPad Pro 13-inch 2024': {
    code: 'IPAD-PRO13-2024',
    name: 'iPad Pro 13-inch (2024)',
    models: 'iPad Pro 13-inch M4 (2024)',
    status: 'Proposed',
    question: 'Confirm that older 12.9-inch cases are not assumed compatible in the reverse direction.',
  },
};

const samsungPatterns = [
  ['S10 Ultra', /\bs10\s+ultra\b/i],
  ['S10 Plus', /\bs10\s+plus\b/i],
  ['S10', /\bs10\b/i],
  ['S9 FE', /\bs9\s+fe\b/i],
  ['S9 Ultra', /\bs9\s+ultra\b/i],
  ['S9 Plus', /\bs9\s+plus\b/i],
  ['S9', /\bs9\b/i],
  ['S8 Ultra', /\bs8\s+ultra\b/i],
  ['S8 Plus', /\bs8\+|\bs8\s+plus\b/i],
  ['S7/S8', /\bs7\s*\/\s*s8\b/i],
  ['S7 Plus / FE', /\bs7\+\s*\/\s*fe|\bs7\s+plus\s*\/\s*fe/i],
  ['A11 Plus', /\ba11\s+plus\b/i],
  ['A9 Plus', /\ba9\s+plus\b/i],
  ['A8', /\ba8\b/i],
  ['A7', /\ba7\b/i],
];

function profileFor(category, name) {
  if (baseProfiles[category]) return { ...baseProfiles[category], sourceCategory: category };
  if (category === 'Universal case') {
    const size = String(name ?? '').match(/\b(7|8|10(?:\.2)?)\s*inch\b/i)?.[1] ?? 'Unknown';
    return {
      code: `UNIVERSAL-${codePart(size)}`,
      name: `Universal ${size}-inch tablet fit`,
      models: '',
      status: 'Proposed',
      question: 'Confirm minimum and maximum device dimensions; size alone is not an exact compatibility promise.',
      sourceCategory: category,
    };
  }
  if (category === 'Samsung Tablet') {
    const model = samsungPatterns.find(([, pattern]) => pattern.test(String(name ?? '')))?.[0] ?? `Unclassified ${name}`;
    return {
      code: `SAMSUNG-${codePart(model)}`,
      name: `Samsung Galaxy Tab ${model}`,
      models: model.startsWith('Unclassified') ? '' : `Samsung Galaxy Tab ${model}`,
      status: model.startsWith('Unclassified') ? 'Required' : 'Proposed',
      question: 'Confirm exact Samsung model number and year; similar names can have different body dimensions.',
      sourceCategory: category,
    };
  }
  return {
    code: `UNCLASSIFIED-${codePart(category)}`,
    name: category || 'Unclassified fit',
    models: '',
    status: 'Required',
    question: 'Compatibility mapping is required.',
    sourceCategory: category,
  };
}

function normalizedVariantName(family, profileName, color) {
  const colorText = color === 'Unspecified' ? '' : ` - ${color}`;
  return `${family} for ${profileName}${colorText}`;
}

function ean13FromSourceId(sourceId) {
  const digits = String(sourceId ?? '').replace(/\D/g, '').slice(-8).padStart(8, '0');
  const body = `2999${digits}`;
  let sum = 0;
  for (let index = 0; index < body.length; index += 1) {
    sum += Number(body[index]) * (index % 2 === 0 ? 1 : 3);
  }
  return `${body}${(10 - (sum % 10)) % 10}`;
}

const repairdeskByCategoryAndName = new Map();
for (const category of scrapedCategories) {
  for (const card of category.cards ?? []) {
    const key = `${normalizeKey(category.name)}||${normalizeKey(card.name)}`;
    if (!repairdeskByCategoryAndName.has(key)) repairdeskByCategoryAndName.set(key, card);
  }
}

const familyCodes = {
  'Twist Leather Case': 'TLC',
  'Z-Fold Case': 'ZFD',
  'Z-Flip Case': 'ZFL',
  'Hard Case': 'HDC',
  'Bubble Hard Case': 'BHC',
  'Survivor Case': 'SUR',
  'Flip Case': 'FLC',
  'Tablet Case': 'TBC',
  'Unclassified Case': 'UNC',
};

const candidateVariants = sourceRows.map((row) => {
  const sourceId = String(row[0] ?? '').trim();
  const originalName = String(row[4] ?? '').trim();
  const category = categoryLeaf(row[3]);
  const family = familyFromName(originalName);
  const color = colorFromName(originalName);
  const profile = profileFor(category, originalName);
  const groupCode = `TM8-GRP-${profile.code}-${familyCodes[family] ?? 'UNC'}`;
  const sourceKey = `${normalizeKey(category)}||${normalizeKey(originalName)}`;
  const repairdesk = repairdeskByCategoryAndName.get(sourceKey) ?? {};
  return {
    sourceId,
    newSku: `TM8-TAB-${sourceId}`,
    barcode: ean13FromSourceId(sourceId),
    originalName,
    proposedName: normalizedVariantName(family, profile.name, color),
    family,
    color,
    groupCode,
    groupName: `${family} for ${profile.name}`,
    sourceCategory: category,
    profile,
    variantImage: String(repairdesk.image_url ?? ''),
    groupImage: '',
    storeSlug: 'park-ridge',
    sourceStock: numberValue(row[15]),
    sourceCost: numberValue(row[17]),
    retailPrice: numberValue(row[19]),
    repairdeskProductId: String(repairdesk.repairdesk_product_id ?? ''),
    inventoryIndexId: String(repairdesk.inventory_index_id ?? ''),
  };
});

const candidateGroupMap = new Map();
for (const variant of candidateVariants) {
  if (!candidateGroupMap.has(variant.groupCode)) {
    candidateGroupMap.set(variant.groupCode, {
      code: variant.groupCode,
      name: variant.groupName,
      family: variant.family,
      profile: variant.profile,
      variants: [],
    });
  }
  candidateGroupMap.get(variant.groupCode).variants.push(variant);
}

function chooseGroupImage(group) {
  const imageRows = group.variants.filter((variant) => variant.variantImage);
  const priorities = ['Black', 'Blue', 'Grey', 'Pink', 'Green'];
  for (const color of priorities) {
    const match = imageRows.find((variant) => variant.color === color && variant.sourceStock > 0)
      ?? imageRows.find((variant) => variant.color === color);
    if (match) return match.variantImage;
  }
  return imageRows.find((variant) => variant.sourceStock > 0)?.variantImage ?? imageRows[0]?.variantImage ?? '';
}

for (const group of candidateGroupMap.values()) {
  const image = chooseGroupImage(group);
  for (const variant of group.variants) variant.groupImage = image;
}

const removedNoImageVariants = candidateVariants.filter((variant) => !variant.groupImage);
const variants = candidateVariants.filter((variant) => variant.groupImage);
const groupMap = new Map();
for (const variant of variants) {
  if (!groupMap.has(variant.groupCode)) {
    groupMap.set(variant.groupCode, {
      code: variant.groupCode,
      name: variant.groupName,
      family: variant.family,
      profile: variant.profile,
      variants: [],
    });
  }
  groupMap.get(variant.groupCode).variants.push(variant);
}

const profileMap = new Map();
for (const variant of variants) {
  if (!profileMap.has(variant.profile.code)) profileMap.set(variant.profile.code, variant.profile);
}

const groups = Array.from(groupMap.values()).sort((left, right) => left.name.localeCompare(right.name));
const profiles = Array.from(profileMap.values()).sort((left, right) => left.name.localeCompare(right.name));
const hardCaseCount = variants.filter((variant) => ['Hard Case', 'Bubble Hard Case'].includes(variant.family)).length;
const twistLeatherCount = variants.filter((variant) => variant.family === 'Twist Leather Case').length;
const zFoldFlipCount = variants.filter((variant) => ['Z-Fold Case', 'Z-Flip Case'].includes(variant.family)).length;
const imageMatchCount = variants.filter((variant) => variant.variantImage).length;
const negativeStockCount = variants.filter((variant) => variant.sourceStock < 0).length;

function proposedCost(variant) {
  if (['Hard Case', 'Bubble Hard Case'].includes(variant.family)) return 15;
  if (variant.family === 'Twist Leather Case') return 5;
  if (['Z-Fold Case', 'Z-Flip Case'].includes(variant.family)) return 4;
  const confirmedCost = costOverrides.get(variant.newSku);
  if (Number.isFinite(confirmedCost) && confirmedCost > 0) return confirmedCost;
  return variant.sourceCost > 0 ? variant.sourceCost : null;
}

function costRule(variant) {
  if (['Hard Case', 'Bubble Hard Case'].includes(variant.family)) return 'Confirmed: Hard Case';
  if (variant.family === 'Twist Leather Case') return 'Confirmed: Twist Leather Case';
  if (['Z-Fold Case', 'Z-Flip Case'].includes(variant.family)) return 'Confirmed: Z-Fold / Z-Flip Case';
  if (costOverrides.has(variant.newSku)) return 'Confirmed: Owner cost override';
  return variant.sourceCost > 0 ? 'Source cost' : 'Needs cost';
}

const missingCostVariants = variants.filter((variant) => proposedCost(variant) === null);
const unresolvedCostCount = missingCostVariants.length;

function slugify(value) {
  return String(value ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 120);
}

const deviceModelMap = new Map();
const compatibilityMappings = [];
for (const profile of profiles) {
  for (const modelName of String(profile.models ?? '').split(';').map((value) => value.trim()).filter(Boolean)) {
    const modelCode = `DEVICE-${codePart(modelName)}`;
    if (!deviceModelMap.has(modelCode)) {
      deviceModelMap.set(modelCode, {
        code: modelCode,
        brand: modelName.startsWith('Samsung') ? 'Samsung' : modelName.startsWith('Universal') ? 'Universal' : 'Apple',
        display_name: modelName,
        model_family: modelName.replace(/\s+(?:M\d|Gen\s*\d+|\(\d{4}\)).*$/i, '').trim(),
        generation: modelName.match(/(?:M\d|Gen\s*\d+|\d+(?:st|nd|rd|th)\s+Gen)/i)?.[0] ?? '',
        release_year: Number(modelName.match(/\b(20\d{2})\b/)?.[1]) || null,
      });
    }
    compatibilityMappings.push({ fit_profile_code: profile.code, device_model_code: modelCode });
  }
}

const importPayload = {
  generated_at: new Date().toISOString(),
  source_file: 'products (13).xlsx',
  category: {
    slug: 'ipad-tablet-cases',
    name: 'iPad & Tablet Cases',
  },
  release_policy: {
    all_rows_hidden: true,
    inventory_imported: false,
    compatibility_direction: 'fit_profile_to_supported_device_only',
  },
  fit_profiles: profiles.map((profile) => ({
    code: profile.code,
    display_name: profile.name,
    source_category: profile.sourceCategory,
    notes: profile.question,
    review_status: profile.status.toLowerCase(),
  })),
  device_models: Array.from(deviceModelMap.values()),
  compatibility_mappings: compatibilityMappings,
  product_groups: groups.map((group) => ({
    code: group.code,
    slug: slugify(group.code),
    name: group.name,
    product_family: group.family,
    fit_profile_code: group.profile.code,
    main_image_url: chooseGroupImage(group),
    status: 'draft',
    is_pos_visible: false,
    is_visible: false,
  })),
  products: variants.map((variant) => {
    const cost = proposedCost(variant);
    const groupHasImage = Boolean(variant.groupImage);
    const importStatus = cost === null || !groupHasImage || variant.profile.status === 'Required'
      ? 'blocked'
      : 'review';
    return {
      sku: variant.newSku,
      slug: slugify(variant.newSku),
      name: variant.proposedName,
      brand: variant.profile.code.startsWith('SAMSUNG-') ? 'Samsung' : variant.profile.code.startsWith('UNIVERSAL-') ? 'Universal' : 'Apple',
      model: variant.profile.name,
      short_description: `${variant.family} in ${variant.color}.`,
      condition_label: 'Brand New',
      compatibility: variant.profile.models,
      cost_price: cost,
      retail_price: variant.retailPrice,
      image_url: variant.variantImage || variant.groupImage,
      stock_quantity: 0,
      is_visible: false,
      is_pos_visible: false,
      upc: variant.barcode,
      product_group_code: variant.groupCode,
      variant_name: variant.color,
      variant_color: variant.color,
      source_system: 'repairdesk_tablet_cases',
      source_external_id: variant.sourceId,
      source_category_path: variant.sourceCategory,
      import_status: importStatus,
      source_metadata: {
        original_name: variant.originalName,
        source_stock: variant.sourceStock,
        proposed_stock: 0,
        inventory_assignment: 'none',
        repairdesk_product_id: variant.repairdeskProductId,
        inventory_index_id: variant.inventoryIndexId,
        variant_image_url: variant.variantImage,
        group_image_url: variant.groupImage,
        cost_rule: costRule(variant),
      },
    };
  }),
};

const workbook = Workbook.create();
const summary = workbook.worksheets.add('Import Summary');
const variantSheet = workbook.worksheets.add('Product Variants');
const groupSheet = workbook.worksheets.add('Product Groups');
const compatibilitySheet = workbook.worksheets.add('Compatibility Review');
const costSheet = workbook.worksheets.add('Cost Rules');
const costOverrideSheet = workbook.worksheets.add('Cost Overrides');
const issueSheet = workbook.worksheets.add('Data Issues');
const removedSheet = workbook.worksheets.add('Removed Products');

summary.showGridLines = false;
summary.getRange('A1:H1').merge();
summary.getRange('A1').values = [['TECHM8 Tablet Cases Import Review']];
summary.getRange('A1:H1').format = {
  fill: '#087F6B',
  font: { bold: true, color: '#FFFFFF', size: 18 },
  verticalAlignment: 'center',
};
summary.getRange('A1:H1').format.rowHeight = 34;
summary.getRange('A3:B14').values = [
  ['Metric', 'Value'],
  ['Imported variants', variants.length],
  ['Removed products with no usable group image', removedNoImageVariants.length],
  ['Proposed product groups', groups.length],
  ['Fit profiles requiring review', profiles.filter((profile) => profile.status === 'Required').length],
  ['RepairDesk variant images matched', imageMatchCount],
  ['Missing variant images', variants.length - imageMatchCount],
  ['Negative stock rows clipped to zero', negativeStockCount],
  ['Hard Case rows forced to $15 cost', hardCaseCount],
  ['Twist Leather Case rows forced to $5 cost', twistLeatherCount],
  ['Z-Fold / Z-Flip Case rows forced to $4 cost', zFoldFlipCount],
  ['Rows still missing a valid cost', unresolvedCostCount],
];
summary.getRange('A3:B3').format = { fill: '#DFF4EF', font: { bold: true, color: '#075E54' } };
summary.getRange('B4:B14').format.numberFormat = '0';
summary.getRange('D3:H3').merge();
summary.getRange('D3').values = [['Release Gate']];
summary.getRange('D3:H3').format = { fill: '#FDE7E3', font: { bold: true, color: '#9C2F22' } };
summary.getRange('D4:H9').merge(true);
summary.getRange('D4:H9').values = [
  ['All rows are drafts: POS Visible = NO and Online Visible = NO.'],
  ['Compatibility is directional: a newer case may list older devices without adding the newer device to the old case.'],
  ['Every store and the online store start at zero stock. Zero stock does not block POS checkout or online ordering.'],
  ['Original SKU and UPC values are ignored. Every variant receives a new unique SKU and EAN-13 barcode.'],
  ['Rows with missing cost, missing image, or Required compatibility cannot be activated.'],
  ['One group main image is used by POS and the website; variant images are retained only for audit.'],
];
summary.getRange('D4:H9').format = { wrapText: true, fill: '#FFF8F0', font: { color: '#4A332A' } };
summary.getRange('A16:H16').merge();
summary.getRange('A16').values = [['Recommended approval order: complete missing costs -> confirm any remaining fit profiles -> review images -> activate approved product groups. All store and online stock remains zero until manually adjusted.']];
summary.getRange('A16:H16').format = { wrapText: true, fill: '#EAF2FF', font: { bold: true, color: '#204B7A' } };
summary.getRange('A:H').format.columnWidth = 16;
summary.getRange('A:A').format.columnWidth = 44;
summary.getRange('D:H').format.columnWidth = 18;

const costOverrideRows = Array.from(costOverrides.entries()).sort(([left], [right]) => left.localeCompare(right, undefined, { numeric: true }));
const costOverrideEndRow = costOverrideRows.length + 1;
costOverrideSheet.getRange('A1:C1').values = [['New SKU', 'Confirmed Cost', 'Source']];
costOverrideSheet.getRange(`A2:C${costOverrideEndRow}`).values = costOverrideRows.map(([sku, cost]) => [
  sku,
  cost,
  costOverridePayload.source_workbook || 'Owner-confirmed cost workbook',
]);
costOverrideSheet.tables.add(`A1:C${costOverrideEndRow}`, true, 'TabletCaseCostOverrides');
costOverrideSheet.freezePanes.freezeRows(1);
costOverrideSheet.getRange('A1:C1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' } };
costOverrideSheet.getRange(`B2:B${costOverrideEndRow}`).format.numberFormat = '$#,##0.00';
costOverrideSheet.getRange('A:A').format.columnWidth = 20;
costOverrideSheet.getRange('B:B').format.columnWidth = 18;
costOverrideSheet.getRange('C:C').format.columnWidth = 46;

const variantHeaders = [
  'Source Item ID', 'New SKU', 'New Barcode', 'Original Name', 'Proposed Name', 'Product Family', 'Color',
  'Group Code', 'Group Name', 'Source Category', 'Fit Profile Code', 'Fit Profile Name', 'Compatibility Status',
  'Variant Image URL', 'Group Main Image URL', 'Store Slug', 'Source Stock', 'Proposed Stock', 'Source Cost',
  'Proposed Cost', 'Cost Rule', 'Retail Price', 'Online Price', 'POS Visible', 'Online Visible',
  'RepairDesk Product ID', 'Inventory Index ID', 'Data Status', 'Notes',
];
variantSheet.getRange('A1:AC1').values = [variantHeaders];
variantSheet.getRange(`A2:AC${variants.length + 1}`).values = variants.map((variant) => [
  variant.sourceId,
  variant.newSku,
  variant.barcode,
  variant.originalName,
  variant.proposedName,
  variant.family,
  variant.color,
  variant.groupCode,
  variant.groupName,
  variant.sourceCategory,
  variant.profile.code,
  variant.profile.name,
  variant.profile.status,
  variant.variantImage,
  variant.groupImage,
  variant.storeSlug,
  variant.sourceStock,
  null,
  variant.sourceCost,
  null,
  null,
  variant.retailPrice,
  null,
  'NO',
  'NO',
  variant.repairdeskProductId,
  variant.inventoryIndexId,
  null,
  [
    variant.sourceStock < 0 ? 'Negative source stock clipped to zero.' : '',
    !variant.variantImage ? 'Variant image missing; group image fallback used where available.' : '',
    variant.profile.status === 'Required' ? 'Compatibility requires owner confirmation.' : '',
  ].filter(Boolean).join(' '),
]);
variantSheet.getRange('R2').formulas = [['=MAX(0,Q2)']];
variantSheet.getRange(`R2:R${variants.length + 1}`).fillDown();
variantSheet.getRange('T2').formulas = [[
  `=IF(OR(F2="Hard Case",F2="Bubble Hard Case"),15,IF(F2="Twist Leather Case",5,IF(OR(F2="Z-Fold Case",F2="Z-Flip Case"),4,IFERROR(VLOOKUP(B2,'Cost Overrides'!$A$2:$B$${costOverrideEndRow},2,FALSE),S2))))`,
]];
variantSheet.getRange(`T2:T${variants.length + 1}`).fillDown();
variantSheet.getRange('U2').formulas = [[
  `=IF(OR(F2="Hard Case",F2="Bubble Hard Case"),"Confirmed: Hard Case",IF(F2="Twist Leather Case","Confirmed: Twist Leather Case",IF(OR(F2="Z-Fold Case",F2="Z-Flip Case"),"Confirmed: Z-Fold / Z-Flip Case",IF(COUNTIF('Cost Overrides'!$A$2:$A$${costOverrideEndRow},B2)>0,"Confirmed: Owner cost override",IF(S2<=0,"Needs cost","Source cost")))))`,
]];
variantSheet.getRange(`U2:U${variants.length + 1}`).fillDown();
variantSheet.getRange('W2').formulas = [['=V2']];
variantSheet.getRange(`W2:W${variants.length + 1}`).fillDown();
variantSheet.getRange('AB2').formulas = [['=IF(OR(M2<>"Approved",U2="Needs cost",O2=""),"Needs review","Ready after approval")']];
variantSheet.getRange(`AB2:AB${variants.length + 1}`).fillDown();
variantSheet.tables.add(`A1:AC${variants.length + 1}`, true, 'ProductVariantsReview');
variantSheet.freezePanes.freezeRows(1);
variantSheet.getRange('A1:AC1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
variantSheet.getRange(`Q2:W${variants.length + 1}`).format.numberFormat = '$#,##0.00';
variantSheet.getRange(`Q2:R${variants.length + 1}`).format.numberFormat = '0';
variantSheet.getRange(`S2:W${variants.length + 1}`).format.numberFormat = '$#,##0.00';
variantSheet.getRange(`A1:AC${variants.length + 1}`).format.verticalAlignment = 'top';
variantSheet.getRange(`D2:O${variants.length + 1}`).format.wrapText = true;
variantSheet.getRange(`AB2:AC${variants.length + 1}`).format.wrapText = true;
variantSheet.getRange(`AB2:AB${variants.length + 1}`).conditionalFormats.add('containsText', {
  text: 'Needs review',
  format: { fill: '#FDE7E3', font: { color: '#9C2F22', bold: true } },
});
variantSheet.getRange(`Q2:Q${variants.length + 1}`).conditionalFormats.add('cellIs', {
  operator: 'lessThan',
  formula: 0,
  format: { fill: '#FDE7E3', font: { color: '#9C2F22', bold: true } },
});
variantSheet.getRange('A:C').format.columnWidth = 18;
variantSheet.getRange('D:E').format.columnWidth = 34;
variantSheet.getRange('F:G').format.columnWidth = 18;
variantSheet.getRange('H:I').format.columnWidth = 32;
variantSheet.getRange('J:M').format.columnWidth = 24;
variantSheet.getRange('N:O').format.columnWidth = 42;
variantSheet.getRange('P:W').format.columnWidth = 16;
variantSheet.getRange('X:Y').format.columnWidth = 14;
variantSheet.getRange('Z:AA').format.columnWidth = 19;
variantSheet.getRange('AB:AC').format.columnWidth = 28;

const groupHeaders = ['Group Code', 'Group Name', 'Product Family', 'Fit Profile Code', 'Fit Profile Name', 'Variant Count', 'Colors', 'Retail Price Range', 'Group Main Image URL', 'Compatibility Status', 'Online Visible'];
groupSheet.getRange('A1:K1').values = [groupHeaders];
groupSheet.getRange(`A2:K${groups.length + 1}`).values = groups.map((group) => {
  const prices = group.variants.map((variant) => variant.retailPrice);
  const minPrice = Math.min(...prices);
  const maxPrice = Math.max(...prices);
  return [
    group.code,
    group.name,
    group.family,
    group.profile.code,
    group.profile.name,
    group.variants.length,
    Array.from(new Set(group.variants.map((variant) => variant.color))).sort().join(', '),
    minPrice === maxPrice ? `$${minPrice.toFixed(2)}` : `$${minPrice.toFixed(2)} - $${maxPrice.toFixed(2)}`,
    chooseGroupImage(group),
    group.profile.status,
    'NO',
  ];
});
groupSheet.tables.add(`A1:K${groups.length + 1}`, true, 'ProductGroupsReview');
groupSheet.freezePanes.freezeRows(1);
groupSheet.getRange('A1:K1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
groupSheet.getRange(`A2:K${groups.length + 1}`).format.wrapText = true;
groupSheet.getRange('A:E').format.columnWidth = 28;
groupSheet.getRange('F:H').format.columnWidth = 18;
groupSheet.getRange('I:I').format.columnWidth = 44;
groupSheet.getRange('J:K').format.columnWidth = 20;

const compatibilityHeaders = ['Fit Profile Code', 'Display Name', 'Source Category', 'Proposed Compatible Device Models', 'Direction Rule', 'Review Status', 'Owner Confirmation Needed'];
compatibilitySheet.getRange('A1:G1').values = [compatibilityHeaders];
compatibilitySheet.getRange(`A2:G${profiles.length + 1}`).values = profiles.map((profile) => [
  profile.code,
  profile.name,
  profile.sourceCategory,
  profile.models,
  'This case profile -> listed devices only. Never infer the reverse mapping.',
  profile.status,
  profile.question,
]);
compatibilitySheet.tables.add(`A1:G${profiles.length + 1}`, true, 'CompatibilityProfilesReview');
compatibilitySheet.freezePanes.freezeRows(1);
compatibilitySheet.getRange('A1:G1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
compatibilitySheet.getRange(`A2:G${profiles.length + 1}`).format.wrapText = true;
compatibilitySheet.getRange(`F2:F${profiles.length + 1}`).conditionalFormats.add('containsText', {
  text: 'Required',
  format: { fill: '#FDE7E3', font: { color: '#9C2F22', bold: true } },
});
compatibilitySheet.getRange('A:A').format.columnWidth = 25;
compatibilitySheet.getRange('B:D').format.columnWidth = 34;
compatibilitySheet.getRange('E:E').format.columnWidth = 40;
compatibilitySheet.getRange('F:F').format.columnWidth = 18;
compatibilitySheet.getRange('G:G').format.columnWidth = 48;

costSheet.getRange('A1:F1').values = [['Priority', 'Product Family', 'Color', 'Proposed Cost', 'Status', 'Interpretation Used']];
costSheet.getRange('A2:F6').values = [
  [1, 'Hard Case / Bubble Hard Case', 'Any', 15, 'Confirmed', 'All names containing Hard Case, including Bubble Hard Case.'],
  [2, 'Twist Leather Case', 'Any', 5, 'Confirmed', 'Applies to every Twist Leather Case colour.'],
  [3, 'Z-Fold Case / Z-Flip Case', 'Any', 4, 'Confirmed', 'Applies to every Z-Fold and Z-Flip Case colour.'],
  [4, 'Owner-confirmed override', 'Any', null, 'Confirmed', 'Use the cost saved in the Cost Overrides sheet.'],
  [5, 'All other products', 'Any', null, 'Review fallback', 'Keep source cost; rows with zero source cost remain blocked.'],
];
costSheet.tables.add('A1:F6', true, 'CatalogCostRules');
costSheet.freezePanes.freezeRows(1);
costSheet.getRange('A1:F1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
costSheet.getRange('D2:D6').format.numberFormat = '$#,##0.00';
costSheet.getRange('A:F').format.columnWidth = 24;
costSheet.getRange('F:F').format.columnWidth = 54;
costSheet.getRange('A1:F6').format.wrapText = true;

const issueRows = [];
for (const variant of variants) {
  if (variant.sourceStock < 0) issueRows.push([variant.sourceId, variant.originalName, 'Negative stock', variant.sourceStock, 'Proposed stock is zero; confirm physical count.']);
  if (proposedCost(variant) === null) issueRows.push([variant.sourceId, variant.originalName, 'Missing cost', variant.sourceCost, 'Provide a cost before activation.']);
  if (!variant.variantImage) issueRows.push([variant.sourceId, variant.originalName, 'Missing variant image', '', variant.groupImage ? 'Group image fallback is available.' : 'No RepairDesk image found for this group.']);
  if (variant.profile.status === 'Required') issueRows.push([variant.sourceId, variant.originalName, 'Compatibility required', variant.profile.code, variant.profile.question]);
}
issueSheet.getRange('A1:E1').values = [['Source Item ID', 'Original Name', 'Issue Type', 'Current Value', 'Required Action']];
issueSheet.getRange(`A2:E${issueRows.length + 1}`).values = issueRows;
issueSheet.tables.add(`A1:E${issueRows.length + 1}`, true, 'CatalogDataIssues');
issueSheet.freezePanes.freezeRows(1);
issueSheet.getRange('A1:E1').format = { fill: '#9C2F22', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
issueSheet.getRange(`A2:E${issueRows.length + 1}`).format.wrapText = true;
issueSheet.getRange('A:A').format.columnWidth = 18;
issueSheet.getRange('B:B').format.columnWidth = 38;
issueSheet.getRange('C:D').format.columnWidth = 22;
issueSheet.getRange('E:E').format.columnWidth = 52;

removedSheet.getRange('A1:H1').values = [[
  'Source Item ID', 'New SKU', 'Original Name', 'Proposed Name', 'Source Category', 'Reason Removed', 'Variant Image URL', 'Group Main Image URL',
]];
removedSheet.getRange(`A2:H${removedNoImageVariants.length + 1}`).values = removedNoImageVariants.map((variant) => [
  variant.sourceId,
  variant.newSku,
  variant.originalName,
  variant.proposedName,
  variant.sourceCategory,
  'Removed because no usable product or group image exists.',
  variant.variantImage,
  variant.groupImage,
]);
removedSheet.tables.add(`A1:H${removedNoImageVariants.length + 1}`, true, 'RemovedProductsAudit');
removedSheet.freezePanes.freezeRows(1);
removedSheet.getRange('A1:H1').format = { fill: '#59636B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
removedSheet.getRange(`A2:H${removedNoImageVariants.length + 1}`).format.wrapText = true;
removedSheet.getRange('A:B').format.columnWidth = 18;
removedSheet.getRange('C:F').format.columnWidth = 34;
removedSheet.getRange('G:H').format.columnWidth = 44;

const missingCostWorkbook = Workbook.create();
const missingCostSheet = missingCostWorkbook.worksheets.add('Missing Costs');
missingCostSheet.showGridLines = false;
missingCostSheet.getRange('A1:K1').merge();
missingCostSheet.getRange('A1').values = [['TECHM8 Tablet Cases - Missing Costs']];
missingCostSheet.getRange('A1:K1').format = {
  fill: '#087F6B',
  font: { bold: true, color: '#FFFFFF', size: 18 },
  verticalAlignment: 'center',
};
missingCostSheet.getRange('A1:K1').format.rowHeight = 34;
missingCostSheet.getRange('A2:K2').merge();
missingCostSheet.getRange('A2').values = [[
  'Enter the confirmed unit cost in column J. Every store and the online store remain at zero stock; zero stock can still be ordered and checked out.',
]];
missingCostSheet.getRange('A2:K2').format = { fill: '#EAF2FF', font: { color: '#204B7A', bold: true }, wrapText: true };
missingCostSheet.getRange('A2:K2').format.rowHeight = 34;
missingCostSheet.getRange('A3:K3').values = [[
  'Source Item ID', 'New SKU', 'Product Name', 'Product Family', 'Colour', 'Compatible Models', 'Source Category', 'Retail Price', 'Current Cost', 'Cost To Enter', 'Status',
]];
missingCostSheet.freezePanes.freezeRows(3);
missingCostSheet.getRange('A3:K3').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
if (missingCostVariants.length) {
  const missingCostEndRow = missingCostVariants.length + 3;
  missingCostSheet.getRange(`A4:J${missingCostEndRow}`).values = missingCostVariants.map((variant) => [
    variant.sourceId,
    variant.newSku,
    variant.proposedName,
    variant.family,
    variant.color,
    variant.profile.models,
    variant.sourceCategory,
    variant.retailPrice,
    variant.sourceCost,
    null,
  ]);
  missingCostSheet.getRange('K4').formulas = [['=IF(J4>0,"Ready","Cost required")']];
  missingCostSheet.getRange(`K4:K${missingCostEndRow}`).fillDown();
  missingCostSheet.tables.add(`A3:K${missingCostEndRow}`, true, 'TabletCaseMissingCosts');
  missingCostSheet.getRange(`A4:K${missingCostEndRow}`).format.verticalAlignment = 'top';
  missingCostSheet.getRange(`C4:G${missingCostEndRow}`).format.wrapText = true;
  missingCostSheet.getRange(`H4:J${missingCostEndRow}`).format.numberFormat = '$#,##0.00';
  missingCostSheet.getRange(`J4:J${missingCostEndRow}`).format = { fill: '#FFF8D8', font: { bold: true, color: '#5C4700' }, numberFormat: '$#,##0.00' };
  missingCostSheet.getRange(`K4:K${missingCostEndRow}`).conditionalFormats.add('containsText', {
    text: 'Cost required',
    format: { fill: '#FDE7E3', font: { color: '#9C2F22', bold: true } },
  });
  missingCostSheet.getRange(`K4:K${missingCostEndRow}`).conditionalFormats.add('containsText', {
    text: 'Ready',
    format: { fill: '#DFF4EF', font: { color: '#075E54', bold: true } },
  });
} else {
  missingCostSheet.getRange('A4:K5').merge();
  missingCostSheet.getRange('A4').values = [['No missing costs. All 287 imported product variants have a confirmed cost.']];
  missingCostSheet.getRange('A4:K5').format = { fill: '#DFF4EF', font: { bold: true, color: '#075E54' }, verticalAlignment: 'center' };
}
missingCostSheet.getRange('A:B').format.columnWidth = 18;
missingCostSheet.getRange('C:C').format.columnWidth = 42;
missingCostSheet.getRange('D:E').format.columnWidth = 20;
missingCostSheet.getRange('F:F').format.columnWidth = 54;
missingCostSheet.getRange('G:G').format.columnWidth = 24;
missingCostSheet.getRange('H:K').format.columnWidth = 16;

await fs.mkdir(previewDir, { recursive: true });
const previews = [
  ['Import Summary', 'A1:H16', 'summary.png'],
  ['Product Variants', 'A1:AC18', 'variants.png'],
  ['Product Groups', `A1:K${Math.min(groups.length + 1, 25)}`, 'groups.png'],
  ['Compatibility Review', `A1:G${profiles.length + 1}`, 'compatibility.png'],
  ['Cost Rules', 'A1:F6', 'cost-rules.png'],
  ['Cost Overrides', `A1:C${costOverrideEndRow}`, 'cost-overrides.png'],
  ['Data Issues', `A1:E${Math.min(issueRows.length + 1, 25)}`, 'issues.png'],
  ['Removed Products', `A1:H${removedNoImageVariants.length + 1}`, 'removed-products.png'],
];
for (const [sheetName, range, fileName] of previews) {
  const preview = await workbook.render({ sheetName, range, scale: 1, format: 'png' });
  await fs.writeFile(`${previewDir}/${fileName}`, new Uint8Array(await preview.arrayBuffer()));
}
const missingCostPreview = await missingCostWorkbook.render({
  sheetName: 'Missing Costs',
  range: `A1:K${Math.max(5, Math.min(missingCostVariants.length + 3, 23))}`,
  scale: 1,
  format: 'png',
});
await fs.writeFile(`${previewDir}/missing-costs.png`, new Uint8Array(await missingCostPreview.arrayBuffer()));

const inspection = await workbook.inspect({
  kind: 'table',
  range: 'Import Summary!A1:H16',
  include: 'values,formulas',
  tableMaxRows: 20,
  tableMaxCols: 10,
  maxChars: 6000,
});
const formulaErrors = await workbook.inspect({
  kind: 'match',
  searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A',
  options: { useRegex: true, maxResults: 300 },
  summary: 'final formula error scan',
});
const missingCostInspection = await missingCostWorkbook.inspect({
  kind: 'table',
  range: `Missing Costs!A1:K${Math.max(5, Math.min(missingCostVariants.length + 3, 15))}`,
  include: 'values,formulas',
  tableMaxRows: 15,
  tableMaxCols: 11,
  maxChars: 6000,
});
const missingCostFormulaErrors = await missingCostWorkbook.inspect({
  kind: 'match',
  searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A',
  options: { useRegex: true, maxResults: 300 },
  summary: 'missing cost formula error scan',
});

await fs.mkdir('D:/program/TECHM8 PRICE LIST/outputs/product-catalog-rebuild', { recursive: true });
const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(outputPath);
const missingCostOutput = await SpreadsheetFile.exportXlsx(missingCostWorkbook);
await missingCostOutput.save(missingCostOutputPath);
await fs.writeFile(importJsonPath, JSON.stringify(importPayload, null, 2), 'utf8');

console.log(JSON.stringify({
  outputPath,
  missingCostOutputPath,
  importJsonPath,
  variants: variants.length,
  groups: groups.length,
  profiles: profiles.length,
  imageMatchCount,
  negativeStockCount,
  hardCaseCount,
  twistLeatherCount,
  zFoldFlipCount,
  unresolvedCostCount,
  removedNoImageCount: removedNoImageVariants.length,
  issueRows: issueRows.length,
  inspection: inspection.ndjson,
  formulaErrors: formulaErrors.ndjson,
  missingCostInspection: missingCostInspection.ndjson,
  missingCostFormulaErrors: missingCostFormulaErrors.ndjson,
}, null, 2));
