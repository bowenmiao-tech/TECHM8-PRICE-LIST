import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { FileBlob, SpreadsheetFile, Workbook } from '@oai/artifact-tool';

const sourcePaths = process.env.PHONE_CASE_SOURCE_PATHS
  ? process.env.PHONE_CASE_SOURCE_PATHS.split(';').map((item) => item.trim()).filter(Boolean)
  : [
      'E:/ontimefile/products case1).xlsx',
      'E:/ontimefile/products (case2).xlsx',
    ];
const imageMapPath = 'D:/program/TECHM8 PRICE LIST/.codex-temp/phone-case-catalog-import/repairdesk-phone-case-images.json';
const reviewInputPaths = [
  'D:/program/TECHM8 PRICE LIST/outputs/phone-case-catalog-20260817/TECHM8_Phone_Cases_Needs_Review.xlsx',
  'D:/program/TECHM8 PRICE LIST/outputs/phone-case-catalog-20260817/TECHM8_Phone_Cases_Needs_Review_Updated.xlsx',
];
const outputDir = process.env.PHONE_CASE_OUTPUT_DIR || 'D:/program/TECHM8 PRICE LIST/outputs/phone-case-catalog-20260819';
const workbookPath = process.env.PHONE_CASE_REVIEW_OUTPUT_PATH || `${outputDir}/TECHM8_Phone_Cases_Final_Review.xlsx`;
const payloadPath = `${outputDir}/TECHM8_Phone_Cases_Import.json`;
const previewPath = `${outputDir}/TECHM8_Phone_Cases_Final_Review.png`;
const migrationPath = process.env.PHONE_CASE_MIGRATION_PATH || `${outputDir}/TECHM8_Phone_Cases_Migration_Preview.sql`;
const migrationBaselinePath = process.env.PHONE_CASE_MIGRATION_BASELINE_PATH || '';

const UNIVERSAL_PATTERN_VARIANTS = new Map([
  ['8372', 'MagSafe Flower'],
  ['8031', 'Flower 7'],
  ['8030', 'Flower 6'],
  ['8029', 'Flower 5'],
  ['8028', 'Flower 4'],
  ['8027', 'Flower 3'],
  ['8026', 'Flower 2'],
  ['8025', 'Flower 1'],
  ['6000', 'Flower / Liquid 96'],
]);
const SPECIAL_ORDER_VARIANTS = new Map([
  ['7159', 'Other Cases (Model Require)'],
  ['5915', 'Flip Case'],
  ['5914', 'Back Cover'],
]);
const SKYLINE_UNIVERSAL_IMAGE = 'https://skylinemobile.com.au/cdn/shop/files/20210103162546.jpg?v=1778040935';
const GOOSPERY_AQUA_IMAGE = 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1685674421.jpg';
const APPLE_LOGO_DARK_GREEN_IMAGE = 'https://oztechm8.com.au/assets/products/phone-cases/iphone-12-12-pro-apple-logo-dark-green.jpg';
const FIXED_REPAIRDESK_IMAGES = new Map([
  ['7182', 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1664762715.jpg'],
  ['7116', 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663814324.jpg'],
  ['6839', 'https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1659061232.jpg'],
]);
const EXCLUDED_PHONE_CASE_SOURCE_IDS = new Set([
  '6688', // Universal Cartoon Case
  '7112', // iPhone 12 Pro Max EFM Phone Case
  '7143', // iPhone EFM Phone Case (device model is ambiguous)
  '7679', // Samsung S20 Plus EFM Aspen Clear
  '7680', // Samsung S20 EFM Aspen Clear
  '7681', // Samsung S21 Ultra EFM Aspen Clear
]);
const BRANDED_CASE_COLLECTIONS = new Map([
  ['CASETiFY', { key: 'casetify-case-collection', name: 'CASETiFY Cases', sort: 5 }],
  ['EFM', { key: 'efm-case-collection', name: 'EFM Cases', sort: 1 }],
  ['OtterBox', { key: 'otterbox-case-collection', name: 'OtterBox Cases', sort: 0 }],
]);

const normalize = (value) => String(value ?? '')
  .normalize('NFKD')
  .replace(/[\u0300-\u036f]/g, '')
  .toLowerCase()
  .replace(/&/g, ' and ')
  .replace(/pro\s*max/g, 'pro max')
  .replace(/promax/g, 'pro max')
  .replace(/[^a-z0-9+]+/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();

const slugify = (value) => normalize(value).replace(/\s+/g, '-').slice(0, 120);
const codePart = (value, max = 42) => normalize(value).toUpperCase().replace(/[^A-Z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, max);
const numberValue = (value) => Number.isFinite(Number(value)) ? Number(value) : 0;
const categoryLeaf = (value) => String(value ?? '').split('>').pop().trim();
const shortHash = (value) => crypto.createHash('sha1').update(String(value)).digest('hex').slice(0, 9).toUpperCase();
const unique = (values) => Array.from(new Set(values));
const moneyText = (value) => Number.isFinite(Number(value)) ? `$${Number(value).toFixed(2)}` : '';

async function loadPreviousReviewInputs() {
  const confirmedCosts = new Map();
  const productOverrides = new Map();

  for (const reviewInputPath of reviewInputPaths) {
    try {
      await fs.access(reviewInputPath);
    } catch {
      continue;
    }

    const previousWorkbook = await SpreadsheetFile.importXlsx(await FileBlob.load(reviewInputPath));
    const costSheet = previousWorkbook.worksheets.getItem('Cost To Confirm');
    const costRows = costSheet.getUsedRange(true).values;
    const costHeaders = costRows[0].map((value) => String(value ?? '').trim());
    for (const row of costRows.slice(1)) {
      const record = Object.fromEntries(costHeaders.map((header, index) => [header, row[index]]));
      const brand = String(record.Brand ?? '').trim();
      const style = String(record['Case Style'] ?? '').trim();
      const confirmedCost = numberValue(record['Confirmed Cost']);
      if (brand && style && confirmedCost > 0) confirmedCosts.set(`${brand}|${normalize(style)}`, confirmedCost);
    }

    const inputSheet = previousWorkbook.worksheets.getItem('Needs Your Input');
    const inputRows = inputSheet.getUsedRange(true).values;
    const headerIndex = inputRows.findIndex((row) => row.some((value) => String(value ?? '').trim() === 'Source Item ID'));
    if (headerIndex >= 0) {
      const inputHeaders = inputRows[headerIndex].map((value) => String(value ?? '').trim());
      for (const row of inputRows.slice(headerIndex + 1)) {
        const record = Object.fromEntries(inputHeaders.map((header, index) => [header, row[index]]));
        const itemId = String(record['Source Item ID'] ?? '').trim();
        if (!itemId) continue;
        productOverrides.set(itemId, {
          finalDevice: String(record['Final Device / Compatibility'] ?? '').trim(),
          finalRetail: numberValue(record['Final Retail']),
          finalImageUrl: String(record['Final Image URL'] ?? '').trim(),
          finalCost: numberValue(record['Confirmed Cost']),
          include: String(record['Include?'] ?? 'Yes').trim().toLowerCase() !== 'no',
          notes: String(record.Notes ?? '').trim(),
        });
      }
    }
  }

  return { confirmedCosts, productOverrides };
}

const previousReviewInputs = await loadPreviousReviewInputs();

function ean13(prefix, itemId) {
  const body = `${prefix}${String(itemId).replace(/\D/g, '').slice(-8).padStart(8, '0')}`.slice(0, 12);
  let sum = 0;
  for (let index = 0; index < 12; index += 1) sum += Number(body[index]) * (index % 2 === 0 ? 1 : 3);
  return `${body}${(10 - (sum % 10)) % 10}`;
}

const categoryDeviceMap = new Map(Object.entries({
  'iphone 6 7 8': ['Apple', 'iPhone 6 / 7 / 8', 'IPHONE-6-7-8'],
  'iphone 6+ 7+ 8+': ['Apple', 'iPhone 6 Plus / 7 Plus / 8 Plus', 'IPHONE-6P-7P-8P'],
  'iphone x xs': ['Apple', 'iPhone X / XS', 'IPHONE-X-XS'],
  'iphone xr': ['Apple', 'iPhone XR', 'IPHONE-XR'],
  'iphone xs max': ['Apple', 'iPhone XS Max', 'IPHONE-XS-MAX'],
  'iphone 11': ['Apple', 'iPhone 11', 'IPHONE-11'],
  'iphone 11 pro': ['Apple', 'iPhone 11 Pro', 'IPHONE-11-PRO'],
  'iphone 11pm': ['Apple', 'iPhone 11 Pro Max', 'IPHONE-11-PRO-MAX'],
  'iphone 12 12pro': ['Apple', 'iPhone 12 / 12 Pro', 'IPHONE-12-12-PRO'],
  'iphone 12pm': ['Apple', 'iPhone 12 Pro Max', 'IPHONE-12-PRO-MAX'],
  'iphone 13mini': ['Apple', 'iPhone 13 mini', 'IPHONE-13-MINI'],
  'iphone 13': ['Apple', 'iPhone 13', 'IPHONE-13'],
  'iphone 13 pro': ['Apple', 'iPhone 13 Pro', 'IPHONE-13-PRO'],
  'iphone 13pm': ['Apple', 'iPhone 13 Pro Max', 'IPHONE-13-PRO-MAX'],
  'iphone 14': ['Apple', 'iPhone 14', 'IPHONE-14'],
  'iphone 14 plus': ['Apple', 'iPhone 14 Plus', 'IPHONE-14-PLUS'],
  'iphone 14 pro': ['Apple', 'iPhone 14 Pro', 'IPHONE-14-PRO'],
  'iphone 14 pro max': ['Apple', 'iPhone 14 Pro Max', 'IPHONE-14-PRO-MAX'],
  'iphone 15': ['Apple', 'iPhone 15', 'IPHONE-15'],
  'iphone 15 plus': ['Apple', 'iPhone 15 Plus', 'IPHONE-15-PLUS'],
  'iphone 15 pro': ['Apple', 'iPhone 15 Pro', 'IPHONE-15-PRO'],
  'iphone 15 pro max': ['Apple', 'iPhone 15 Pro Max', 'IPHONE-15-PRO-MAX'],
  'iphone 16 e 17 e': ['Apple', 'iPhone 16e / 17e', 'IPHONE-16E-17E'],
  'iphone 16': ['Apple', 'iPhone 16', 'IPHONE-16'],
  'iphone 16 plus': ['Apple', 'iPhone 16 Plus', 'IPHONE-16-PLUS'],
  'iphone 16 pro': ['Apple', 'iPhone 16 Pro', 'IPHONE-16-PRO'],
  'iphone 16 pro max': ['Apple', 'iPhone 16 Pro Max', 'IPHONE-16-PRO-MAX'],
  'iphone 17': ['Apple', 'iPhone 17', 'IPHONE-17'],
  'iphone 17 air': ['Apple', 'iPhone 17 Air', 'IPHONE-17-AIR'],
  'iphone 17 pro': ['Apple', 'iPhone 17 Pro', 'IPHONE-17-PRO'],
  'iphone 17 pro max': ['Apple', 'iPhone 17 Pro Max', 'IPHONE-17-PRO-MAX'],
  'samsung a13': ['Samsung', 'Samsung Galaxy A13', 'SAMSUNG-A13'],
  'samsung a14': ['Samsung', 'Samsung Galaxy A14', 'SAMSUNG-A14'],
  'samsung a15': ['Samsung', 'Samsung Galaxy A15', 'SAMSUNG-A15'],
  'samsung a16': ['Samsung', 'Samsung Galaxy A16', 'SAMSUNG-A16'],
  'samsung a17': ['Samsung', 'Samsung Galaxy A17', 'SAMSUNG-A17'],
  'samsung a25': ['Samsung', 'Samsung Galaxy A25', 'SAMSUNG-A25'],
  'samsung a34': ['Samsung', 'Samsung Galaxy A34', 'SAMSUNG-A34'],
  'samsung a36 a56': ['Samsung', 'Samsung Galaxy A36 / A56', 'SAMSUNG-A36-A56'],
  'samsung a37': ['Samsung', 'Samsung Galaxy A37', 'SAMSUNG-A37'],
  'samsung a54': ['Samsung', 'Samsung Galaxy A54', 'SAMSUNG-A54'],
  'samsung a55': ['Samsung', 'Samsung Galaxy A55', 'SAMSUNG-A55'],
  'samsung a57': ['Samsung', 'Samsung Galaxy A57', 'SAMSUNG-A57'],
  'samsung s22': ['Samsung', 'Samsung Galaxy S22', 'SAMSUNG-S22'],
  'samsung s22p': ['Samsung', 'Samsung Galaxy S22 Plus', 'SAMSUNG-S22-PLUS'],
  'samsung s22u': ['Samsung', 'Samsung Galaxy S22 Ultra', 'SAMSUNG-S22-ULTRA'],
  'samsung s21': ['Samsung', 'Samsung Galaxy S21', 'SAMSUNG-S21'],
  'samsung s21fe': ['Samsung', 'Samsung Galaxy S21 FE', 'SAMSUNG-S21-FE'],
  'samsung s21 plus': ['Samsung', 'Samsung Galaxy S21 Plus', 'SAMSUNG-S21-PLUS'],
  'samsung note 20': ['Samsung', 'Samsung Galaxy Note 20', 'SAMSUNG-NOTE-20'],
  'samsung z flip5': ['Samsung', 'Samsung Galaxy Z Flip5', 'SAMSUNG-Z-FLIP5'],
  'samsung z fold4': ['Samsung', 'Samsung Galaxy Z Fold4', 'SAMSUNG-Z-FOLD4'],
  'samsung zfold 8': ['Samsung', 'Samsung Galaxy Z Fold8', 'SAMSUNG-Z-FOLD8'],
  'samsung s23': ['Samsung', 'Samsung Galaxy S23', 'SAMSUNG-S23'],
  'samsung s23 fe': ['Samsung', 'Samsung Galaxy S23 FE', 'SAMSUNG-S23-FE'],
  'samsung s23 plus': ['Samsung', 'Samsung Galaxy S23 Plus', 'SAMSUNG-S23-PLUS'],
  'samsung s23 ultra': ['Samsung', 'Samsung Galaxy S23 Ultra', 'SAMSUNG-S23-ULTRA'],
  'samsung s24': ['Samsung', 'Samsung Galaxy S24', 'SAMSUNG-S24'],
  'samsung s24 fe': ['Samsung', 'Samsung Galaxy S24 FE', 'SAMSUNG-S24-FE'],
  'samsung s24 plus': ['Samsung', 'Samsung Galaxy S24 Plus', 'SAMSUNG-S24-PLUS'],
  'samsung s24 ultra': ['Samsung', 'Samsung Galaxy S24 Ultra', 'SAMSUNG-S24-ULTRA'],
  'samsung s25': ['Samsung', 'Samsung Galaxy S25', 'SAMSUNG-S25'],
  'samsung s25 edge': ['Samsung', 'Samsung Galaxy S25 Edge', 'SAMSUNG-S25-EDGE'],
  'samsung s25 plus': ['Samsung', 'Samsung Galaxy S25 Plus', 'SAMSUNG-S25-PLUS'],
  'samsung s25 ultra': ['Samsung', 'Samsung Galaxy S25 Ultra', 'SAMSUNG-S25-ULTRA'],
  'samsung s26': ['Samsung', 'Samsung Galaxy S26', 'SAMSUNG-S26'],
  'samsung s26 plus': ['Samsung', 'Samsung Galaxy S26 Plus', 'SAMSUNG-S26-PLUS'],
  'samsung s26 ultra': ['Samsung', 'Samsung Galaxy S26 Ultra', 'SAMSUNG-S26-ULTRA'],
}));

function deviceFromTuple(tuple, sourceCategory) {
  if (!tuple) return null;
  const [brand, displayName, code] = tuple;
  return {
    brand,
    displayName,
    code,
    profileCode: `PHONE-${code}`,
    sourceCategory,
    subcategory: brand === 'Apple' ? 'Apple iPhone' : brand === 'Samsung' ? 'Samsung Galaxy' : brand === 'Google' ? 'Google Pixel' : 'Other & Universal',
  };
}

const nameDevicePatterns = [
  [/pixel\s*9\s*pro\s*xl/i, ['Google', 'Google Pixel 9 Pro XL', 'PIXEL-9-PRO-XL']],
  [/pixel\s*9\s*\/\s*9\s*pro/i, ['Google', 'Google Pixel 9 / 9 Pro', 'PIXEL-9-9-PRO']],
  [/pixel\s*8\s*pro/i, ['Google', 'Google Pixel 8 Pro', 'PIXEL-8-PRO']],
  [/pixel\s*8a/i, ['Google', 'Google Pixel 8a', 'PIXEL-8A']],
  [/pixel\s*8/i, ['Google', 'Google Pixel 8', 'PIXEL-8']],
  [/iphone\s*17\s*pro\s*max/i, ['Apple', 'iPhone 17 Pro Max', 'IPHONE-17-PRO-MAX']],
  [/iphone\s*17\s*air/i, ['Apple', 'iPhone 17 Air', 'IPHONE-17-AIR']],
  [/iphone\s*17\s*pro/i, ['Apple', 'iPhone 17 Pro', 'IPHONE-17-PRO']],
  [/iphone\s*(?:17e\s*\/\s*16e|16e\s*\/\s*17e)/i, ['Apple', 'iPhone 16e / 17e', 'IPHONE-16E-17E']],
  [/iphone\s*17/i, ['Apple', 'iPhone 17', 'IPHONE-17']],
  [/iphone\s*16\s*pro\s*max/i, ['Apple', 'iPhone 16 Pro Max', 'IPHONE-16-PRO-MAX']],
  [/iphone\s*16\s*plus/i, ['Apple', 'iPhone 16 Plus', 'IPHONE-16-PLUS']],
  [/iphone\s*16\s*pro/i, ['Apple', 'iPhone 16 Pro', 'IPHONE-16-PRO']],
  [/iphone\s*16/i, ['Apple', 'iPhone 16', 'IPHONE-16']],
  [/iphone\s*15\s*pro\s*max/i, ['Apple', 'iPhone 15 Pro Max', 'IPHONE-15-PRO-MAX']],
  [/iphone\s*15\s*plus/i, ['Apple', 'iPhone 15 Plus', 'IPHONE-15-PLUS']],
  [/iphone\s*15\s*pro/i, ['Apple', 'iPhone 15 Pro', 'IPHONE-15-PRO']],
  [/iphone\s*15/i, ['Apple', 'iPhone 15', 'IPHONE-15']],
  [/iphone\s*14\s*pro\s*max/i, ['Apple', 'iPhone 14 Pro Max', 'IPHONE-14-PRO-MAX']],
  [/iphone\s*14\s*plus/i, ['Apple', 'iPhone 14 Plus', 'IPHONE-14-PLUS']],
  [/iphone\s*14\s*pro/i, ['Apple', 'iPhone 14 Pro', 'IPHONE-14-PRO']],
  [/iphone\s*14/i, ['Apple', 'iPhone 14', 'IPHONE-14']],
  [/iphone\s*13\s*pro\s*max/i, ['Apple', 'iPhone 13 Pro Max', 'IPHONE-13-PRO-MAX']],
  [/iphone\s*13\s*mini/i, ['Apple', 'iPhone 13 mini', 'IPHONE-13-MINI']],
  [/iphone\s*13\s*pro/i, ['Apple', 'iPhone 13 Pro', 'IPHONE-13-PRO']],
  [/iphone\s*13/i, ['Apple', 'iPhone 13', 'IPHONE-13']],
  [/iphone\s*12\s*pro\s*max/i, ['Apple', 'iPhone 12 Pro Max', 'IPHONE-12-PRO-MAX']],
  [/iphone\s*12(?:\s*\/\s*12\s*pro|\s*pro)?/i, ['Apple', 'iPhone 12 / 12 Pro', 'IPHONE-12-12-PRO']],
  [/iphone\s*11\s*pro\s*max/i, ['Apple', 'iPhone 11 Pro Max', 'IPHONE-11-PRO-MAX']],
  [/iphone\s*11\s*pro/i, ['Apple', 'iPhone 11 Pro', 'IPHONE-11-PRO']],
  [/iphone\s*11/i, ['Apple', 'iPhone 11', 'IPHONE-11']],
  [/iphone\s*xs\s*max/i, ['Apple', 'iPhone XS Max', 'IPHONE-XS-MAX']],
  [/iphone\s*xs\b/i, ['Apple', 'iPhone X / XS', 'IPHONE-X-XS']],
  [/iphone\s*x\s*\/\s*xs/i, ['Apple', 'iPhone X / XS', 'IPHONE-X-XS']],
  [/iphone\s*xr/i, ['Apple', 'iPhone XR', 'IPHONE-XR']],
  [/iphone\s*7\s*\/\s*8\s*(?:plus|\+)/i, ['Apple', 'iPhone 6 Plus / 7 Plus / 8 Plus', 'IPHONE-6P-7P-8P']],
  [/iphone\s*7\s*\/\s*8\b/i, ['Apple', 'iPhone 6 / 7 / 8', 'IPHONE-6-7-8']],
  [/iphone\s*6\+?\s*\/\s*7\+?\s*\/\s*8\+/i, ['Apple', 'iPhone 6 Plus / 7 Plus / 8 Plus', 'IPHONE-6P-7P-8P']],
  [/iphone\s*6\s*\/\s*7\s*\/\s*8/i, ['Apple', 'iPhone 6 / 7 / 8', 'IPHONE-6-7-8']],
  [/samsung\s*s25u|\bs25\s*ultra\b/i, ['Samsung', 'Samsung Galaxy S25 Ultra', 'SAMSUNG-S25-ULTRA']],
  [/samsung\s*s25\+|\bs25\s*plus\b/i, ['Samsung', 'Samsung Galaxy S25 Plus', 'SAMSUNG-S25-PLUS']],
  [/samsung\s*s25\b|\bs25\b/i, ['Samsung', 'Samsung Galaxy S25', 'SAMSUNG-S25']],
  [/samsung\s*s24\+|\bs24\s*plus\b/i, ['Samsung', 'Samsung Galaxy S24 Plus', 'SAMSUNG-S24-PLUS']],
  [/samsung\s*s24\s*ultra/i, ['Samsung', 'Samsung Galaxy S24 Ultra', 'SAMSUNG-S24-ULTRA']],
  [/samsung\s*s24\b/i, ['Samsung', 'Samsung Galaxy S24', 'SAMSUNG-S24']],
  [/samsung\s*s23\s*plus/i, ['Samsung', 'Samsung Galaxy S23 Plus', 'SAMSUNG-S23-PLUS']],
  [/samsung\s*s23\s*ultra/i, ['Samsung', 'Samsung Galaxy S23 Ultra', 'SAMSUNG-S23-ULTRA']],
  [/samsung\s*s23\b/i, ['Samsung', 'Samsung Galaxy S23', 'SAMSUNG-S23']],
  [/samsung\s*(?:galaxy\s*)?z\s*flip\s*5/i, ['Samsung', 'Samsung Galaxy Z Flip5', 'SAMSUNG-Z-FLIP5']],
  [/(?:samsung\s*)?(?:galaxy\s*)?z\s*flip\s*3(?:\s*5g)?/i, ['Samsung', 'Samsung Galaxy Z Flip3', 'SAMSUNG-Z-FLIP3']],
  [/(?:samsung\s*)?(?:galaxy\s*)?z\s*fold\s*5/i, ['Samsung', 'Samsung Galaxy Z Fold5', 'SAMSUNG-Z-FOLD5']],
  [/(?:samsung\s*)?(?:galaxy\s*)?z\s*fold\s*3/i, ['Samsung', 'Samsung Galaxy Z Fold3', 'SAMSUNG-Z-FOLD3']],
  [/samsung\s*(?:galaxy\s*)?z\s*fold\s*4/i, ['Samsung', 'Samsung Galaxy Z Fold4', 'SAMSUNG-Z-FOLD4']],
  [/samsung\s*(?:galaxy\s*)?z\s*fold\s*8/i, ['Samsung', 'Samsung Galaxy Z Fold8', 'SAMSUNG-Z-FOLD8']],
  [/samsung\s*(?:galaxy\s*)?note\s*20/i, ['Samsung', 'Samsung Galaxy Note 20', 'SAMSUNG-NOTE-20']],
  [/\bnote\s*20\b/i, ['Samsung', 'Samsung Galaxy Note 20', 'SAMSUNG-NOTE-20']],
  [/(?:samsung\s*)?(?:galaxy\s*)?note\s*10\b/i, ['Samsung', 'Samsung Galaxy Note 10', 'SAMSUNG-NOTE-10']],
  [/(?:samsung\s*)?(?:galaxy\s*)?s20\s*ultra/i, ['Samsung', 'Samsung Galaxy S20 Ultra', 'SAMSUNG-S20-ULTRA']],
  [/(?:samsung\s*)?(?:galaxy\s*)?s20\s*(?:plus|\+)/i, ['Samsung', 'Samsung Galaxy S20 Plus', 'SAMSUNG-S20-PLUS']],
  [/(?:samsung\s*)?(?:galaxy\s*)?s20\b/i, ['Samsung', 'Samsung Galaxy S20', 'SAMSUNG-S20']],
  [/samsung\s*(?:galaxy\s*)?s22\s*(?:plus|\+)/i, ['Samsung', 'Samsung Galaxy S22 Plus', 'SAMSUNG-S22-PLUS']],
  [/samsung\s*(?:galaxy\s*)?s22\s*ultra/i, ['Samsung', 'Samsung Galaxy S22 Ultra', 'SAMSUNG-S22-ULTRA']],
  [/samsung\s*(?:galaxy\s*)?s22\b/i, ['Samsung', 'Samsung Galaxy S22', 'SAMSUNG-S22']],
  [/samsung\s*(?:galaxy\s*)?s21\s*ultra/i, ['Samsung', 'Samsung Galaxy S21 Ultra', 'SAMSUNG-S21-ULTRA']],
  [/samsung\s*(?:galaxy\s*)?s21\s*(?:plus|\+)/i, ['Samsung', 'Samsung Galaxy S21 Plus', 'SAMSUNG-S21-PLUS']],
  [/samsung\s*(?:galaxy\s*)?s21\s*fe/i, ['Samsung', 'Samsung Galaxy S21 FE', 'SAMSUNG-S21-FE']],
  [/samsung\s*(?:galaxy\s*)?s21\b/i, ['Samsung', 'Samsung Galaxy S21', 'SAMSUNG-S21']],
];

function detectDevice(category, name) {
  const leaf = normalize(categoryLeaf(category));
  const mapped = categoryDeviceMap.get(leaf);
  if (mapped) return deviceFromTuple(mapped, category);
  if (/universal phone case|universal case/.test(leaf)) {
    const size = String(name).match(/Universal\s+(XXL|XL|L|M)\b/i)?.[1]?.toUpperCase() ?? 'Universal';
    return deviceFromTuple(['Universal', size === 'Universal' ? 'Universal Phone Case' : `Universal Phone Pouch - ${size}`, `UNIVERSAL-PHONE-${size}`], category);
  }
  if (/efm|otter box|life proof/.test(leaf)) {
    const matched = nameDevicePatterns.find(([pattern]) => pattern.test(String(name)));
    return matched ? deviceFromTuple(matched[1], category) : null;
  }
  if (/yesido waterproof/i.test(String(name))) return deviceFromTuple(['Universal', 'Universal Waterproof Phone Pouch', 'UNIVERSAL-WATERPROOF-POUCH'], category);
  if (/universal/i.test(String(name))) return deviceFromTuple(['Universal', 'Universal Phone Case', 'UNIVERSAL-PHONE'], category);
  const matched = nameDevicePatterns.find(([pattern]) => pattern.test(String(name)));
  return matched ? deviceFromTuple(matched[1], category) : null;
}

function deviceFromReviewInput(value, sourceCategory) {
  const requested = normalize(value);
  if (!requested) return null;
  const exactTuple = Array.from(categoryDeviceMap.values()).find((tuple) => normalize(tuple[1]) === requested);
  if (exactTuple) return deviceFromTuple(exactTuple, sourceCategory);
  if (/^universal phone case$/.test(requested)) {
    return deviceFromTuple(['Universal', 'Universal Phone Case', 'UNIVERSAL-PHONE'], sourceCategory);
  }
  const pouchSize = String(value).match(/Universal Phone Pouch\s*-?\s*(XXL|XL|L|M)\b/i)?.[1]?.toUpperCase();
  if (pouchSize) {
    return deviceFromTuple(['Universal', `Universal Phone Pouch - ${pouchSize}`, `UNIVERSAL-PHONE-${pouchSize}`], sourceCategory);
  }
  const matched = nameDevicePatterns.find(([, tuple]) => normalize(tuple[1]) === requested);
  return matched ? deviceFromTuple(matched[1], sourceCategory) : detectDevice(sourceCategory, value);
}

function universalPatternDevice(sourceCategory) {
  return deviceFromTuple(
    ['Universal', 'Model Confirmed at Sale', 'UNIVERSAL-PATTERN-CASE'],
    sourceCategory,
  );
}

function specialOrderDevice(sourceCategory) {
  return deviceFromTuple(
    ['Universal', 'Model Recorded in Sale Note', 'SPECIAL-ORDER-CASE'],
    sourceCategory,
  );
}

function directImageUrl(value) {
  const candidate = String(value ?? '').trim();
  if (!/^https?:\/\//i.test(candidate)) return '';
  return /\.(?:avif|gif|jpe?g|png|webp)(?:$|[?#])/i.test(candidate) ? candidate : '';
}

function reviewedImageUrl(itemId, overrideValue, sourceImageUrl) {
  if (FIXED_REPAIRDESK_IMAGES.has(itemId)) return FIXED_REPAIRDESK_IMAGES.get(itemId);
  if (itemId === '8365') return APPLE_LOGO_DARK_GREEN_IMAGE;
  if (itemId === '7159') return SKYLINE_UNIVERSAL_IMAGE;
  if (['8085', '8073', '8067'].includes(itemId)) return SKYLINE_UNIVERSAL_IMAGE;
  if (itemId === '8135' && /aqua/i.test(String(overrideValue))) return GOOSPERY_AQUA_IMAGE;
  return directImageUrl(overrideValue) || String(sourceImageUrl ?? '').trim();
}

const colors = [
  ['Rainbow Purple', /\brainbow\s+purple\b/i], ['Rainbow Black', /\brainbow\s+black\b/i],
  ['Rainbow Blue', /\brainbow\s+blue\b/i], ['Rainbow Pink', /\brainbow\s+pink\b/i],
  ['Rainbow Red', /\brainbow\s+red\b/i], ['Pistachio Green', /\bpistachio\s+green\b/i],
  ['Rose Gold', /\brose\s+gold\b/i], ['Matte Black', /\bmatte?\s+black\b/i],
  ['Matte White', /\bmatte?\s+white\b/i], ['Light Pink', /\blight\s+pink\b/i],
  ['Hot Pink', /\bhot\s*\-?\s*pink\b/i], ['Dark Green', /\bdark\s*green\b/i],
  ['Dark Blue', /\bdark\s*blue\b/i],
  ['Sky Blue', /\bsky\s*blue\b/i], ['Navy Blue', /\bnavy(?:\s+blue)?\b/i],
  ['Black Gradient', /\bblack\s+gradient\b/i], ['Assorted', /\b(?:all|mix|mixed)\s+colou?r\b/i],
  ['Rose', /\brose\b/i], ['Aqua', /\baqua\b/i], ['Teal', /\bteal\b/i],
  ['Mint', /\bmint\b/i], ['Cream', /\bcream\b/i], ['Brown', /\bbrown\b/i],
  ['Black', /\bblack\b/i], ['White', /\bwhite\b/i], ['Clear', /\bclear\b/i],
  ['Blue', /\bblue\b/i], ['Green', /\bgreen\b/i], ['Purple', /\bpurple\b/i],
  ['Pink', /\bpink\b/i], ['Red', /\bred\b/i], ['Gold', /\bgold\b/i],
  ['Grey', /\bgr(?:e|a)y\b/i], ['Silver', /\b(?:silver|sliver)\b/i],
  ['Yellow', /\byellow\b/i], ['Orange', /\borange\b/i],
];

function detectColor(name) {
  return colors.find(([, pattern]) => pattern.test(String(name)))?.[0] ?? 'Standard';
}

function removeDevices(value) {
  return String(value)
    .replace(/google\s+pixel\s*\d+(?:a|\s*pro(?:\s*xl)?)?(?:\s*\/\s*\d+\s*pro)?/ig, ' ')
    .replace(/iphone\s*12\s*\/\s*12\s*pro/ig, ' ')
    .replace(/iphone\s*(?:17e\s*\/\s*16e|16e\s*\/\s*17e|\d+(?:\s*pro\s*max|\s*pro|\s*plus|\s*mini|\s*air|\s*pm)?|x\s*\/\s*xs|xs\s*max|xr|6\+?\s*\/\s*7\+?\s*\/\s*8\+?)/ig, ' ')
    .replace(/samsung\s+(?:galaxy\s+)?[as]\d+(?:\s*(?:ultra|plus|edge|fe)|\+|u|p)?/ig, ' ')
    .replace(/^\s*[as]\d+(?:\s*(?:ultra|plus|edge|fe)|\+|u|p)?\b/ig, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function removeColorWords(value) {
  let result = String(value);
  for (const [, pattern] of colors) result = result.replace(new RegExp(pattern.source, 'ig'), ' ');
  return result.replace(/[()]/g, ' ').replace(/\s+/g, ' ').replace(/[\s\-]+$/g, '').trim();
}

function titleWords(value) {
  const keepUpper = new Set(['EFM', 'NBA', 'MK', 'C', 'ONE', 'PIECE']);
  return String(value).split(/\s+/).filter(Boolean).map((word) => {
    const upper = word.toUpperCase();
    if (keepUpper.has(upper)) return upper;
    if (/^mag\s?safe$/i.test(word)) return 'MagSafe';
    if (/^otterbox$/i.test(word)) return 'OtterBox';
    if (/^goospery$/i.test(word)) return 'Goospery';
    if (/^hanman$/i.test(word)) return 'Hanman';
    return word.charAt(0).toUpperCase() + word.slice(1).toLowerCase();
  }).join(' ');
}

function detectStyle(name, sourceCategory = '') {
  const original = String(name).trim();
  const sourceLeaf = normalize(categoryLeaf(sourceCategory));
  const descriptor = removeColorWords(removeDevices(original))
    .replace(/\bphone\b/ig, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  const lower = normalize(descriptor);
  let brand = 'OZTECHM8';
  let family = 'Fashion Case';
  let display = '';

  if (/otter\s*box|otterbox/.test(lower) || /otter box|life proof/.test(sourceLeaf)) brand = 'OtterBox';
  else if (/\befm\b/.test(lower) || sourceLeaf === 'efm') brand = 'EFM';
  else if (/^c\b/.test(lower)) brand = 'CASETiFY';
  else if (/\bhanman\b/.test(lower)) brand = 'Hanman';
  else if (/goospery/.test(lower)) brand = 'Goospery';
  else if (/rich diary/.test(lower)) brand = 'Rich Diary';
  else if (/yesido/.test(lower)) brand = 'Yesido';

  if (sourceLeaf === '113 life proof' || /otter.*(?:fre|life proof).*waterproof/.test(lower) || /otter.*fre.*waterproof/.test(lower)) {
    family = 'Premium Branded Case'; display = 'OtterBox Fre Waterproof MagSafe Case';
  } else if (sourceLeaf === '112 otter box defender' || /otter.*defender/.test(lower)) {
    family = 'Premium Branded Case'; display = /magsafe/.test(lower) ? 'OtterBox Defender MagSafe Case' : 'OtterBox Defender Case';
  } else if (sourceLeaf === '111 otter box symmetry' || /otter.*symmetry|case symmetry/.test(lower)) {
    family = 'Premium Branded Case'; display = /magsafe|symmetry\s*\+/.test(lower) ? 'OtterBox Symmetry+ MagSafe Case' : 'OtterBox Symmetry Case';
  } else if (sourceLeaf === 'efm' || /\befm\b/.test(lower)) {
    const series = removeColorWords(descriptor.replace(/\bEFM\b/i, '').replace(/\bcase\b/ig, '')).trim();
    family = 'Premium Branded Case'; display = `EFM ${titleWords(series || 'Case')}${/case/i.test(series) ? '' : ' Case'}`.replace(/\s+/g, ' ');
  } else if (/hanman/.test(lower) && /magsafe/.test(lower) && /flip/.test(lower)) {
    family = 'Flip Case'; display = 'Hanman MagSafe Flip Case';
  } else if (/hanman/.test(lower)) {
    family = /flip/.test(lower) ? 'Flip Case' : 'Fashion Case'; display = `Hanman${/magsafe/.test(lower) ? ' MagSafe' : ''}${/flip/.test(lower) ? ' Flip' : ''} Case`;
  } else if (/rich diary/.test(lower)) {
    family = 'Flip Case'; display = 'Rich Diary Flip Case';
  } else if (/goospery/.test(lower)) {
    family = 'Flip Case'; display = 'Goospery Flip Case';
  } else if (/silicone.*magsafe.*hard|magsafe.*silicone.*hard/.test(lower)) {
    family = 'MagSafe Case'; display = 'Silicone MagSafe Hard Case';
  } else if (/shockproof.*grip/.test(lower)) {
    family = 'Shockproof Case'; display = 'Shockproof Grip Case';
  } else if (/magnetic.*wallet/.test(lower)) {
    family = 'Wallet Case'; display = 'Magnetic Wallet Case';
  } else if (/detachable.*wallet/.test(lower)) {
    family = 'Wallet Case'; display = 'Detachable Wallet Case';
  } else if (/lux.*wallet/.test(lower)) {
    family = 'Wallet Case'; display = 'Lux Wallet Case';
  } else if (/apple logo.*magsafe/.test(lower) || /magsafe.*apple logo/.test(lower)) {
    family = 'MagSafe Case'; display = 'Apple Logo MagSafe Case';
  } else if (/apple logo/.test(lower)) {
    family = 'Fashion Case'; display = 'Apple Logo Case';
  } else if (/air cushion/.test(lower)) {
    family = 'Shockproof Case'; display = 'Air Cushion+ Case';
  } else if (/iridescent/.test(lower)) {
    family = 'MagSafe Case'; display = 'Iridescent MagSafe Case';
  } else if (/glitter/.test(lower)) {
    family = /magsafe/.test(lower) ? 'MagSafe Case' : 'Fashion Case'; display = `${/magsafe/.test(lower) ? 'MagSafe ' : ''}Glitter Case`;
  } else if (/magsafe.*clear|clear.*magsafe/.test(lower)) {
    family = 'MagSafe Case'; display = 'Clear MagSafe Case';
  } else if (/magsafe/.test(lower) && /^c\b/.test(lower)) {
    const design = descriptor.replace(/^C\s+/i, '').replace(/\bMagsafe\b/ig, '').trim();
    family = 'MagSafe Case'; display = `${titleWords(design || 'Design')} MagSafe Case`;
  } else if (/^c\b/.test(lower)) {
    const design = descriptor.replace(/^C\s+/i, '').trim();
    family = 'Fashion Case'; display = `${titleWords(design || 'Design')} Case`;
  } else if (/magsafe/.test(lower)) {
    const detailed = titleWords(descriptor
      .replace(/\bphone\b/ig, '')
      .replace(/\bcase\b/ig, '')
      .replace(/\s+/g, ' ')
      .trim());
    family = /shockproof|bumper|ring/.test(lower) ? 'Shockproof Case' : 'MagSafe Case';
    display = detailed && normalize(detailed) !== 'magsafe' ? `${detailed} Case` : 'MagSafe Case';
  } else if (/silicone/.test(lower)) {
    family = 'Silicone Case'; display = 'Silicone Case';
  } else if (/clear/.test(lower)) {
    family = 'Clear Case'; display = 'Clear Case';
  } else if (/back cover/.test(lower)) {
    family = 'Back Cover'; display = 'Back Cover';
  } else if (/flip/.test(lower)) {
    family = 'Flip Case'; display = 'Flip Case';
  } else if (/waterproof/.test(lower)) {
    family = 'Waterproof Case'; display = titleWords(descriptor);
  } else {
    display = titleWords(descriptor || 'Phone Case');
    if (!/case|cover/i.test(display)) display += ' Case';
  }

  display = display.replace(/\bCase Case\b/i, 'Case').replace(/\s+/g, ' ').trim();
  return { brand, family, display, key: normalize(display) };
}

function deviceSort(device) {
  if (device.brand === 'Apple') {
    const order = ['6-7-8', '6P-7P-8P', 'X-XS', 'XR', 'XS-MAX', '11', '11-PRO', '11-PRO-MAX', '12-12-PRO', '12-PRO-MAX', '13-MINI', '13', '13-PRO', '13-PRO-MAX', '14', '14-PLUS', '14-PRO', '14-PRO-MAX', '15', '15-PLUS', '15-PRO', '15-PRO-MAX', '16E-17E', '16', '16-PLUS', '16-PRO', '16-PRO-MAX', '17', '17-AIR', '17-PRO', '17-PRO-MAX'];
    const index = order.findIndex((value) => device.code.endsWith(value));
    return 1000 + (index < 0 ? 999 : index) * 100;
  }
  if (device.brand === 'Samsung') {
    const match = device.code.match(/SAMSUNG-([AS])(\d+)(?:-(FE|PLUS|ULTRA|EDGE))?/);
    if (!match) return 9000;
    const series = match[1] === 'A' ? 4000 : 6000;
    const suffix = ({ FE: 1, PLUS: 2, ULTRA: 3, EDGE: 4 })[match[3]] ?? 0;
    return series + Number(match[2]) * 10 + suffix;
  }
  if (device.brand === 'Google') return 8000 + Number(device.code.match(/\d+/)?.[0] ?? 0) * 10;
  return 10000;
}

const familyOrder = new Map([
  ['Premium Branded Case', 0], ['MagSafe Case', 10], ['Shockproof Case', 20],
  ['Wallet Case', 30], ['Flip Case', 40], ['Silicone Case', 50], ['Clear Case', 60],
  ['Back Cover', 70], ['Fashion Case', 80], ['Waterproof Case', 90],
]);

function chooseMode(values) {
  const counts = new Map();
  for (const value of values.filter((item) => Number(item) > 0)) {
    const key = Number(value).toFixed(2);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  const ranked = Array.from(counts.entries()).sort((a, b) => b[1] - a[1] || Number(a[0]) - Number(b[0]));
  if (!ranked.length) return { value: null, decisive: false, values: [] };
  const decisive = ranked.length === 1 || ranked[0][1] > ranked[1][1];
  return { value: decisive ? Number(ranked[0][0]) : null, decisive, values: ranked.map(([value, count]) => ({ value: Number(value), count })) };
}

function imageIndexes(categories) {
  const byCategoryAndName = new Map();
  const byName = new Map();
  for (const category of categories) {
    for (const card of category.cards ?? []) {
      const nameKey = normalize(card.name);
      const categoryKeys = unique([normalize(category.category_name), normalize(`5. Phone Cases > ${category.category_name}`)]);
      for (const categoryKey of categoryKeys) byCategoryAndName.set(`${categoryKey}|${nameKey}`, card);
      if (!byName.has(nameKey)) byName.set(nameKey, []);
      byName.get(nameKey).push(card);
    }
  }
  return { byCategoryAndName, byName };
}

function findImage(record, indexes) {
  const keys = [normalize(record.Category), normalize(categoryLeaf(record.Category))];
  const nameKey = normalize(record['Item Name']);
  for (const categoryKey of keys) {
    const card = indexes.byCategoryAndName.get(`${categoryKey}|${nameKey}`);
    if (card) return card;
  }
  const globalMatches = indexes.byName.get(nameKey) ?? [];
  return globalMatches.length === 1 ? globalMatches[0] : null;
}

const records = [];
for (const sourcePath of sourcePaths) {
  const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(sourcePath));
  const rows = workbook.worksheets.getItemAt(0).getUsedRange(true).values;
  const headers = rows[0].map((value) => String(value ?? '').trim());
  for (const row of rows.slice(1)) {
    const record = Object.fromEntries(headers.map((header, index) => [header, row[index]]));
    if (!record['Item ID'] || String(record['Item ID']).startsWith('This column')) continue;
    if (!String(record.Category ?? '').trim().toLowerCase().startsWith('5. phone cases')) continue;
    records.push({ ...record, _source_file: path.basename(sourcePath) });
  }
}

const repairdeskImages = JSON.parse(await fs.readFile(imageMapPath, 'utf8'));
const indexes = imageIndexes(repairdeskImages);
const nonPhoneCases = [];
const initialCandidates = [];

for (const record of records) {
  const name = String(record['Item Name']).trim();
  const category = String(record.Category).trim();
  const itemId = String(record['Item ID']).trim();
  if (EXCLUDED_PHONE_CASE_SOURCE_IDS.has(itemId)) continue;
  const userOverride = previousReviewInputs.productOverrides.get(itemId);
  const leaf = normalize(categoryLeaf(category));
  if (/air pods|air tag/.test(leaf)) {
    nonPhoneCases.push({ record, reason: 'AirPods and AirTag accessories are not phone cases.' });
    continue;
  }
  const detectedDevice = detectDevice(category, name);
  const reviewedDevice = userOverride?.finalDevice ? deviceFromReviewInput(userOverride.finalDevice, category) : null;
  const universalPattern = UNIVERSAL_PATTERN_VARIANTS.has(itemId);
  const specialOrder = SPECIAL_ORDER_VARIANTS.has(itemId);
  let device = reviewedDevice ?? detectedDevice;
  let style = detectStyle(name, category);
  let variantName = detectColor(name);
  let variantType = 'colour';
  if (universalPattern) {
    device = universalPatternDevice(category);
    style = {
      brand: 'OZTECHM8',
      family: 'Universal Pattern Case',
      display: 'Universal Flower & Pattern Phone Case',
      key: 'universal flower pattern phone case',
    };
    variantName = UNIVERSAL_PATTERN_VARIANTS.get(itemId);
    variantType = 'pattern';
  } else if (specialOrder) {
    device = specialOrderDevice(category);
    style = {
      brand: 'OZTECHM8',
      family: 'Special Order Case',
      display: 'Special Order Phone Case',
      key: 'special order phone case',
    };
    variantName = SPECIAL_ORDER_VARIANTS.get(itemId);
    variantType = 'option';
  }
  if (device?.brand === 'Universal' && /^universal\s+(?:xxl|xl|l|m)\b/i.test(name)) {
    style = { brand: 'OZTECHM8', family: 'Universal Phone Case', display: 'Universal Phone Pouch', key: 'universal phone pouch' };
  }
  const imageCard = findImage(record, indexes);
  const sourceCost = numberValue(record['Cost Price']);
  const retailPrice = userOverride?.finalRetail > 0 ? userOverride.finalRetail : numberValue(record['Retail Price']);
  const sourceStock = numberValue(record['On Hand Qty']);
  const imageUrl = reviewedImageUrl(itemId, userOverride?.finalImageUrl, imageCard?.image_url);
  const noImageAccepted = /没有就算了/i.test(String(userOverride?.finalImageUrl ?? ''));
  initialCandidates.push({
    itemId,
    sourceFile: record._source_file,
    sourceCategory: category,
    originalName: name,
    originalSku: String(record.SKU ?? '').trim(),
    originalUpc: String(record.UPC ?? '').trim(),
    sourceCost,
    retailPrice,
    sourceStock,
    device,
    style,
    color: variantType === 'colour' ? variantName : 'Standard',
    variantName,
    variantType,
    imageCard,
    imageUrl,
    reviewedCost: userOverride?.finalCost > 0 ? userOverride.finalCost : null,
    repairdeskProductId: String(imageCard?.dom_product_id ?? ''),
    inventoryIndexId: String(imageCard?.inventory_index_id ?? ''),
    sku: `TM8-PC-${itemId}`,
    upc: ean13('2997', itemId),
    userInclude: (userOverride?.include ?? true) && !noImageAccepted,
    userNotes: userOverride?.notes ?? '',
  });
}

const duplicateAudit = [];
const duplicateGroups = new Map();
for (const candidate of initialCandidates) {
  const key = `${candidate.device?.code ?? 'UNKNOWN'}|${normalize(candidate.originalName)}`;
  if (!duplicateGroups.has(key)) duplicateGroups.set(key, []);
  duplicateGroups.get(key).push(candidate);
}

const candidates = [];
const forcedReview = [];
for (const group of duplicateGroups.values()) {
  if (group.length === 1) {
    candidates.push(group[0]);
    continue;
  }
  const retailValues = unique(group.map((item) => item.retailPrice.toFixed(2)));
  if (retailValues.length > 1) {
    for (const item of group) forcedReview.push({ ...item, forcedIssue: 'Duplicate product has conflicting retail prices.' });
    duplicateAudit.push({ group, action: 'Blocked: conflicting retail prices' });
    continue;
  }
  const ranked = [...group].sort((a, b) => Number(Boolean(b.imageUrl)) - Number(Boolean(a.imageUrl)) || Number(b.sourceCost > 0) - Number(a.sourceCost > 0) || Number(b.itemId) - Number(a.itemId));
  candidates.push(ranked[0]);
  duplicateAudit.push({ group, action: `Kept source item ${ranked[0].itemId}; duplicate rows ignored` });
}

for (const candidate of candidates) {
  if (!candidate.device) continue;
  const collection = BRANDED_CASE_COLLECTIONS.get(candidate.style.brand) ?? null;
  candidate.costGroupKey = `${candidate.device.code}|${candidate.style.key}`;
  candidate.groupKey = `${candidate.device.code}|${collection?.key ?? candidate.style.key}`;
  const costStyleKey = candidate.style.key === 'otterbox defender magsafe case'
    ? 'otterbox defender case'
    : candidate.style.key === 'efm aspen state case'
      ? 'efm aspen case'
      : candidate.style.key;
  const costBrand = candidate.style.brand === 'CASETiFY' ? 'OZTECHM8' : candidate.style.brand;
  candidate.styleCostKey = `${costBrand}|${costStyleKey}`;
  candidate.collection = collection;
  candidate.groupCode = `TM8-GRP-PC-${codePart(candidate.device.code, 22)}-${shortHash(collection?.key ?? candidate.style.key)}`;
  const styleGroupName = ['Universal Phone Pouch', 'Universal Flower & Pattern Phone Case', 'Special Order Phone Case'].includes(candidate.style.display)
    ? (candidate.style.display === 'Universal Phone Pouch' ? candidate.device.displayName : candidate.style.display)
    : `${candidate.style.display} for ${candidate.device.displayName}`;
  candidate.groupName = collection ? `${collection.name} for ${candidate.device.displayName}` : styleGroupName;
  candidate.proposedName = `${styleGroupName}${candidate.variantName === 'Standard' ? '' : ` - ${candidate.variantName}`}`;
  if (collection) {
    candidate.variantName = candidate.variantName === 'Standard'
      ? candidate.style.display
      : `${candidate.style.display} - ${candidate.variantName}`;
    candidate.variantType = 'image';
  }
}

const representativeImagesByGroup = new Map();
const representativeImagesByStyle = new Map();
for (const candidate of candidates.filter((item) => item.userInclude && item.imageUrl && item.costGroupKey)) {
  if (!representativeImagesByGroup.has(candidate.costGroupKey)) representativeImagesByGroup.set(candidate.costGroupKey, candidate.imageUrl);
  if (!representativeImagesByStyle.has(candidate.styleCostKey)) representativeImagesByStyle.set(candidate.styleCostKey, candidate.imageUrl);
}
for (const candidate of candidates.filter((item) => item.userInclude && !item.imageUrl && item.costGroupKey)) {
  const groupImage = representativeImagesByGroup.get(candidate.costGroupKey);
  const styleImage = representativeImagesByStyle.get(candidate.styleCostKey);
  candidate.imageUrl = groupImage || styleImage || '';
  if (candidate.imageUrl) candidate.imageFallback = groupImage ? 'repairdesk_group' : 'repairdesk_style';
}

const groupRetailModes = new Map();
const styleRetailModes = new Map();
for (const candidate of candidates.filter((item) => item.costGroupKey && item.retailPrice > 0)) {
  if (!groupRetailModes.has(candidate.costGroupKey)) groupRetailModes.set(candidate.costGroupKey, []);
  if (!styleRetailModes.has(candidate.styleCostKey)) styleRetailModes.set(candidate.styleCostKey, []);
  groupRetailModes.get(candidate.costGroupKey).push(candidate.retailPrice);
  styleRetailModes.get(candidate.styleCostKey).push(candidate.retailPrice);
}
for (const [key, values] of groupRetailModes) groupRetailModes.set(key, chooseMode(values));
for (const [key, values] of styleRetailModes) styleRetailModes.set(key, chooseMode(values));
for (const candidate of candidates.filter((item) => item.costGroupKey && !(item.retailPrice > 0))) {
  const groupMode = groupRetailModes.get(candidate.costGroupKey);
  const styleMode = styleRetailModes.get(candidate.styleCostKey);
  const fallbackRetail = groupMode?.decisive ? groupMode.value : styleMode?.decisive ? styleMode.value : null;
  if (fallbackRetail > 0) {
    candidate.retailPrice = fallbackRetail;
    candidate.retailRule = groupMode?.decisive ? 'Matched product-group retail price' : 'Matched case-style retail price';
  }
}

const groupCostStats = new Map();
for (const candidate of candidates.filter((item) => item.costGroupKey)) {
  if (!groupCostStats.has(candidate.costGroupKey)) groupCostStats.set(candidate.costGroupKey, []);
  const validSourceCost = candidate.sourceCost > 0 && candidate.sourceCost < candidate.retailPrice
    ? candidate.sourceCost
    : 0;
  groupCostStats.get(candidate.costGroupKey).push(candidate.reviewedCost || validSourceCost);
}
const groupCostModes = new Map(Array.from(groupCostStats, ([key, values]) => [key, chooseMode(values)]));
const styleKnownCosts = new Map();
for (const candidate of candidates.filter((item) => item.costGroupKey)) {
  const mode = groupCostModes.get(candidate.costGroupKey);
  if (!mode?.decisive || mode.value == null) continue;
  if (!styleKnownCosts.has(candidate.styleCostKey)) styleKnownCosts.set(candidate.styleCostKey, []);
  styleKnownCosts.get(candidate.styleCostKey).push(mode.value);
}
const styleCostModes = new Map(Array.from(styleKnownCosts, ([key, values]) => [key, chooseMode(values)]));

for (const candidate of candidates.filter((item) => item.costGroupKey)) {
  const groupMode = groupCostModes.get(candidate.costGroupKey);
  const styleMode = styleCostModes.get(candidate.styleCostKey);
  if (candidate.reviewedCost > 0) {
    candidate.finalCost = candidate.reviewedCost;
    candidate.costRule = 'Cost confirmed for this product in the phone case review workbook';
  } else if ((groupMode?.values?.length ?? 0) > 1) {
    candidate.finalCost = null;
    candidate.costRule = 'Conflicting costs within the same device and case style';
  } else if ((styleMode?.values?.length ?? 0) === 1) {
    candidate.finalCost = styleMode.values[0].value;
    candidate.costRule = candidate.sourceCost === candidate.finalCost
      ? 'Source cost confirmed across the same case style'
      : 'Normalized to the same case style cost';
  } else if ((styleMode?.values?.length ?? 0) > 1) {
    candidate.finalCost = null;
    candidate.costRule = 'Comparable case style has conflicting costs';
  } else if (groupMode?.decisive && groupMode.value != null) {
    candidate.finalCost = groupMode.value;
    candidate.costRule = 'Source cost confirmed by the same product group';
  } else {
    candidate.finalCost = null;
    candidate.costRule = 'No valid comparable cost found';
  }

  const reviewedCost = previousReviewInputs.confirmedCosts.get(candidate.styleCostKey);
  if (reviewedCost > 0 && !(candidate.reviewedCost > 0)) {
    candidate.finalCost = reviewedCost;
    candidate.costRule = 'Cost confirmed in the phone case review workbook';
  }
}

// A case style has one cost across models and colours. If that cost is not below
// every known retail price, hold the entire style for review instead of importing
// only the higher-priced variants or guessing a replacement cost.
const invalidMarginStyleKeys = new Set(
  candidates
    .filter((item) => item.styleCostKey && item.finalCost > 0 && item.retailPrice > 0 && item.finalCost >= item.retailPrice)
    .map((item) => item.styleCostKey),
);
for (const candidate of candidates.filter((item) => invalidMarginStyleKeys.has(item.styleCostKey))) {
  candidate.finalCost = null;
  candidate.costRule = 'Cost must be confirmed because the comparable style cost is not below every retail price';
}

const confirmedStyleCosts = new Map([
  ['OZTECHM8|back cover', 1],
  ['OtterBox|otterbox fre waterproof magsafe case', 59.07],
  ['EFM|efm aspen case', 45],
  ['OZTECHM8|color doc magsafe case', 8.5],
  ['OZTECHM8|daub hearts magsafe case', 5],
  ['OZTECHM8|8 magsafe case', 3],
  ['EFM|efm 13 pro max aspen armour crystalex case', 45],
  ['EFM|efm 5g aspen state case', 45],
  ['EFM|efm samsung note 20 aspen case', 45],
  ['EFM|efm samsung note 20 aspen state case', 45],
  ['EFM|efm note 20 case', 45],
  ['OZTECHM8|15 pro max back case', 1],
  ['OZTECHM8|hard case', 3],
  ['OZTECHM8|ricky case', 3],
  ['OZTECHM8|smiling magsafe case', 5],
  ['OZTECHM8|tartan design case', 3],
]);
for (const candidate of candidates.filter((item) => item.styleCostKey)) {
  const confirmedCost = confirmedStyleCosts.get(candidate.styleCostKey);
  if (confirmedCost > 0 && confirmedCost < candidate.retailPrice) {
    candidate.finalCost = confirmedCost;
    candidate.costRule = 'Confirmed against the existing POS case-style cost';
  }
}

const reviewRows = [...forcedReview];
const readyCandidates = [];
for (const candidate of candidates) {
  const issues = [];
  if (!candidate.userInclude) issues.push('Excluded by user.');
  if (!candidate.device) issues.push('Device/model is missing or ambiguous.');
  if (!candidate.imageUrl) issues.push('Product image is missing.');
  if (!(candidate.finalCost > 0)) issues.push(candidate.costRule || 'Cost is missing.');
  if (!(candidate.retailPrice > 0)) issues.push('Retail price must be greater than zero.');
  if (issues.length) reviewRows.push({ ...candidate, forcedIssue: issues.join(' ') });
  else readyCandidates.push(candidate);
}

const productDataReviewRows = reviewRows.filter((item) => item.userInclude && (
  !item.device
  || !item.imageUrl
  || !(item.retailPrice > 0)
  || /Duplicate product/.test(item.forcedIssue ?? '')
));

const collectionOptions = new Map();
for (const candidate of readyCandidates.filter((item) => item.collection)) {
  const key = `${candidate.groupCode}|${normalize(candidate.variantName)}`;
  if (!collectionOptions.has(key)) collectionOptions.set(key, []);
  collectionOptions.get(key).push(candidate);
}
for (const duplicateOptions of collectionOptions.values()) {
  if (duplicateOptions.length < 2) continue;
  for (const candidate of duplicateOptions) candidate.variantName = candidate.originalName;
}

const costQuestionMap = new Map();
for (const item of reviewRows.filter((candidate) => candidate.userInclude && !(candidate.finalCost > 0) && candidate.styleCostKey)) {
  if (!costQuestionMap.has(item.styleCostKey)) costQuestionMap.set(item.styleCostKey, []);
  costQuestionMap.get(item.styleCostKey).push(item);
}
const costQuestions = Array.from(costQuestionMap, ([key, items]) => {
  const sourceCosts = unique(items.map((item) => item.sourceCost).filter((value) => value > 0)).sort((a, b) => a - b);
  const allComparable = styleCostModes.get(key)?.values ?? [];
  const suggested = invalidMarginStyleKeys.has(key)
    ? null
    : (styleCostModes.get(key)?.decisive ? styleCostModes.get(key).value : null);
  return {
    key,
    brand: items[0].style.brand,
    style: items[0].style.display,
    products: items.length,
    devices: unique(items.map((item) => item.device?.displayName).filter(Boolean)),
    examples: unique(items.map((item) => item.originalName)).slice(0, 5),
    sourceCosts,
    comparable: allComparable,
    suggested,
  };
}).sort((a, b) => b.products - a.products || a.brand.localeCompare(b.brand) || a.style.localeCompare(b.style));

const readyGroupMap = new Map();
for (const candidate of readyCandidates) {
  if (!readyGroupMap.has(candidate.groupCode)) readyGroupMap.set(candidate.groupCode, []);
  readyGroupMap.get(candidate.groupCode).push(candidate);
}

function chooseGroupImage(variants) {
  const priority = ['Black', 'Matte Black', 'Clear', 'Blue', 'Green', 'Pink', 'Red', 'Standard'];
  for (const color of priority) {
    const match = variants.find((variant) => variant.color === color && variant.imageUrl);
    if (match) return match.imageUrl;
  }
  return variants.find((variant) => variant.imageUrl)?.imageUrl ?? '';
}

const productGroups = Array.from(readyGroupMap, ([code, variants]) => {
  const first = variants[0];
  const sortOrder = deviceSort(first.device) + (first.collection?.sort ?? familyOrder.get(first.style.family) ?? 99);
  return {
    code,
    slug: slugify(code),
    name: first.groupName,
    product_family: first.collection ? 'Branded Case Collection' : first.style.family,
    fit_profile_code: first.device.profileCode,
    main_image_url: chooseGroupImage(variants),
    pos_main_category: 'Phone Cases',
    pos_subcategory: first.device.subcategory,
    pos_sort_order: sortOrder,
    status: 'active',
    is_pos_visible: true,
    is_visible: false,
  };
}).sort((a, b) => a.pos_sort_order - b.pos_sort_order || a.name.localeCompare(b.name));

const profileMap = new Map();
for (const candidate of readyCandidates) {
  if (!profileMap.has(candidate.device.profileCode)) profileMap.set(candidate.device.profileCode, candidate.device);
}
const fitProfiles = Array.from(profileMap.values()).map((device) => ({
  code: device.profileCode,
  display_name: device.displayName,
  source_category: device.sourceCategory,
  notes: device.code === 'UNIVERSAL-PATTERN-CASE'
    ? 'Pattern and device availability vary by design. Staff must confirm the requested phone model and record it in the sale note.'
    : device.code === 'SPECIAL-ORDER-CASE'
      ? 'Generic special-order case item. Staff must record the requested phone model and case type in the sale note.'
      : `Directional phone case fit profile for ${device.displayName}.`,
  review_status: 'approved',
}));
const deviceModels = Array.from(profileMap.values()).map((device) => ({
  code: `DEVICE-${device.code}`,
  brand: device.brand,
  display_name: device.displayName,
  model_family: device.displayName.replace(/\s+(?:Pro Max|Pro|Plus|Ultra|FE|Edge|Air|mini).*$/i, '').trim(),
  generation: device.displayName.match(/(?:\d+[a-z]?|X|XS|XR)(?:\s*\/[^)]*)?/i)?.[0] ?? '',
  release_year: null,
}));
const compatibilityMappings = Array.from(profileMap.values()).map((device) => ({
  fit_profile_code: device.profileCode,
  device_model_code: `DEVICE-${device.code}`,
}));

const products = readyCandidates.map((candidate) => {
  const group = productGroups.find((item) => item.code === candidate.groupCode);
  const compatibility = candidate.variantType === 'pattern'
    ? 'Varies by pattern; confirm phone model at sale'
    : candidate.variantType === 'option'
      ? 'Phone model recorded in sale note'
      : candidate.device.displayName;
  const shortDescription = candidate.variantType === 'pattern'
    ? `${candidate.variantName} design. Confirm the required phone model before checkout.`
    : candidate.variantType === 'option'
      ? `${candidate.variantName}. Record the required phone model in the sale note.`
      : `${candidate.style.display}. Fits ${candidate.device.displayName}.`;
  return {
    sku: candidate.sku,
    slug: slugify(candidate.sku),
    name: candidate.proposedName,
    brand: candidate.style.brand,
    model: candidate.device.displayName,
    short_description: shortDescription,
    condition_label: 'Brand New',
    compatibility,
    cost_price: candidate.finalCost,
    retail_price: candidate.retailPrice,
    image_url: candidate.imageUrl,
    stock_quantity: 0,
    is_visible: false,
    is_pos_visible: true,
    upc: candidate.upc,
    product_group_code: candidate.groupCode,
    variant_name: candidate.variantName,
    variant_color: candidate.variantType === 'colour' && candidate.variantName !== 'Standard' ? candidate.variantName : null,
    source_system: 'repairdesk_phone_cases',
    source_external_id: candidate.itemId,
    source_category_path: candidate.sourceCategory,
    import_status: 'active',
    pos_main_category: 'Phone Cases',
    pos_subcategory: candidate.device.subcategory,
    pos_sort_order: group.pos_sort_order,
    source_metadata: {
      original_name: candidate.originalName,
      original_sku: candidate.originalSku,
      original_upc: candidate.originalUpc,
      source_file: candidate.sourceFile,
      source_stock: candidate.sourceStock,
      proposed_stock: 0,
      inventory_assignment: 'none',
      repairdesk_product_id: candidate.repairdeskProductId,
      inventory_index_id: candidate.inventoryIndexId,
      cost_rule: candidate.costRule,
      source_cost: candidate.sourceCost,
      variant_type: candidate.variantType,
      review_notes: candidate.userNotes,
      image_source: candidate.imageFallback
        ? candidate.imageFallback
        : candidate.itemId === '8365'
        ? 'user_provided_asset'
        : ['7159', '8085', '8073', '8067'].includes(candidate.itemId)
          ? 'skyline_mobile'
          : 'repairdesk_pos',
    },
  };
}).sort((a, b) => a.pos_sort_order - b.pos_sort_order || a.name.localeCompare(b.name));

const costCrossChecks = Array.from(new Set(candidates.filter((item) => item.styleCostKey).map((item) => item.styleCostKey))).map((key) => {
  const rows = candidates.filter((item) => item.styleCostKey === key);
  const groupCosts = unique(rows.map((item) => item.costGroupKey).filter(Boolean)).map((groupKey) => groupCostModes.get(groupKey)?.value).filter((value) => value != null);
  const mode = styleCostModes.get(key);
  return {
    brand: rows[0]?.style.brand ?? '',
    style: rows[0]?.style.display ?? '',
    products: rows.length,
    devices: unique(rows.map((item) => item.device?.displayName).filter(Boolean)).length,
    sourceCosts: unique(rows.map((item) => item.sourceCost).filter((value) => value > 0)).sort((a, b) => a - b),
    groupCosts: unique(groupCosts).sort((a, b) => a - b),
    chosenCost: invalidMarginStyleKeys.has(key) ? null : (mode?.decisive ? mode.value : null),
    status: invalidMarginStyleKeys.has(key)
      ? 'Review: cost is not below every retail price'
      : (mode?.decisive ? 'Consistent or clear mode' : 'Conflict / no cost'),
  };
}).sort((a, b) => a.brand.localeCompare(b.brand) || a.style.localeCompare(b.style));

const payload = {
  generated_at: new Date().toISOString(),
  source_files: sourcePaths.map((item) => path.basename(item)),
  category: { slug: 'phone-cases', name: 'Phone Cases' },
  release_policy: {
    pos_visible: true,
    online_visible: false,
    inventory_imported: false,
    zero_stock_sellable: true,
    blocked_rows_excluded: true,
  },
  taxonomy: [
    { category_name: 'Phone Cases', subcategory_name: 'Apple iPhone', category_sort: 10, subcategory_sort: 10 },
    { category_name: 'Phone Cases', subcategory_name: 'Samsung Galaxy', category_sort: 10, subcategory_sort: 20 },
    { category_name: 'Phone Cases', subcategory_name: 'Google Pixel', category_sort: 10, subcategory_sort: 30 },
    { category_name: 'Phone Cases', subcategory_name: 'Other & Universal', category_sort: 10, subcategory_sort: 40 },
  ],
  fit_profiles: fitProfiles,
  device_models: deviceModels,
  compatibility_mappings: compatibilityMappings,
  product_groups: productGroups,
  products,
};

let baselineSkus = new Set();
if (migrationBaselinePath) {
  const baselinePayload = JSON.parse(await fs.readFile(migrationBaselinePath, 'utf8'));
  baselineSkus = new Set((baselinePayload.products ?? []).map((product) => product.sku));
}
const migrationProducts = baselineSkus.size
  ? products.filter((product) => !baselineSkus.has(product.sku))
  : products;
const migrationGroupCodes = new Set(migrationProducts.map((product) => product.product_group_code));
const migrationGroups = productGroups.filter((group) => migrationGroupCodes.has(group.code));
const migrationProfileCodes = new Set(migrationGroups.map((group) => group.fit_profile_code));
const migrationFitProfiles = fitProfiles.filter((profile) => migrationProfileCodes.has(profile.code));
const migrationMappings = compatibilityMappings.filter((mapping) => migrationProfileCodes.has(mapping.fit_profile_code));
const migrationDeviceCodes = new Set(migrationMappings.map((mapping) => mapping.device_model_code));
const migrationDeviceModels = deviceModels.filter((device) => migrationDeviceCodes.has(device.code));
const migrationPayload = {
  ...payload,
  fit_profiles: migrationFitProfiles,
  device_models: migrationDeviceModels,
  compatibility_mappings: migrationMappings,
  product_groups: migrationGroups,
  products: migrationProducts,
};
const expectedActiveProductCount = baselineSkus.size
  ? baselineSkus.size + migrationProducts.length
  : products.length;

const staleArchiveSql = baselineSkus.size ? '' : `
update public.products product
set is_visible = false,
    is_pos_visible = false,
    import_status = 'archived',
    updated_at = timezone('utc'::text, now())
where product.source_system = 'repairdesk_phone_cases'
  and not exists (
    select 1
    from phone_case_product_input input
    where input.sku = product.sku
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
  and not exists (
    select 1
    from phone_case_group_input input
    where input.code = product_group.code
  );
`;

function jsonLiteral(value, tag) {
  return `$${tag}$${JSON.stringify(value)}$${tag}$::jsonb`;
}

const sql = `begin;

insert into public.categories (slug, name, description, sort_order)
values ('phone-cases', 'Phone Cases', 'Phone cases grouped by device, style, and colour.', 330)
on conflict (slug) do update
set name = excluded.name,
    description = excluded.description,
    sort_order = excluded.sort_order,
    updated_at = timezone('utc'::text, now());

insert into public.pos_category_taxonomy (category_name, subcategory_name, category_sort, subcategory_sort, active)
select category_name, subcategory_name, category_sort, subcategory_sort, true
from jsonb_to_recordset(${jsonLiteral(migrationPayload.taxonomy, 'taxonomy')}) as x(
  category_name text, subcategory_name text, category_sort integer, subcategory_sort integer
)
on conflict (category_name, subcategory_name) do update
set category_sort = excluded.category_sort,
    subcategory_sort = excluded.subcategory_sort,
    active = true,
    updated_at = now();

create temporary table phone_case_profile_input on commit drop as
select * from jsonb_to_recordset(${jsonLiteral(migrationPayload.fit_profiles, 'profiles')}) as x(
  code text, display_name text, source_category text, notes text, review_status text
);

create temporary table phone_case_device_input on commit drop as
select * from jsonb_to_recordset(${jsonLiteral(migrationPayload.device_models, 'devices')}) as x(
  code text, brand text, display_name text, model_family text, generation text, release_year integer
);

create temporary table phone_case_mapping_input on commit drop as
select * from jsonb_to_recordset(${jsonLiteral(migrationPayload.compatibility_mappings, 'mappings')}) as x(
  fit_profile_code text, device_model_code text
);

create temporary table phone_case_group_input on commit drop as
select * from jsonb_to_recordset(${jsonLiteral(migrationPayload.product_groups, 'groups')}) as x(
  code text, slug text, name text, product_family text, fit_profile_code text,
  main_image_url text, pos_main_category text, pos_subcategory text, pos_sort_order integer,
  status text, is_pos_visible boolean, is_visible boolean
);

create temporary table phone_case_product_input on commit drop as
select * from jsonb_to_recordset(${jsonLiteral(migrationPayload.products, 'products')}) as x(
  sku text, slug text, name text, brand text, model text, short_description text,
  condition_label text, compatibility text, cost_price numeric, retail_price numeric,
  image_url text, stock_quantity integer, is_visible boolean, is_pos_visible boolean,
  upc text, product_group_code text, variant_name text, variant_color text,
  source_system text, source_external_id text, source_category_path text,
  import_status text, pos_main_category text, pos_subcategory text, pos_sort_order integer,
  source_metadata jsonb
);

do $$
begin
  if (select count(*) from phone_case_product_input) <> ${migrationProducts.length} then
    raise exception 'Expected ${migrationProducts.length} phone case products in this migration.';
  end if;
  if exists (
    select 1 from phone_case_product_input
    where cost_price <= 0 or retail_price <= 0 or cost_price >= retail_price or stock_quantity <> 0
       or is_visible or not is_pos_visible or import_status <> 'active'
       or coalesce(btrim(image_url), '') = ''
  ) then
    raise exception 'Phone case input contains an invalid price, stock, visibility, status, or image.';
  end if;
  if exists (select sku from phone_case_product_input group by sku having count(*) > 1)
     or exists (select upc from phone_case_product_input group by upc having count(*) > 1)
     or exists (select source_external_id from phone_case_product_input group by source_external_id having count(*) > 1) then
    raise exception 'Phone case input contains a duplicate SKU, barcode, or source item.';
  end if;
end $$;

insert into public.product_fit_profiles (code, display_name, source_category, notes, review_status)
select code, display_name, source_category, notes, review_status
from phone_case_profile_input
on conflict (code) do update
set display_name = excluded.display_name,
    source_category = excluded.source_category,
    notes = excluded.notes,
    review_status = excluded.review_status,
    updated_at = timezone('utc'::text, now());

insert into public.device_models (code, brand, display_name, model_family, generation, release_year)
select code, brand, display_name, model_family, generation, release_year
from phone_case_device_input
on conflict (code) do update
set brand = excluded.brand,
    display_name = excluded.display_name,
    model_family = excluded.model_family,
    generation = excluded.generation,
    release_year = excluded.release_year,
    updated_at = timezone('utc'::text, now());

insert into public.product_fit_profile_devices (fit_profile_id, device_model_id)
select profile.id, device.id
from phone_case_mapping_input input
join public.product_fit_profiles profile on profile.code = input.fit_profile_code
join public.device_models device on device.code = input.device_model_code
on conflict (fit_profile_id, device_model_id) do nothing;

insert into public.product_groups (
  code, slug, name, category_id, product_family, fit_profile_id, main_image_url,
  status, is_pos_visible, is_visible, pos_category_id, pos_sort_order
)
select
  input.code, input.slug, input.name, category.id, input.product_family, profile.id,
  input.main_image_url, input.status, input.is_pos_visible, input.is_visible,
  taxonomy.id, input.pos_sort_order
from phone_case_group_input input
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
from phone_case_product_input input
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

${staleArchiveSql}

do $$
begin
  if (select count(*) from public.products where source_system = 'repairdesk_phone_cases' and import_status = 'active') <> ${expectedActiveProductCount} then
    raise exception 'Phone case database count does not match the import.';
  end if;
  if exists (
    select 1 from public.products product
    join phone_case_product_input input on input.sku = product.sku
    left join public.product_groups product_group on product_group.id = product.product_group_id
    left join public.pos_category_taxonomy taxonomy on taxonomy.id = product.pos_category_id
    where product.cost_price <= 0 or product.retail_price <= 0 or product.cost_price >= product.retail_price or product.stock_quantity <> 0
        or not product.is_pos_visible or product.import_status <> 'active'
        or product_group.id is null or taxonomy.category_name <> 'Phone Cases'
  ) then
    raise exception 'Imported phone case verification failed.';
  end if;
end $$;

commit;

select
  count(*) as imported_products,
  count(distinct product_group_id) as product_groups,
  count(*) filter (where is_pos_visible and import_status = 'active') as active_pos_products,
  count(*) filter (where stock_quantity <> 0) as products_with_nonzero_catalog_stock
from public.products
where source_system = 'repairdesk_phone_cases';
`;

await fs.mkdir(outputDir, { recursive: true });
await fs.writeFile(payloadPath, JSON.stringify(payload, null, 2), 'utf8');
await fs.writeFile(migrationPath, sql, 'utf8');

const reviewWorkbook = Workbook.create();
const summarySheet = reviewWorkbook.worksheets.add('Summary');
const reviewSheet = reviewWorkbook.worksheets.add('Needs Your Input');
const costQuestionSheet = reviewWorkbook.worksheets.add('Cost To Confirm');
const importedSheet = reviewWorkbook.worksheets.add('Imported Products');
const costSheet = reviewWorkbook.worksheets.add('Cost Cross-check');
const duplicateSheet = reviewWorkbook.worksheets.add('Duplicate Audit');
const excludedSheet = reviewWorkbook.worksheets.add('Not Phone Cases');

summarySheet.showGridLines = false;
summarySheet.getRange('A1:H1').merge();
summarySheet.getRange('A1').values = [['TECHM8 Phone Case Import Review']];
summarySheet.getRange('A1:H1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF', size: 18 }, verticalAlignment: 'center' };
summarySheet.getRange('A1:H1').format.rowHeight = 36;
summarySheet.getRange('A3:B13').values = [
  ['Metric', 'Value'],
  ['Source rows checked', records.length],
  ['Products imported to POS', products.length],
  ['Product groups created', productGroups.length],
  ['Device fit profiles', fitProfiles.length],
  ['Case style costs to confirm', costQuestions.length],
  ['Products needing model, image, or price input', productDataReviewRows.length],
  ['Duplicate rows not imported twice', duplicateAudit.reduce((sum, item) => sum + item.group.length - 1, 0)],
  ['Non-phone-case accessories excluded', nonPhoneCases.length],
  ['Imported with product images', products.filter((item) => item.image_url).length],
  ['Imported store stock', 0],
];
summarySheet.getRange('A3:B3').format = { fill: '#DFF4EF', font: { bold: true, color: '#075E54' } };
summarySheet.getRange('B4:B13').format.numberFormat = '0';
summarySheet.getRange('D3:H3').merge();
summarySheet.getRange('D3').values = [['Import Rules Applied']];
summarySheet.getRange('D3:H3').format = { fill: '#DFF4EF', font: { bold: true, color: '#075E54' } };
summarySheet.getRange('D4:H10').merge(true);
summarySheet.getRange('D4:H10').values = [
  ['Each device and case style is one POS card; colours are selectable variants.'],
  ['The same device and case style uses one cost. Zero costs are filled only from a reliable matching group or style.'],
  ['Conflicting costs, costs at or above retail, missing images, ambiguous device models, and zero retail prices are not imported.'],
  ['All four stores and the online store start at zero stock. Zero stock can still be sold.'],
  ['POS visibility is enabled; public website visibility remains disabled.'],
  ['AirPods and AirTag accessories are excluded because they are not phone cases.'],
  ['The Needs Your Input sheet contains only rows that require a decision or missing data.'],
];
summarySheet.getRange('D4:H10').format = { fill: '#F5FAF8', wrapText: true, font: { color: '#274640' } };
summarySheet.getRange('A14:H14').merge();
summarySheet.getRange('A14').values = [[costQuestions.length || productDataReviewRows.length
  ? 'Cost To Confirm: enter the cost in the yellow Confirmed Cost column. Needs Your Input: follow column C and edit only the yellow columns D-H.'
  : 'No additional product information or cost confirmation is required.']];
summarySheet.getRange('A14:H14').format = { fill: '#FFF3CD', font: { bold: true, color: '#664D03' }, wrapText: true };
summarySheet.getRange('A:A').format.columnWidth = 42;
summarySheet.getRange('B:B').format.columnWidth = 18;
summarySheet.getRange('D:H').format.columnWidth = 18;

const reviewHeaders = ['Source Item ID', 'Product', 'Required Action', 'Final Device / Compatibility', 'Final Retail', 'Final Image URL', 'Include?', 'Notes', 'Case Style', 'Source Category', 'Source Cost', 'Confirmed Cost', 'Source Retail', 'Original Issue', 'Current Proposal', 'Status'];
reviewSheet.getRange('A1:P1').values = [reviewHeaders];
if (productDataReviewRows.length) {
  reviewSheet.getRange(`A2:O${productDataReviewRows.length + 1}`).values = productDataReviewRows.map((item) => {
    const actions = [];
    if (!item.userInclude) actions.push('No action: excluded by your choice');
    if (!item.device) actions.push('Enter the exact device/model in column D');
    if (!(item.retailPrice > 0)) actions.push('Enter the selling price in column E');
    if (!item.imageUrl) actions.push('Paste the product image URL in column F');
    if (!(item.finalCost > 0)) actions.push('Confirm this case style on the Cost To Confirm sheet');
    return [
      item.itemId,
      item.originalName,
      actions.join('; '),
      item.device?.displayName ?? '',
      item.retailPrice,
      item.imageUrl,
      item.userInclude ? 'Yes' : 'No',
      item.userNotes,
      item.style?.display ?? '',
      item.sourceCategory,
      item.sourceCost,
      item.finalCost,
      item.retailPrice,
      item.forcedIssue,
      item.device?.displayName ?? '',
    ];
  });
  reviewSheet.getRange('P2').formulas = [['=IF(G2="No","Excluded",IF(OR(D2="",E2<=0,F2="",L2<=0),"Needs input","Ready to import"))']];
  reviewSheet.getRange(`P2:P${productDataReviewRows.length + 1}`).fillDown();
  reviewSheet.tables.add(`A1:P${productDataReviewRows.length + 1}`, true, 'PhoneCaseNeedsInput');
  reviewSheet.getRange(`E2:E${productDataReviewRows.length + 1}`).format.numberFormat = '$#,##0.00';
  reviewSheet.getRange(`K2:M${productDataReviewRows.length + 1}`).format.numberFormat = '$#,##0.00';
  reviewSheet.getRange(`D2:H${productDataReviewRows.length + 1}`).format = { fill: '#FFF3CD', font: { color: '#664D03' } };
  reviewSheet.getRange(`C2:C${productDataReviewRows.length + 1}`).format = { fill: '#E7F3FF', font: { bold: true, color: '#155A8A' }, wrapText: true };
  reviewSheet.getRange(`P2:P${productDataReviewRows.length + 1}`).conditionalFormats.add('containsText', { text: 'Needs input', format: { fill: '#FDE7E3', font: { bold: true, color: '#9C2F22' } } });
  reviewSheet.getRange(`P2:P${productDataReviewRows.length + 1}`).conditionalFormats.add('containsText', { text: 'Ready to import', format: { fill: '#DFF4EF', font: { bold: true, color: '#075E54' } } });
} else {
  reviewSheet.getRange('A2:P4').merge();
  reviewSheet.getRange('A2').values = [['No additional information is required.']];
  reviewSheet.getRange('A2:P4').format = { fill: '#DFF4EF', font: { bold: true, color: '#075E54' }, verticalAlignment: 'center' };
}
reviewSheet.freezePanes.freezeRows(1);
reviewSheet.freezePanes.freezeColumns(3);
reviewSheet.getRange('A1:P1').format = { fill: '#9C2F22', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
reviewSheet.getRange(`A1:P${Math.max(4, productDataReviewRows.length + 1)}`).format.verticalAlignment = 'top';
reviewSheet.getRange(`B2:D${Math.max(2, productDataReviewRows.length + 1)}`).format.wrapText = true;
reviewSheet.getRange(`F2:J${Math.max(2, productDataReviewRows.length + 1)}`).format.wrapText = true;
reviewSheet.getRange(`N2:P${Math.max(2, productDataReviewRows.length + 1)}`).format.wrapText = true;
reviewSheet.getRange('A:A').format.columnWidth = 16;
reviewSheet.getRange('B:B').format.columnWidth = 42;
reviewSheet.getRange('C:C').format.columnWidth = 48;
reviewSheet.getRange('D:D').format.columnWidth = 34;
reviewSheet.getRange('E:E').format.columnWidth = 18;
reviewSheet.getRange('F:F').format.columnWidth = 48;
reviewSheet.getRange('G:H').format.columnWidth = 18;
reviewSheet.getRange('I:I').format.columnWidth = 30;
reviewSheet.getRange('J:J').format.columnWidth = 34;
reviewSheet.getRange('K:M').format.columnWidth = 18;
reviewSheet.getRange('N:N').format.columnWidth = 48;
reviewSheet.getRange('O:O').format.columnWidth = 34;
reviewSheet.getRange('P:P').format.columnWidth = 20;

costQuestionSheet.showGridLines = false;
costQuestionSheet.getRange('A1:J1').values = [['Brand', 'Case Style', 'Affected Products', 'Devices', 'Examples', 'Positive Source Costs', 'Comparable Cost Counts', 'Suggested Cost', 'Confirmed Cost', 'Status']];
if (costQuestions.length) {
  costQuestionSheet.getRange(`A2:I${costQuestions.length + 1}`).values = costQuestions.map((item) => [
    item.brand,
    item.style,
    item.products,
    item.devices.join(', '),
    item.examples.join('\n'),
    item.sourceCosts.map(moneyText).join(', '),
    item.comparable.map((entry) => `${moneyText(entry.value)} x ${entry.count}`).join(', '),
    item.suggested,
    item.suggested,
  ]);
  costQuestionSheet.getRange('J2').formulas = [['=IF(I2>0,"Ready","Cost required")']];
  costQuestionSheet.getRange(`J2:J${costQuestions.length + 1}`).fillDown();
  costQuestionSheet.tables.add(`A1:J${costQuestions.length + 1}`, true, 'PhoneCaseCostQuestions');
  costQuestionSheet.getRange(`H2:I${costQuestions.length + 1}`).format.numberFormat = '$#,##0.00';
  costQuestionSheet.getRange(`I2:I${costQuestions.length + 1}`).format = { fill: '#FFF3CD', font: { bold: true, color: '#664D03' }, numberFormat: '$#,##0.00' };
  costQuestionSheet.getRange(`J2:J${costQuestions.length + 1}`).conditionalFormats.add('containsText', { text: 'Cost required', format: { fill: '#FDE7E3', font: { bold: true, color: '#9C2F22' } } });
  costQuestionSheet.getRange(`J2:J${costQuestions.length + 1}`).conditionalFormats.add('containsText', { text: 'Ready', format: { fill: '#DFF4EF', font: { bold: true, color: '#075E54' } } });
}
costQuestionSheet.freezePanes.freezeRows(1);
costQuestionSheet.getRange('A1:J1').format = { fill: '#9C2F22', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
costQuestionSheet.getRange(`A2:J${Math.max(2, costQuestions.length + 1)}`).format.wrapText = true;
costQuestionSheet.getRange('A:B').format.columnWidth = 30;
costQuestionSheet.getRange('C:C').format.columnWidth = 18;
costQuestionSheet.getRange('D:D').format.columnWidth = 52;
costQuestionSheet.getRange('E:E').format.columnWidth = 56;
costQuestionSheet.getRange('F:G').format.columnWidth = 28;
costQuestionSheet.getRange('H:J').format.columnWidth = 18;

const importedHeaders = ['New SKU', 'Product Name', 'Brand', 'Device', 'Case Style', 'Colour / Variant', 'Cost', 'Retail', 'POS Category', 'POS Subcategory', 'Image URL', 'Source Item ID', 'Cost Rule'];
importedSheet.getRange('A1:M1').values = [importedHeaders];
importedSheet.getRange(`A2:M${products.length + 1}`).values = products.map((product) => [
  product.sku, product.name, product.brand, product.model,
  readyCandidates.find((item) => item.itemId === product.source_external_id)?.style.display ?? '',
  product.variant_name, product.cost_price, product.retail_price, product.pos_main_category,
  product.pos_subcategory, product.image_url, product.source_external_id,
  product.source_metadata.cost_rule,
]);
importedSheet.tables.add(`A1:M${products.length + 1}`, true, 'ImportedPhoneCases');
importedSheet.freezePanes.freezeRows(1);
importedSheet.getRange('A1:M1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
importedSheet.getRange(`G2:H${products.length + 1}`).format.numberFormat = '$#,##0.00';
importedSheet.getRange(`B2:M${products.length + 1}`).format.wrapText = true;
importedSheet.getRange('A:A').format.columnWidth = 18;
importedSheet.getRange('B:B').format.columnWidth = 44;
importedSheet.getRange('C:F').format.columnWidth = 24;
importedSheet.getRange('G:J').format.columnWidth = 18;
importedSheet.getRange('K:K').format.columnWidth = 48;
importedSheet.getRange('L:M').format.columnWidth = 24;

costSheet.getRange('A1:H1').values = [['Brand', 'Comparable Case Style', 'Rows', 'Devices', 'Positive Source Costs', 'Canonical Group Costs', 'Suggested Cross-model Cost', 'Status']];
costSheet.getRange(`A2:H${costCrossChecks.length + 1}`).values = costCrossChecks.map((item) => [
  item.brand, item.style, item.products, item.devices,
  item.sourceCosts.map(moneyText).join(', '), item.groupCosts.map(moneyText).join(', '),
  item.chosenCost, item.status,
]);
costSheet.tables.add(`A1:H${costCrossChecks.length + 1}`, true, 'PhoneCaseCostCrossCheck');
costSheet.freezePanes.freezeRows(1);
costSheet.getRange('A1:H1').format = { fill: '#087F6B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
costSheet.getRange(`G2:G${costCrossChecks.length + 1}`).format.numberFormat = '$#,##0.00';
costSheet.getRange(`A2:H${costCrossChecks.length + 1}`).format.wrapText = true;
costSheet.getRange('A:B').format.columnWidth = 32;
costSheet.getRange('C:D').format.columnWidth = 14;
costSheet.getRange('E:F').format.columnWidth = 34;
costSheet.getRange('G:H').format.columnWidth = 24;

const duplicateRows = duplicateAudit.flatMap((audit) => audit.group.map((item) => [item.itemId, item.originalName, item.sourceCategory, item.sourceCost, item.retailPrice, audit.action]));
duplicateSheet.getRange('A1:F1').values = [['Source Item ID', 'Original Name', 'Source Category', 'Cost', 'Retail', 'Action']];
if (duplicateRows.length) {
  duplicateSheet.getRange(`A2:F${duplicateRows.length + 1}`).values = duplicateRows;
  duplicateSheet.tables.add(`A1:F${duplicateRows.length + 1}`, true, 'PhoneCaseDuplicateAudit');
  duplicateSheet.getRange(`D2:E${duplicateRows.length + 1}`).format.numberFormat = '$#,##0.00';
}
duplicateSheet.freezePanes.freezeRows(1);
duplicateSheet.getRange('A1:F1').format = { fill: '#59636B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
duplicateSheet.getRange('A:A').format.columnWidth = 16;
duplicateSheet.getRange('B:C').format.columnWidth = 40;
duplicateSheet.getRange('D:E').format.columnWidth = 16;
duplicateSheet.getRange('F:F').format.columnWidth = 44;

excludedSheet.getRange('A1:F1').values = [['Source Item ID', 'Original Name', 'Source Category', 'Cost', 'Retail', 'Reason Excluded']];
excludedSheet.getRange(`A2:F${nonPhoneCases.length + 1}`).values = nonPhoneCases.map(({ record, reason }) => [record['Item ID'], record['Item Name'], record.Category, numberValue(record['Cost Price']), numberValue(record['Retail Price']), reason]);
excludedSheet.tables.add(`A1:F${nonPhoneCases.length + 1}`, true, 'PhoneCaseNonCaseExclusions');
excludedSheet.freezePanes.freezeRows(1);
excludedSheet.getRange('A1:F1').format = { fill: '#59636B', font: { bold: true, color: '#FFFFFF' }, wrapText: true };
excludedSheet.getRange(`D2:E${nonPhoneCases.length + 1}`).format.numberFormat = '$#,##0.00';
excludedSheet.getRange('A:A').format.columnWidth = 16;
excludedSheet.getRange('B:C').format.columnWidth = 42;
excludedSheet.getRange('D:E').format.columnWidth = 16;
excludedSheet.getRange('F:F').format.columnWidth = 48;

const preview = await reviewWorkbook.render({
  sheetName: costQuestions.length ? 'Cost To Confirm' : 'Summary',
  range: costQuestions.length ? `A1:J${Math.max(5, Math.min(costQuestions.length + 1, 22))}` : 'A1:H14',
  scale: 1,
  format: 'png',
});
await fs.writeFile(previewPath, new Uint8Array(await preview.arrayBuffer()));
const inspection = await reviewWorkbook.inspect({ kind: 'table', range: 'Summary!A1:H14', include: 'values,formulas', tableMaxRows: 20, tableMaxCols: 10, maxChars: 5000 });
const formulaErrors = await reviewWorkbook.inspect({ kind: 'match', searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A', options: { useRegex: true, maxResults: 300 }, summary: 'phone case review formula scan' });
const output = await SpreadsheetFile.exportXlsx(reviewWorkbook);
await output.save(workbookPath);

console.log(JSON.stringify({
  sourceRows: records.length,
  readyProducts: products.length,
  groups: productGroups.length,
  profiles: fitProfiles.length,
  reviewRows: reviewRows.length,
  productDataReviewRows: productDataReviewRows.length,
  costQuestions: costQuestions.length,
  nonPhoneCases: nonPhoneCases.length,
  duplicateRows: duplicateRows.length,
  imageMatchedReady: products.filter((item) => item.image_url).length,
  workbookPath,
  payloadPath,
  migrationPath,
  previewPath,
  inspection: inspection.ndjson,
  formulaErrors: formulaErrors.ndjson,
}, null, 2));
