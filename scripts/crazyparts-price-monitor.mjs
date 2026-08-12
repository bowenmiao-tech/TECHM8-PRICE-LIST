import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { SpreadsheetFile, Workbook } from '@oai/artifact-tool';
import { reportCrazyPartsStatus, trackedFamilyFromArgs } from './crazyparts-status.mjs';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const configPath = path.join(projectRoot, 'crazyparts-price-monitor.config.json');

function parseArgs(argv) {
  const options = {
    all: false,
    headful: false,
    maxModels: 0,
    concurrency: 1,
    families: [],
    models: [],
    rebuildLatest: false,
    listFamilies: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--all') options.all = true;
    else if (arg === '--headful') options.headful = true;
    else if (arg === '--family') options.families.push(argv[++index]);
    else if (arg === '--model') options.models.push(argv[++index]);
    else if (arg === '--max-models') options.maxModels = Number(argv[++index] || 0);
    else if (arg === '--concurrency') options.concurrency = Number(argv[++index] || 1);
    else if (arg === '--rebuild-latest') options.rebuildLatest = true;
    else if (arg === '--list-families') options.listFamilies = true;
    else if (arg === '--help') options.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }

  return options;
}

function printHelp() {
  console.log(`TECHM8 Crazy Parts price monitor

Usage:
  node scripts/crazyparts-price-monitor.mjs --all
  node scripts/crazyparts-price-monitor.mjs --family "A Series"
  node scripts/crazyparts-price-monitor.mjs --model "a17-5g-(a176)"

Options:
  --all                Process every discovered model
  --family <name>      Process one menu family, for example "A Series"
  --model <slug/url>   Process one model; may be repeated
  --max-models <n>     Limit the selected models for a controlled test
  --concurrency <n>    Number of model pages processed in parallel (default 1)
  --headful            Show the browser window
  --rebuild-latest     Rebuild the workbook from the latest saved raw run
  --list-families      Log in and list the currently available model families
`);
}

function brisbaneTimestamp(date = new Date()) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Australia/Brisbane',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}T${values.hour}:${values.minute}:${values.second}+10:00`;
}

function safeRunId(timestamp) {
  return timestamp.replace(/[-:]/g, '').replace('T', '-').replace('+1000', '').replace('+10:00', '');
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function cleanMenuText(text) {
  return String(text || '')
    .replace(/Coming Soon/gi, '')
    .replace(/New$/i, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function normaliseModelHref(input) {
  const value = String(input || '').trim();
  if (!value) return null;
  if (/^https?:\/\//i.test(value)) return new URL(value).pathname;
  if (value.startsWith('/products/')) return value.split('?')[0];
  return `/products/${value.replace(/^\/+|\/+$/g, '')}`;
}

function isEligibleRepairModel(model) {
  const family = String(model.family || '').trim().toLowerCase();
  const name = String(model.name || '').trim();
  if (name.toLowerCase() === family) return false;
  if (family === 'sony' && (/playstation/i.test(name) || /^sony\s+xperia$/i.test(name))) return false;
  return true;
}

function categoryLabel(category) {
  return {
    screen: 'Screen',
    battery: 'Battery',
    charging_port: 'Charging Port',
    camera: 'Camera',
  }[category];
}

function classifyProduct(name) {
  const value = String(name || '').toLowerCase().replace(/[–—]/g, '-');

  const screenExcluded = /(screen protector|tempered glass|protective glass|rear cover|back glass|tester|testing|test cable|fpc connector|lcd connector|screen connector|display connector|screen flex|lcd flex|digitizer flex|frame only|middle frame|housing|front glass|screen glass only)/i;
  const screenTerms = /(\blcd\b|\boled\b|screen replacement|screen assembly|display assembly|digitizer)/i;
  if (!screenExcluded.test(value) && screenTerms.test(value)) return 'screen';

  const batteryExcluded = /(battery adhesive|battery sticker|battery pull tab|battery cover|battery door|battery connector|battery tester|power bank|battery case)/i;
  const batteryTerms = /\bbattery\b|\b\d{3,5}\s?mah\b.*\beb-[a-z0-9-]+/i;
  if (batteryTerms.test(value) && !batteryExcluded.test(value)) return 'battery';

  const portTerms = /(charging port|charge port|charger port|dock connector|charging connector|usb[- ]?[c]?(?: port| connector)|\bcport\b)/i;
  const portExcluded = /(tester|test cable|wall charger|car charger|charging adapter)/i;
  if (portTerms.test(value) && !portExcluded.test(value)) return 'charging_port';

  const cameraTerms = /(front camera|rear camera|camera module|camera assembly)/i;
  const cameraExcluded = /(camera glass|camera lens|lens glass|camera frame|camera cover|camera protector|camera protection)/i;
  if (cameraTerms.test(value) && !cameraExcluded.test(value)) return 'camera';

  return null;
}

function productMatchesModel(productName, modelHeading) {
  const title = String(productName || '');
  const heading = String(modelHeading || '');
  const parenthetical = [...heading.matchAll(/\(([^)]+)\)/g)].map((match) => match[1]).join(' ');
  const modelCodes = parenthetical.match(/\b[A-Z]\d{2,4}[A-Z]?\b/gi) || [];
  if (modelCodes.some((code) => new RegExp(`\\b${code}[A-Z]?\\b`, 'i').test(title))) return true;

  const plainHeading = heading.replace(/^Samsung\s+(?:Galaxy\s+)?/i, '').trim();
  const token = plainHeading.match(/^([A-Z]\d+[A-Z]*)\b/i)?.[1];
  if (!token) return true;
  return new RegExp(`\\b(?:Samsung(?:\\s+Galaxy)?|Galaxy)\\s+${token}\\b`, 'i').test(title);
}

function parseMoney(value) {
  const number = Number(String(value || '').replace(/[^0-9.]/g, ''));
  return Number.isFinite(number) ? number : null;
}

function isAvailableStock(stock) {
  return /in stock|low stock/i.test(stock || '');
}

async function launchBrowser(config, headful) {
  const baseOptions = {
    headless: !headful,
    args: ['--disable-blink-features=AutomationControlled'],
  };

  const channels = [config.browserChannel, 'chrome', 'msedge'].filter(Boolean);
  let lastError;
  for (const channel of [...new Set(channels)]) {
    try {
      return await chromium.launch({ ...baseOptions, channel });
    } catch (error) {
      lastError = error;
    }
  }

  throw new Error(`Could not launch Chrome or Edge: ${lastError?.message || 'unknown error'}`);
}

async function login(page, config, email, password) {
  let finalDetail = '';
  const attempts = Math.max(1, config.loginAttempts || 1);
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    await page.goto(`${config.baseUrl}/account/login`, {
      waitUntil: 'domcontentloaded',
      timeout: config.navigationTimeoutMs,
    });

    await page.getByPlaceholder('Enter your email address').fill(email);
    await page.getByPlaceholder('Enter your password').fill(password);
    const termsCheckbox = page.getByRole('checkbox', { name: /terms and conditions/i });
    if (await termsCheckbox.isVisible().catch(() => false)) {
      await termsCheckbox.setChecked(true);
    }
    await page.getByRole('button', { name: 'Login', exact: true }).click();
    try {
      await page.waitForURL(/\/member\/dashboard/, {
        waitUntil: 'domcontentloaded',
        timeout: config.navigationTimeoutMs,
      });
      finalDetail = '';
      break;
    } catch {
      const visibleAlerts = await page.locator('[role="alert"], .ant-message, .ant-notification').allTextContents().catch(() => []);
      finalDetail = visibleAlerts.map((value) => value.trim()).filter(Boolean).join(' | ');
      if (attempt < attempts) await sleep(config.loginRetryDelayMs || 5000);
    }
  }

  if (!page.url().includes('/member/dashboard')) {
    throw new Error(`Login did not reach the member dashboard after ${attempts} attempt(s)${finalDetail ? `: ${finalDetail}` : ''}.`);
  }

  const dashboardText = await page.locator('body').innerText();
  if (!dashboardText.includes(config.expectedMemberTier)) {
    throw new Error(`Login succeeded, but the expected ${config.expectedMemberTier} member tier was not found.`);
  }
}

async function discoverModels(page, config) {
  await page.goto(config.baseUrl, {
    waitUntil: 'domcontentloaded',
    timeout: config.navigationTimeoutMs,
  });

  const result = await page.locator('div.hidden').evaluateAll((elements) => {
    const host = elements.find((element) => {
      const navs = [...element.children].filter((child) => child.tagName === 'NAV');
      return navs.length >= 4
        && (navs[0].innerText || '').startsWith('iPhone')
        && (navs[1].innerText || '').startsWith('S Series');
    });

    if (!host) return null;

    const navBrands = ['Apple', 'Samsung', 'Google', 'Other Models'];
    return [...host.children].slice(0, 4).flatMap((nav, navIndex) => {
      return [...nav.children].flatMap((group) => {
        const children = [...group.children];
        const anchors = children.filter((child) => child.tagName === 'A' && child.getAttribute('href')?.startsWith('/products/'));
        if (!anchors.length) return [];

        const firstChild = children[0];
        const family = (firstChild?.textContent || navBrands[navIndex]).trim();
        const modelAnchors = firstChild?.tagName === 'A' && anchors.length > 1 ? anchors.slice(1) : anchors;

        return modelAnchors.map((anchor) => ({
          brand: navBrands[navIndex],
          family,
          name: (anchor.textContent || '').trim(),
          href: anchor.getAttribute('href').split('?')[0],
        }));
      });
    });
  });

  if (!result?.length) {
    throw new Error('The model navigation menu could not be found. The Crazy Parts page layout may have changed.');
  }

  const unique = new Map();
  for (const item of result) {
    const name = cleanMenuText(item.name);
    if (!name || /Coming Soon/i.test(item.name)) continue;
    if (!unique.has(item.href)) {
      unique.set(item.href, { ...item, family: cleanMenuText(item.family), name });
    }
  }
  return [...unique.values()];
}

async function extractProductCards(page, config) {
  const tier = config.expectedMemberTier;
  return page.locator('a[href^="/products/detail/"]').evaluateAll((anchors, expectedTier) => {
    const uniqueAnchors = new Map();
    for (const anchor of anchors) {
      const href = anchor.getAttribute('href')?.split('&')[0];
      if (href && !uniqueAnchors.has(href)) uniqueAnchors.set(href, anchor);
    }

    const products = [];
    for (const [href, anchor] of uniqueAnchors.entries()) {
      let node = anchor;
      let card = null;
      while (node && node !== document.body) {
        const uniqueDetailLinks = new Set(
          [...node.querySelectorAll('a[href^="/products/detail/"]')]
            .map((link) => link.getAttribute('href')?.split('&')[0])
            .filter(Boolean),
        );
        const hasCartButton = [...node.querySelectorAll('button')]
          .some((button) => /Add To Cart/i.test(button.innerText || ''));
        if (hasCartButton && uniqueDetailLinks.size === 1) {
          card = node;
          break;
        }
        node = node.parentElement;
      }
      if (!card) continue;

      const matchingLinks = [...card.querySelectorAll(`a[href^="${href.split('?')[0]}"]`)];
      const title = matchingLinks
        .map((link) => (link.innerText || link.querySelector('img')?.alt || '').trim())
        .sort((a, b) => b.length - a.length)[0];
      const lines = (card.innerText || '').split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
      const tierIndex = lines.findIndex((line) => line.toLowerCase() === String(expectedTier).toLowerCase());
      const memberPriceLine = tierIndex >= 0
        ? lines.slice(tierIndex + 1).find((line) => /^\$[\d,.]+$/.test(line))
        : null;
      const syd = lines.find((line) => /^SYD:/i.test(line)) || '';
      const mel = lines.find((line) => /^MEL:/i.test(line)) || '';

      if (title && memberPriceLine) {
        products.push({ title, href, memberPriceLine, syd, mel });
      }
    }
    return products;
  }, tier);
}

async function scrapeModel(page, model, config) {
  const productMap = new Map();
  let pageNumber = 1;
  let totalPages = 1;
  let heading = model.name;

  do {
    const url = new URL(model.href, config.baseUrl);
    url.searchParams.set('page', String(pageNumber));
    await page.goto(url.toString(), {
      waitUntil: 'domcontentloaded',
      timeout: config.navigationTimeoutMs,
    });

    if (page.url().includes('/account/login')) {
      throw new Error('The Crazy Parts session expired during the run.');
    }

    const bodyText = await page.locator('body').innerText();
    const documentTitle = await page.title();
    if (/Error 1015|rate.?limit|you are being rate limited/i.test(`${documentTitle}\n${bodyText}`)) {
      const error = new Error('Crazy Parts rate limit (Error 1015)');
      error.code = 'CRAZYPARTS_RATE_LIMIT';
      throw error;
    }

    heading = cleanMenuText(await page.locator('h1').first().innerText().catch(() => model.name));
    if (/Login to see price/i.test(bodyText)) {
      throw new Error('Member pricing is no longer available in the current session.');
    }

    if (pageNumber === 1) {
      const itemMatch = bodyText.match(/(\d+)\s+items/i);
      const itemCount = itemMatch ? Number(itemMatch[1]) : 0;
      totalPages = Math.max(1, Math.ceil(itemCount / config.pageSize));
    }

    const cards = await extractProductCards(page, config);
    for (const card of cards) {
      const price = parseMoney(card.memberPriceLine);
      if (price == null) continue;
      const category = classifyProduct(card.title);
      const stock = [card.syd, card.mel].filter(Boolean).join(' | ');
      productMap.set(card.href, {
        category,
        name: card.title,
        price,
        sydStock: card.syd.replace(/^SYD:/i, '').trim(),
        melStock: card.mel.replace(/^MEL:/i, '').trim(),
        available: isAvailableStock(stock),
        url: new URL(card.href, config.baseUrl).toString(),
      });
    }

    pageNumber += 1;
    if (pageNumber <= totalPages) await sleep(config.pageDelayMs);
  } while (pageNumber <= totalPages);

  return { ...model, heading, products: [...productMap.values()] };
}

function summariseModels(models, capturedAt) {
  const repairRows = [];
  const sourceRows = [];
  const exceptions = [];
  const categories = ['screen', 'battery', 'charging_port', 'camera'];

  for (const model of models) {
    if (!isEligibleRepairModel({ ...model, name: model.heading || model.name })) continue;
    const relevant = model.products.filter((product) => (
      product.category && productMatchesModel(product.name, model.heading || model.name)
    ));
    for (const product of relevant) {
      sourceRows.push({
        brand: model.brand,
        family: model.family,
        model: model.heading || model.name,
        modelUrl: model.href,
        repairType: categoryLabel(product.category),
        ...product,
        capturedAt,
      });
    }

    for (const category of categories) {
      const matching = relevant.filter((product) => product.category === category);
      const active = matching.filter((product) => product.available).sort((a, b) => a.price - b.price);
      if (!matching.length) continue;
      if (!active.length) {
        exceptions.push({
          brand: model.brand,
          model: model.heading || model.name,
          repairType: categoryLabel(category),
          issue: 'All matching parts are out of stock',
          details: `${matching.length} matching product(s) found`,
          url: new URL(model.href, 'https://www.crazyparts.com.au').toString(),
        });
        continue;
      }

      const minimum = active[0];
      const maximum = active[active.length - 1];
      const lowStockOnly = active.every((product) => /low stock/i.test(`${product.sydStock} ${product.melStock}`)
        && !/in stock/i.test(`${product.sydStock} ${product.melStock}`));
      repairRows.push({
        brand: model.brand,
        family: model.family,
        model: model.heading || model.name,
        repairType: categoryLabel(category),
        minPartPrice: minimum.price,
        maxPartPrice: maximum.price,
        optionCount: active.length,
        stockSummary: lowStockOnly ? 'Low stock only' : 'Available',
        status: 'OK',
        minProduct: minimum.name,
        maxProduct: maximum.name,
        minUrl: minimum.url,
        maxUrl: maximum.url,
        capturedAt,
      });
    }
  }

  return { repairRows, sourceRows, exceptions };
}

async function loadPreviousSuccessfulRun(historyDir) {
  const files = (await fs.readdir(historyDir).catch(() => []))
    .filter((name) => name.endsWith('.json') && !name.endsWith('-failed.json'))
    .sort()
    .reverse();
  for (const fileName of files) {
    try {
      const parsed = JSON.parse(await fs.readFile(path.join(historyDir, fileName), 'utf8'));
      const rows = [...(parsed.repairRows || []), ...(parsed.sourceRows || [])];
      const hasRateLimitPage = rows.some((row) => /Error 1015|rate.?limit/i.test(`${row.model || ''} ${row.name || ''}`));
      const representedModels = new Set((parsed.sourceRows || []).map((row) => `${row.brand}|${row.model}`)).size;
      const expectedModels = Number(parsed.modelsProcessed || 0);
      const hasReasonableCoverage = !expectedModels || representedModels >= Math.ceil(expectedModels * 0.8);
      if (Array.isArray(parsed.repairRows) && !hasRateLimitPage && hasReasonableCoverage) return parsed;
    } catch {
      // Ignore a damaged history entry and continue to an older successful run.
    }
  }
  return null;
}

async function loadLatestSavedRun(historyDir) {
  const files = (await fs.readdir(historyDir).catch(() => []))
    .filter((name) => name.endsWith('.json') && !name.endsWith('-failed.json'))
    .sort()
    .reverse();
  for (const fileName of files) {
    try {
      const filePath = path.join(historyDir, fileName);
      const parsed = JSON.parse(await fs.readFile(filePath, 'utf8'));
      if (Array.isArray(parsed.sourceRows)) return { filePath, parsed };
    } catch {
      // Ignore a damaged history entry and continue.
    }
  }
  return null;
}

function modelsFromSourceRows(sourceRows) {
  const models = new Map();
  for (const row of sourceRows) {
    const key = `${row.brand}|${row.family}|${row.model}|${row.modelUrl}`;
    if (!models.has(key)) {
      models.set(key, {
        brand: row.brand,
        family: row.family,
        name: row.model,
        heading: row.model,
        href: row.modelUrl,
        products: [],
      });
    }
    models.get(key).products.push({
      category: row.category,
      name: row.name,
      price: row.price,
      sydStock: row.sydStock,
      melStock: row.melStock,
      available: row.available,
      url: row.url,
    });
  }
  return [...models.values()];
}

function applyPriceChangeChecks(summary, previousRun, config) {
  if (!previousRun?.repairRows?.length) return;
  const previousRows = new Map(previousRun.repairRows.map((row) => [
    `${row.brand}|${row.model}|${row.repairType}`,
    row,
  ]));

  for (const row of summary.repairRows) {
    const previous = previousRows.get(`${row.brand}|${row.model}|${row.repairType}`);
    if (!previous) continue;
    const minChange = previous.minPartPrice > 0
      ? Math.abs(row.minPartPrice - previous.minPartPrice) / previous.minPartPrice * 100
      : 0;
    const maxChange = previous.maxPartPrice > 0
      ? Math.abs(row.maxPartPrice - previous.maxPartPrice) / previous.maxPartPrice * 100
      : 0;
    const largestChange = Math.max(minChange, maxChange);
    if (largestChange > config.maxPriceChangePercent) {
      row.status = 'REVIEW';
      summary.exceptions.push({
        brand: row.brand,
        model: row.model,
        repairType: row.repairType,
        issue: 'Large price change',
        details: `Maximum part-price movement was ${largestChange.toFixed(1)}% versus the previous successful run`,
        url: row.minUrl,
      });
    }
  }
}

function columnName(number) {
  let value = number;
  let result = '';
  while (value > 0) {
    value -= 1;
    result = String.fromCharCode(65 + (value % 26)) + result;
    value = Math.floor(value / 26);
  }
  return result;
}

function setWidths(sheet, lastRow, widths) {
  widths.forEach((width, index) => {
    const column = columnName(index + 1);
    sheet.getRange(`${column}1:${column}${lastRow}`).format.columnWidth = width;
  });
}

function safeWorkbookValue(value) {
  if (typeof value !== 'string') return value;
  return value
    .replace(/\u001B\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/g, '');
}

function safeWorkbookRows(rows) {
  return rows.map((row) => row.map(safeWorkbookValue));
}

async function buildWorkbook(data, config, workbookPath, previewDir) {
  const capturedDisplay = data.capturedAt.replace('T', ' ').replace('+10:00', ' Brisbane');
  const workbook = Workbook.create();
  const prices = workbook.worksheets.add('Repair Prices');
  const source = workbook.worksheets.add('Source Products');
  const exceptions = workbook.worksheets.add('Exceptions');
  const settings = workbook.worksheets.add('Settings');

  for (const sheet of [prices, source, exceptions, settings]) sheet.showGridLines = false;

  settings.getRange('A1:B8').values = safeWorkbookRows([
    ['Setting', 'Value'],
    ['GST rate', config.gstRate],
    ['Labour charge', config.labourCharge],
    ['Round up increment', config.roundingIncrement],
    ['Member tier', config.expectedMemberTier],
    ['Captured at', capturedDisplay],
    ['Scope', data.scope],
    ['Source', config.baseUrl],
  ]);
  settings.getRange('A1:B1').format = { fill: '#123B5D', font: { bold: true, color: '#FFFFFF' } };
  settings.getRange('B2').format.numberFormat = '0%';
  settings.getRange('B3:B4').format.numberFormat = '"$"#,##0.00';
  setWidths(settings, 8, [24, 72]);
  settings.freezePanes.freezeRows(1);
  const settingsTable = settings.tables.add('A1:B8', true, 'SettingsTable');
  settingsTable.style = 'TableStyleMedium2';

  const priceHeaders = [
    'Brand', 'Family', 'Model', 'Repair Type', 'Min Part ex GST', 'Max Part ex GST',
    'Min Repair Price', 'Max Repair Price', 'Options', 'Stock', 'Status', 'Updated',
  ];
  prices.getRange('A1:L1').merge();
  prices.getRange('A1').values = [['TECHM8 Crazy Parts Repair Price List']];
  prices.getRange('A1:L1').format = {
    fill: '#123B5D',
    font: { bold: true, color: '#FFFFFF', size: 18 },
    rowHeight: 30,
  };
  prices.getRange('A2:L2').merge();
  prices.getRange('A2').values = [[`Formula: round up to nearest $${config.roundingIncrement} after part price + GST + $${config.labourCharge} labour. Cameras use the lowest and highest eligible camera modules.`]];
  prices.getRange('A2:L2').format = { fill: '#EAF2F8', font: { color: '#234E6F' }, wrapText: true, rowHeight: 34 };
  prices.getRange('A4:L4').merge();
  prices.getRange('A4').values = [[
    `Updated: ${capturedDisplay}   |   Models processed: ${data.modelsProcessed}   |   Repair prices: ${data.repairRows.length}   |   Exceptions: ${data.exceptions.length}`,
  ]];
  prices.getRange('A4:L4').format = { fill: '#DCEAF4', font: { bold: true, color: '#123B5D' } };
  prices.getRange('A6:L6').values = [priceHeaders];

  const priceStartRow = 7;
  if (data.repairRows.length) {
    const values = safeWorkbookRows(data.repairRows.map((row) => [
      row.brand, row.family, row.model, row.repairType, row.minPartPrice, row.maxPartPrice,
      null, null, row.optionCount, row.stockSummary, row.status,
      capturedDisplay,
    ]));
    const priceEndRow = priceStartRow + values.length - 1;
    prices.getRange(`A${priceStartRow}:L${priceEndRow}`).values = values;
    prices.getRange(`G${priceStartRow}`).formulas = [[`=ROUNDUP((E${priceStartRow}*(1+'Settings'!$B$2)+'Settings'!$B$3)/'Settings'!$B$4,0)*'Settings'!$B$4`]];
    prices.getRange(`G${priceStartRow}:G${priceEndRow}`).fillDown();
    prices.getRange(`H${priceStartRow}`).formulas = [[`=ROUNDUP((F${priceStartRow}*(1+'Settings'!$B$2)+'Settings'!$B$3)/'Settings'!$B$4,0)*'Settings'!$B$4`]];
    prices.getRange(`H${priceStartRow}:H${priceEndRow}`).fillDown();
    prices.getRange(`E${priceStartRow}:F${priceEndRow}`).format.numberFormat = '"$"#,##0.00';
    prices.getRange(`G${priceStartRow}:H${priceEndRow}`).format.numberFormat = '"$"#,##0';
    prices.getRange(`I${priceStartRow}:I${priceEndRow}`).format.numberFormat = '#,##0';
    prices.getRange(`A6:L${priceEndRow}`).format.wrapText = true;
    prices.freezePanes.freezeRows(6);
    prices.freezePanes.freezeColumns(4);
    const priceTable = prices.tables.add(`A6:L${priceEndRow}`, true, 'RepairPricesTable');
    priceTable.style = 'TableStyleMedium2';
    prices.getRange(`J${priceStartRow}:K${priceEndRow}`).conditionalFormats.add('containsText', {
      text: 'Low',
      format: { fill: '#FFF2CC', font: { color: '#7A5200' } },
    });
    prices.getRange(`K${priceStartRow}:K${priceEndRow}`).conditionalFormats.add('containsText', {
      text: 'REVIEW',
      format: { fill: '#FCE8E6', font: { bold: true, color: '#B3261E' } },
    });
    setWidths(prices, priceEndRow, [13, 18, 29, 18, 16, 16, 17, 17, 11, 18, 12, 27]);
  } else {
    prices.getRange('A7:L7').merge();
    prices.getRange('A7').values = [['No eligible repair prices were produced. Check the Exceptions sheet.']];
    setWidths(prices, 7, [13, 18, 29, 18, 16, 16, 17, 17, 11, 18, 12, 27]);
  }

  const sourceHeaders = ['Brand', 'Family', 'Model', 'Repair Type', 'Product', 'Member Price ex GST', 'Sydney Stock', 'Melbourne Stock', 'Eligible', 'Product URL', 'Captured'];
  source.getRange('A1:K1').values = [sourceHeaders];
  const sourceRows = data.sourceRows.length ? safeWorkbookRows(data.sourceRows.map((row) => [
    row.brand, row.family, row.model, row.repairType, row.name, row.price,
    row.sydStock, row.melStock, row.available ? 'Yes' : 'No', row.url, capturedDisplay,
  ])) : [['', '', '', '', 'No matching source products', null, '', '', '', config.baseUrl, capturedDisplay]];
  source.getRange(`A2:K${sourceRows.length + 1}`).values = sourceRows;
  source.getRange(`F2:F${sourceRows.length + 1}`).format.numberFormat = '"$"#,##0.00';
  source.getRange(`A1:K${sourceRows.length + 1}`).format.wrapText = true;
  const sourceTable = source.tables.add(`A1:K${sourceRows.length + 1}`, true, 'SourceProductsTable');
  sourceTable.style = 'TableStyleMedium2';
  source.freezePanes.freezeRows(1);
  setWidths(source, sourceRows.length + 1, [13, 18, 29, 18, 55, 19, 16, 18, 12, 42, 23]);

  const exceptionHeaders = ['Brand', 'Model', 'Repair Type', 'Issue', 'Details', 'Model URL'];
  exceptions.getRange('A1:F1').values = [exceptionHeaders];
  const exceptionRows = data.exceptions.length ? safeWorkbookRows(data.exceptions.map((row) => [
    row.brand || '', row.model || '', row.repairType || '', row.issue, row.details || '', row.url || '',
  ])) : [['', '', '', 'No exceptions', '', '']];
  exceptions.getRange(`A2:F${exceptionRows.length + 1}`).values = exceptionRows;
  exceptions.getRange(`A1:F${exceptionRows.length + 1}`).format.wrapText = true;
  const exceptionTable = exceptions.tables.add(`A1:F${exceptionRows.length + 1}`, true, 'ExceptionsTable');
  exceptionTable.style = 'TableStyleMedium3';
  exceptions.freezePanes.freezeRows(1);
  setWidths(exceptions, exceptionRows.length + 1, [13, 31, 18, 32, 42, 45]);

  await fs.mkdir(previewDir, { recursive: true });
  const previewSpecs = [
    ['Repair Prices', 'A1:L16', 'repair-prices.png'],
    ['Source Products', `A1:K${Math.min(sourceRows.length + 1, 14)}`, 'source-products.png'],
    ['Exceptions', `A1:F${Math.min(exceptionRows.length + 1, 14)}`, 'exceptions.png'],
    ['Settings', 'A1:B8', 'settings.png'],
  ];
  for (const [sheetName, range, fileName] of previewSpecs) {
    const preview = await workbook.render({ sheetName, range, scale: 1.2, format: 'png' });
    await fs.writeFile(path.join(previewDir, fileName), new Uint8Array(await preview.arrayBuffer()));
  }

  const inspect = await workbook.inspect({
    kind: 'table',
    range: 'Repair Prices!A1:L16',
    include: 'values,formulas',
    tableMaxRows: 16,
    tableMaxCols: 12,
    maxChars: 8000,
  });
  const errors = await workbook.inspect({
    kind: 'match',
    searchTerm: '#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A',
    options: { useRegex: true, maxResults: 100 },
    summary: 'final formula error scan',
  });
  if (/#REF!|#DIV\/0!|#VALUE!|#NAME\?|#N\/A/.test(errors.ndjson || '')) {
    throw new Error(`Workbook formula verification failed: ${errors.ndjson}`);
  }

  console.log(inspect.ndjson);
  const temporaryPath = `${workbookPath}.tmp.xlsx`;
  await fs.rm(temporaryPath, { force: true }).catch(() => {});
  const output = await SpreadsheetFile.exportXlsx(workbook);
  await output.save(temporaryPath);
  try {
    await fs.rm(workbookPath, { force: true });
    await fs.rename(temporaryPath, workbookPath);
    return workbookPath;
  } catch (error) {
    if (!['EBUSY', 'EPERM', 'EACCES'].includes(error.code)) throw error;
    const extension = path.extname(workbookPath);
    const runDirectory = path.basename(path.dirname(previewDir));
    const pendingPath = `${workbookPath.slice(0, -extension.length)}_PENDING_${runDirectory}${extension}`;
    await fs.rm(pendingPath, { force: true }).catch(() => {});
    await fs.rename(temporaryPath, pendingPath);
    console.warn(`The current workbook is open or locked. The new workbook was saved as: ${pendingPath}`);
    return pendingPath;
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const trackedFamily = trackedFamilyFromArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }
  if (!args.all && !args.families.length && !args.models.length && !args.rebuildLatest && !args.listFamilies) {
    throw new Error('Choose --all, --family, or provide at least one --model. This safety check prevents accidental full-site runs.');
  }

  const config = JSON.parse(await fs.readFile(configPath, 'utf8'));
  const capturedAt = brisbaneTimestamp();
  const runId = safeRunId(capturedAt);
  const outputDir = path.resolve(projectRoot, config.outputDir);
  const historyDir = path.join(outputDir, 'history');
  const previewDir = path.join(outputDir, '.runtime', runId, 'previews');
  const workbookPath = path.join(outputDir, 'TECHM8_CrazyParts_Repair_Prices.xlsx');
  await fs.mkdir(historyDir, { recursive: true });

  if (args.rebuildLatest) {
    const latest = await loadLatestSavedRun(historyDir);
    if (!latest) throw new Error('No saved raw run is available to rebuild.');
    const summary = summariseModels(modelsFromSourceRows(latest.parsed.sourceRows), latest.parsed.capturedAt);
    const retainedExceptions = (latest.parsed.exceptions || []).filter((item) => (
      item.issue !== 'Large price change' && item.issue !== 'All matching parts are out of stock'
    ));
    const rebuilt = {
      ...latest.parsed,
      repairRows: summary.repairRows,
      sourceRows: summary.sourceRows,
      exceptions: [...summary.exceptions, ...retainedExceptions],
    };
    await fs.writeFile(latest.filePath, JSON.stringify(rebuilt, null, 2));
    const savedWorkbookPath = await buildWorkbook(rebuilt, config, workbookPath, previewDir);
    console.log(`Workbook rebuilt: ${savedWorkbookPath}`);
    console.log(`Raw run history updated: ${latest.filePath}`);
    return;
  }

  const email = process.env.CRAZYPARTS_EMAIL;
  const password = process.env.CRAZYPARTS_PASSWORD;
  if (!email || !password) {
    throw new Error('Crazy Parts credentials are not available. Use run-crazyparts-price-monitor.ps1.');
  }

  if (trackedFamily) {
    reportCrazyPartsStatus(trackedFamily, {
      status: 'running',
      totalModels: 0,
      processedModels: 0,
      eligibleModels: 0,
      repairRows: 0,
      progressPercent: 0,
      message: 'Logging in and discovering Crazy Parts model pages.',
      startedNow: true,
    });
  }

  const browser = await launchBrowser(config, args.headful);
  const failures = [];
  let selectedModels = [];
  const scrapedModels = [];

  try {
    const context = await browser.newContext({
      viewport: { width: 1440, height: 1000 },
      locale: 'en-AU',
      timezoneId: 'Australia/Brisbane',
    });
    const page = await context.newPage();
    await login(page, config, email, password);
    console.log(`Logged in with ${config.expectedMemberTier} member pricing.`);

    const discovered = await discoverModels(page, config);
    if (args.listFamilies) {
      const familyCounts = new Map();
      for (const model of discovered) {
        const key = `${model.brand}|${model.family}`;
        familyCounts.set(key, (familyCounts.get(key) || 0) + 1);
      }
      console.log('Available Crazy Parts model families:');
      for (const [key, count] of [...familyCounts].sort(([left], [right]) => left.localeCompare(right))) {
        const [brand, family] = key.split('|');
        console.log(`${brand}\t${family}\t${count}`);
      }
      await context.close();
      return;
    }
    const discoveredByHref = new Map(discovered.map((model) => [model.href, model]));
    if (args.all) {
      selectedModels = discovered.filter(isEligibleRepairModel);
    } else {
      const familyNames = new Set(args.families.map((value) => String(value || '').trim().toLowerCase()));
      const familyModels = discovered.filter((model) => (
        familyNames.has(model.family.toLowerCase()) && isEligibleRepairModel(model)
      ));
      const manualModels = args.models.map((value) => {
        const href = normaliseModelHref(value);
        return discoveredByHref.get(href) || {
          brand: 'Unknown', family: 'Manual', name: cleanMenuText(value), href,
        };
      });
      selectedModels = [...new Map([...familyModels, ...manualModels].map((model) => [model.href, model])).values()];
      for (const familyName of args.families) {
        if (!familyModels.some((model) => model.family.toLowerCase() === String(familyName).trim().toLowerCase())) {
          throw new Error(`No models were discovered for family: ${familyName}`);
        }
      }
    }
    if (args.maxModels > 0) selectedModels = selectedModels.slice(0, args.maxModels);
    console.log(`Selected ${selectedModels.length} model page(s).`);
    if (trackedFamily) {
      reportCrazyPartsStatus(trackedFamily, {
        status: 'running',
        totalModels: selectedModels.length,
        processedModels: 0,
        progressPercent: 0,
        message: `Reading 0 of ${selectedModels.length} model pages.`,
      });
    }

    let nextIndex = 0;
    let completed = 0;
    let fatalError = null;
    const concurrency = Math.max(1, Math.min(8, Math.floor(args.concurrency || 1), selectedModels.length || 1));
    console.log(`Using ${concurrency} concurrent model page worker(s).`);
    const workers = Array.from({ length: concurrency }, async (_, workerIndex) => {
      const workerPage = workerIndex === 0 ? page : await context.newPage();
      while (true) {
        if (fatalError) break;
        const index = nextIndex;
        nextIndex += 1;
        if (index >= selectedModels.length) break;
        const model = selectedModels[index];
        try {
          let result;
          const rateLimitAttempts = Math.max(1, config.rateLimitRetryAttempts || 1);
          for (let attempt = 1; attempt <= rateLimitAttempts; attempt += 1) {
            try {
              result = await scrapeModel(workerPage, model, config);
              break;
            } catch (error) {
              if (error.code !== 'CRAZYPARTS_RATE_LIMIT' || attempt === rateLimitAttempts) throw error;
              const waitMs = Math.min(config.rateLimitBackoffMs * (2 ** (attempt - 1)), 300000);
              console.warn(`Crazy Parts rate limit reached. Waiting ${Math.round(waitMs / 1000)} seconds before retry ${attempt + 1}/${rateLimitAttempts}.`);
              await sleep(waitMs);
            }
          }
          scrapedModels.push(result);
          completed += 1;
          console.log(`[${completed}/${selectedModels.length}] ${result.heading}: ${result.products.length} products read`);
          if (trackedFamily && (completed === selectedModels.length || completed % 5 === 0)) {
            reportCrazyPartsStatus(trackedFamily, {
              status: 'running',
              totalModels: selectedModels.length,
              processedModels: completed,
              progressPercent: Math.min(94, Math.round((completed / selectedModels.length) * 94)),
              message: `Reading model pages: ${completed} of ${selectedModels.length}.`,
            });
          }
        } catch (error) {
          if (error.code === 'CRAZYPARTS_RATE_LIMIT') {
            fatalError = error;
            console.error(`Stopping this run because Crazy Parts is still rate limiting requests.`);
            break;
          }
          failures.push({
            brand: model.brand,
            model: model.name,
            repairType: '',
            issue: 'Model page failed',
            details: error.message,
            url: new URL(model.href, config.baseUrl).toString(),
          });
          completed += 1;
          console.error(`[${completed}/${selectedModels.length}] ${model.name}: ${error.message}`);
          if (trackedFamily && (completed === selectedModels.length || completed % 5 === 0)) {
            reportCrazyPartsStatus(trackedFamily, {
              status: 'running',
              totalModels: selectedModels.length,
              processedModels: completed,
              progressPercent: Math.min(94, Math.round((completed / selectedModels.length) * 94)),
              message: `Reading model pages: ${completed} of ${selectedModels.length}; ${failures.length} failed.`,
            });
          }
        }
        if (nextIndex < selectedModels.length) await sleep(config.pageDelayMs);
      }
      if (workerIndex !== 0) await workerPage.close();
    });
    await Promise.all(workers);
    if (fatalError) throw fatalError;

    await context.close();
  } finally {
    await browser.close();
  }

  const failureRate = selectedModels.length ? (failures.length / selectedModels.length) * 100 : 100;
  if (failureRate > config.maxFailureRatePercent) {
    const failedRunPath = path.join(historyDir, `${runId}-failed.json`);
    await fs.writeFile(failedRunPath, JSON.stringify({ capturedAt, selectedModels, failures }, null, 2));
    throw new Error(`Failure rate ${failureRate.toFixed(1)}% exceeded the ${config.maxFailureRatePercent}% safety limit. The current workbook was not replaced.`);
  }

  const summary = summariseModels(scrapedModels, capturedAt);
  summary.exceptions.push(...failures);
  const previousRun = await loadPreviousSuccessfulRun(historyDir);
  applyPriceChangeChecks(summary, previousRun, config);
  const scope = args.all
    ? 'All discovered models'
    : [...args.families.map((value) => `Family: ${value}`), ...args.models.map((value) => `Model: ${value}`)].join(', ');
  const rawData = {
    capturedAt,
    scope,
    selectionComplete: args.maxModels === 0 && args.models.length === 0,
    requestedFamilies: args.families,
    modelsSelected: selectedModels.length,
    modelsProcessed: scrapedModels.length,
    repairRows: summary.repairRows,
    sourceRows: summary.sourceRows,
    exceptions: summary.exceptions,
  };
  const historyPath = path.join(historyDir, `${runId}.json`);
  await fs.writeFile(historyPath, JSON.stringify(rawData, null, 2));

  if (trackedFamily) {
    reportCrazyPartsStatus(trackedFamily, {
      status: 'syncing',
      totalModels: selectedModels.length,
      processedModels: selectedModels.length,
      eligibleModels: new Set(summary.repairRows.map((row) => row.model)).size,
      repairRows: summary.repairRows.length,
      progressPercent: 95,
      message: 'Supplier prices captured. Updating and verifying the Admin price list.',
    });
  }

  const savedWorkbookPath = await buildWorkbook(rawData, config, workbookPath, previewDir);
  console.log(`Workbook updated: ${savedWorkbookPath}`);
  console.log(`Raw run history: ${historyPath}`);
}

main().catch((error) => {
  const trackedFamily = trackedFamilyFromArgs(process.argv.slice(2));
  if (trackedFamily) {
    reportCrazyPartsStatus(trackedFamily, {
      status: error.code === 'CRAZYPARTS_RATE_LIMIT' ? 'rate_limited' : 'failed',
      message: error.code === 'CRAZYPARTS_RATE_LIMIT'
        ? 'Crazy Parts rate limit is active. The existing Admin prices were kept.'
        : `Update failed: ${error.message}`,
    });
  }
  console.error(`Crazy Parts price monitor failed: ${error.message}`);
  process.exitCode = 1;
});
