import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputDir = path.join(projectRoot, 'outputs', 'crazyparts-price-monitor');
const historyDir = path.join(outputDir, 'history');
const backupDir = path.join(outputDir, 'supabase-backups');

const familyConfig = new Map([
  ['a series', { dbBrand: 'Samsung A Series', displayBrand: 'Samsung', mode: 'samsung' }],
  ['oppo', { dbBrand: 'OPPO', displayBrand: 'OPPO', mode: 'replace' }],
  ['huawei', { dbBrand: 'HUAWEI', displayBrand: 'Huawei', mode: 'replace' }],
  ['xiaomi', { dbBrand: 'XIAOMI', displayBrand: 'Xiaomi', mode: 'replace' }],
  ['redmi', { dbBrand: 'REDMI', displayBrand: 'Redmi', mode: 'replace' }],
  ['motorola', { dbBrand: 'MOTOROLA', displayBrand: 'Motorola', mode: 'replace' }],
  ['nokia', { dbBrand: 'NOKIA', displayBrand: 'Nokia', mode: 'replace' }],
  ['oneplus', { dbBrand: 'ONEPLUS', displayBrand: 'OnePlus', mode: 'replace' }],
  ['realme', { dbBrand: 'REALME', displayBrand: 'Realme', mode: 'replace' }],
  ['vivo', { dbBrand: 'VIVO', displayBrand: 'Vivo', mode: 'replace' }],
  ['sony', { dbBrand: 'SONY', displayBrand: 'Sony', mode: 'replace' }],
]);

function parseArgs(argv) {
  return {
    apply: argv.includes('--apply'),
    history: argv.includes('--history') ? argv[argv.indexOf('--history') + 1] : '',
  };
}

function priceForPart(partPrice) {
  return Math.ceil(((Number(partPrice) * 1.10) + 110) / 5) * 5;
}

function cleanModel(value) {
  return String(value || '')
    .replace(/^Samsung\s+(?:Galaxy\s+)?/i, '')
    .replace(/\([^)]*\)/g, ' ')
    .replace(/[^a-z0-9+]+/gi, ' ')
    .trim()
    .toLowerCase();
}

function describeModel(value) {
  const text = String(value || '');
  const plain = text.replace(/^Samsung\s+(?:Galaxy\s+)?/i, '');
  return {
    base: plain.match(/^\s*(A\d+(?:S|E|\+)?)/i)?.[1]?.toLowerCase() || '',
    codes: (text.match(/\bA\d{3,4}[A-Z]?\b/gi) || []).map((item) => item.toLowerCase()),
    network: /5g/i.test(text) ? '5g' : (/4g/i.test(text) ? '4g' : ''),
    clean: cleanModel(text),
    japanese: /japanese/i.test(text),
  };
}

function repairTypeForIssue(issue) {
  if (issue === 'Screen Replacement') return 'Screen';
  if (issue === 'Battery (ORIGINAL )') return 'Battery';
  if (issue === 'Charging Socket/Microphone') return 'Charging Port';
  if (issue === 'Front Camera' || issue === 'Rear Camera') return 'Camera';
  return null;
}

function issuesForRepairType(repairType) {
  if (repairType === 'Screen') return ['Screen Replacement'];
  if (repairType === 'Battery') return ['Battery (ORIGINAL )'];
  if (repairType === 'Charging Port') return ['Charging Socket/Microphone'];
  if (repairType === 'Camera') return ['Front Camera', 'Rear Camera'];
  return [];
}

function canonicalModelName(sourceModel, candidates) {
  let name = String(sourceModel || '')
    .replace(/^Samsung\s+Galaxy\s+/i, 'Samsung ')
    .replace(/\s*\(/g, ' (')
    .replace(/\)\s*/g, ') ')
    .replace(/\s+/g, ' ')
    .trim();
  name = name.replace(/\bA(\d+)(s|e)\b/gi, (_, number, suffix) => `A${number}${suffix.toUpperCase()}`);

  const description = describeModel(sourceModel);
  const has5gSibling = candidates.some((candidate) => (
    candidate.description.base === description.base && candidate.description.network === '5g'
  ));
  if (!description.network && has5gSibling) {
    name = name.replace(/\s+(\()/, ' 4G $1');
    if (!/\b4G\b/i.test(name)) name = `${name} 4G`;
  }
  return name;
}

function findSiteModelForCandidate(candidate, siteModels, candidates) {
  if (candidate.description.japanese) return null;
  const has5gSibling = candidates.some((other) => (
    other.description.base === candidate.description.base && other.description.network === '5g'
  ));
  const needsExplicit4g = !candidate.description.network && has5gSibling;
  let best = null;

  for (const siteModel of siteModels) {
    const site = describeModel(siteModel);
    if (!site.base || site.base !== candidate.description.base || site.japanese) continue;
    if (needsExplicit4g && site.network !== '4g') continue;
    if (candidate.description.network && site.network && site.network !== candidate.description.network) continue;
    if (candidate.description.codes.length && site.codes.length
      && !candidate.description.codes.some((code) => site.codes.includes(code))) continue;

    let score = 0;
    if (candidate.description.codes.some((code) => site.codes.includes(code))) score += 100;
    if (candidate.description.clean === site.clean) score += 60;
    if (needsExplicit4g && site.network === '4g') score += 35;
    else if (candidate.description.network === site.network) score += 30;
    else if (!candidate.description.network && !site.network) score += 20;
    else if (candidate.description.network && !site.network) score += 5;
    if (candidate.description.codes.length && !site.codes.length) score += 10;

    if (!best || score > best.score) best = { model: siteModel, score };
  }
  return best && best.score >= 20 ? best.model : null;
}

async function latestHistory(explicitPath) {
  if (explicitPath) return path.resolve(projectRoot, explicitPath);
  const files = (await fs.readdir(historyDir))
    .filter((name) => /^\d{8}-\d{6}\.json$/.test(name))
    .sort()
    .reverse();
  for (const name of files) {
    const filePath = path.join(historyDir, name);
    const parsed = JSON.parse(await fs.readFile(filePath, 'utf8'));
    const families = new Set([
      ...(parsed.repairRows || []).map((row) => String(row.family || '').toLowerCase()),
      ...(parsed.sourceRows || []).map((row) => String(row.family || '').toLowerCase()),
    ]);
    if ([...families].some((family) => familyConfig.has(family))) return filePath;
  }
  throw new Error('No supported Crazy Parts history file was found.');
}

async function supabaseConfig() {
  const source = await fs.readFile(path.join(projectRoot, 'supabase-config.js'), 'utf8');
  const url = source.match(/url:\s*'([^']+)'/)?.[1];
  const anonKey = source.match(/anonKey:\s*'([^']+)'/)?.[1];
  if (!url || !anonKey) throw new Error('Supabase public configuration is missing.');
  return { url, anonKey };
}

async function readSiteRows(config, brands) {
  const rows = [];
  const pageSize = 1000;
  for (const brand of brands) {
    for (let offset = 0; ; offset += pageSize) {
      const params = new URLSearchParams({
        select: 'brand,model,issue,price',
        brand: `eq.${brand}`,
        order: 'model.asc,issue.asc',
        limit: String(pageSize),
        offset: String(offset),
      });
      const response = await fetch(`${config.url}/rest/v1/repair_prices?${params}`, {
        headers: { apikey: config.anonKey, Authorization: `Bearer ${config.anonKey}` },
      });
      if (!response.ok) throw new Error(`Could not read ${brand} repair prices: ${await response.text()}`);
      const page = await response.json();
      rows.push(...page);
      if (page.length < pageSize) break;
    }
  }
  return rows;
}

function makePlan(rawData, siteRows) {
  const grouped = new Map();
  for (const row of rawData.repairRows || []) {
    if (!grouped.has(row.model)) grouped.set(row.model, []);
    grouped.get(row.model).push(row);
  }
  const candidates = [...grouped].map(([model, rows]) => ({
    model,
    rows,
    description: describeModel(model),
  }));

  const siteModels = [...new Set(siteRows.map((row) => row.model))];
  const siteRowMap = new Map(siteRows.map((row) => [`${row.model}|${row.issue}`, row]));
  const groupedTargets = new Map();
  const representedSiteModels = new Set();

  for (const candidate of candidates) {
    const existingModel = findSiteModelForCandidate(candidate, siteModels, candidates);
    const targetModel = existingModel || canonicalModelName(candidate.model, candidates);
    if (existingModel) representedSiteModels.add(existingModel);
    for (const source of candidate.rows) {
      const key = `${targetModel}|${source.repairType}`;
      if (!groupedTargets.has(key)) groupedTargets.set(key, { targetModel, repairType: source.repairType, sources: [] });
      groupedTargets.get(key).sources.push({ ...source, sourceModel: candidate.model });
    }
  }

  const updates = [];
  for (const group of groupedTargets.values()) {
    const minimum = priceForPart(Math.min(...group.sources.map((source) => source.minPartPrice)));
    const maximum = priceForPart(Math.max(...group.sources.map((source) => source.maxPartPrice)));
    const newPrice = minimum === maximum ? String(minimum) : `${minimum} - ${maximum}`;
    for (const issue of issuesForRepairType(group.repairType)) {
      const existing = siteRowMap.get(`${group.targetModel}|${issue}`);
      updates.push({
        brand: 'Samsung A Series',
        model: group.targetModel,
        issue,
        oldPrice: existing?.price ?? null,
        newPrice,
        sourceModel: [...new Set(group.sources.map((source) => source.sourceModel))].join(' / '),
        repairType: group.repairType,
      });
    }
  }

  const sourceBasesWithVariants = new Set(candidates
    .filter((candidate) => candidate.description.network === '5g')
    .map((candidate) => candidate.description.base)
    .filter((base) => candidates.some((candidate) => (
      candidate.description.base === base && !candidate.description.network
    ))));
  const desiredModels = [...new Set(updates.map((row) => row.model))];
  const desiredDescriptions = desiredModels.map((model) => ({
    model,
    description: describeModel(model),
  }));
  const obsoleteModels = siteModels.filter((model) => {
    const description = describeModel(model);
    const obsoleteGeneric = sourceBasesWithVariants.has(description.base)
      && !description.network
      && !description.codes.length
      && !representedSiteModels.has(model);
    if (obsoleteGeneric) return true;

    const obsoleteAlias = !representedSiteModels.has(model)
      && desiredDescriptions.some((target) => {
        if (target.model === model || target.description.base !== description.base) return false;
        if (target.description.japanese !== description.japanese) return false;
        if (target.description.network === description.network) return true;
        const networks = new Set([target.description.network, description.network]);
        return !sourceBasesWithVariants.has(description.base)
          && networks.has('')
          && networks.has('4g');
      });
    return obsoleteAlias;
  });
  const desiredKeys = new Set(updates.map((row) => `${row.model}|${row.issue}`));
  const unmatched = siteRows
    .filter((row) => repairTypeForIssue(row.issue)
      && !desiredKeys.has(`${row.model}|${row.issue}`)
      && !obsoleteModels.includes(row.model))
    .map((row) => ({ model: row.model, issue: row.issue }));
  return { updates, unmatched, obsoleteModels, supplierModels: candidates.length };
}

function canonicalOtherModelName(sourceModel, displayBrand) {
  let model = String(sourceModel || '')
    .replace(/\s*\(/g, ' (')
    .replace(/\)\s*/g, ') ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!model) return '';

  const escapedBrand = displayBrand.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const prefix = new RegExp(`^${escapedBrand}\\b`, 'i');
  if (prefix.test(model)) return model.replace(prefix, displayBrand).trim();
  return `${displayBrand} ${model}`;
}

function makeReplacementPlan(rawData, siteRows, configs) {
  if (rawData.selectionComplete === false) {
    throw new Error('Destructive brand replacement refused: the source run used a model limit or manual model selection.');
  }
  if (Number(rawData.modelsProcessed) !== Number(rawData.modelsSelected)) {
    throw new Error(`Destructive brand replacement refused: ${rawData.modelsProcessed || 0}/${rawData.modelsSelected || 0} model pages completed.`);
  }
  const pageFailures = (rawData.exceptions || []).filter((item) => item.issue === 'Model page failed');
  if (pageFailures.length) {
    throw new Error(`Destructive brand replacement refused: ${pageFailures.length} model page(s) failed.`);
  }

  const byFamily = new Map(configs.map((config) => [config.family, config]));
  const groups = new Map();
  for (const row of rawData.repairRows || []) {
    const config = byFamily.get(String(row.family || '').toLowerCase());
    if (!config) continue;
    const model = canonicalOtherModelName(row.model, config.displayBrand);
    if (!model || !issuesForRepairType(row.repairType).length) continue;
    const key = `${config.dbBrand}|${model}|${row.repairType}`;
    if (!groups.has(key)) groups.set(key, {
      brand: config.dbBrand,
      model,
      repairType: row.repairType,
      sources: [],
    });
    groups.get(key).sources.push(row);
  }

  const siteMap = new Map(siteRows.map((row) => [`${row.brand}|${row.model}|${row.issue}`, row]));
  const updates = [];
  for (const group of groups.values()) {
    const minimum = priceForPart(Math.min(...group.sources.map((source) => source.minPartPrice)));
    const maximum = priceForPart(Math.max(...group.sources.map((source) => source.maxPartPrice)));
    const newPrice = minimum === maximum ? String(minimum) : `${minimum} - ${maximum}`;
    for (const issue of issuesForRepairType(group.repairType)) {
      const existing = siteMap.get(`${group.brand}|${group.model}|${issue}`);
      updates.push({
        brand: group.brand,
        model: group.model,
        issue,
        oldPrice: existing?.price ?? null,
        newPrice,
        sourceModel: [...new Set(group.sources.map((source) => source.model))].join(' / '),
        repairType: group.repairType,
      });
    }
  }

  const replaceBrands = configs.map((config) => config.dbBrand);
  for (const brand of replaceBrands) {
    if (!updates.some((row) => row.brand === brand)) {
      throw new Error(`Destructive brand replacement refused: ${brand} produced no eligible repair prices.`);
    }
  }
  return {
    updates,
    unmatched: [],
    obsoleteModels: [],
    replaceBrands,
    supplierModels: new Set(updates.map((row) => `${row.brand}|${row.model}`)).size,
  };
}

function configsInHistory(rawData) {
  const families = new Set([
    ...(rawData.repairRows || []).map((row) => String(row.family || '').toLowerCase()),
    ...(rawData.sourceRows || []).map((row) => String(row.family || '').toLowerCase()),
  ]);
  return [...families]
    .map((family) => ({ family, ...familyConfig.get(family) }))
    .filter((config) => config.dbBrand);
}

function sqlForUpdates(plan) {
  const payload = JSON.stringify(plan.updates.map((item) => ({
    brand: item.brand,
    model: item.model,
    issue: item.issue,
    new_price: item.newPrice,
  })));
  const obsoletePayload = JSON.stringify(plan.obsoleteModels);
  const replacementPayload = JSON.stringify(plan.replaceBrands || []);
  return `begin;
delete from public.repair_prices
where brand in (
  select value from jsonb_array_elements_text($techm8_replace$${replacementPayload}$techm8_replace$::jsonb)
);
with incoming as (
  select *
  from jsonb_to_recordset($techm8_sync$${payload}$techm8_sync$::jsonb)
    as row_data(brand text, model text, issue text, new_price text)
)
insert into public.repair_prices (brand, model, issue, price)
select brand, model, issue, new_price from incoming
on conflict (brand, model, issue) do update
set price = excluded.price,
    updated_at = now();
delete from public.repair_prices
where brand = 'Samsung A Series'
  and model in (
    select value from jsonb_array_elements_text($techm8_obsolete$${obsoletePayload}$techm8_obsolete$::jsonb)
  );
commit;`;
}

async function applyPlan(plan, stamp) {
  const sqlPath = path.join(outputDir, `.supabase-price-sync-${stamp}.sql`);
  await fs.writeFile(sqlPath, sqlForUpdates(plan), 'utf8');
  try {
    const executable = process.platform === 'win32' ? 'supabase.exe' : 'supabase';
    const result = spawnSync(executable, ['db', 'query', '--linked', '--file', sqlPath, '--output', 'json'], {
      cwd: projectRoot,
      encoding: 'utf8',
      windowsHide: true,
    });
    if (result.status !== 0) throw new Error(result.stderr || result.stdout || 'Supabase update failed.');
  } finally {
    await fs.rm(sqlPath, { force: true });
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const historyPath = await latestHistory(args.history);
  const rawData = JSON.parse(await fs.readFile(historyPath, 'utf8'));
  const configs = configsInHistory(rawData);
  if (!configs.length) throw new Error('The selected history does not contain a supported model family.');
  const affectedBrands = [...new Set(configs.map((config) => config.dbBrand))];
  const config = await supabaseConfig();
  const beforeRows = await readSiteRows(config, affectedBrands);
  const samsungConfig = configs.find((item) => item.mode === 'samsung');
  const replacementConfigs = configs.filter((item) => item.mode === 'replace');
  const samsungPlan = samsungConfig
    ? makePlan({
      ...rawData,
      repairRows: (rawData.repairRows || []).filter((row) => String(row.family || '').toLowerCase() === samsungConfig.family),
    }, beforeRows.filter((row) => row.brand === samsungConfig.dbBrand))
    : null;
  const replacementPlan = replacementConfigs.length
    ? makeReplacementPlan(rawData, beforeRows, replacementConfigs)
    : null;
  const plan = {
    updates: [...(samsungPlan?.updates || []), ...(replacementPlan?.updates || [])],
    unmatched: samsungPlan?.unmatched || [],
    obsoleteModels: samsungPlan?.obsoleteModels || [],
    replaceBrands: replacementPlan?.replaceBrands || [],
    supplierModels: (samsungPlan?.supplierModels || 0) + (replacementPlan?.supplierModels || 0),
  };
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+/, '').replace('T', '-');

  const newRows = plan.updates.filter((item) => item.oldPrice === null).length;
  const targetModels = new Set(plan.updates.map((item) => item.model)).size;
  console.log(`Prepared ${plan.updates.length} Admin price row(s) across ${targetModels} Admin model(s) for ${affectedBrands.join(', ')}: ${newRows} new row(s), ${plan.unmatched.length} unmatched existing row(s).`);
  if (plan.replaceBrands.length) console.log(`Full brand replacement: ${plan.replaceBrands.join(', ')}`);
  const newModels = [...new Set(plan.updates.filter((item) => item.oldPrice === null).map((item) => item.model))];
  if (newModels.length) console.log(`New/expanded models: ${newModels.join(', ')}`);
  if (plan.obsoleteModels.length) console.log(`Obsolete generic/duplicate models to remove: ${plan.obsoleteModels.join(', ')}`);
  if (plan.unmatched.length) {
    const unmatchedRows = plan.unmatched.map((item) => `${item.model} / ${item.issue}`);
    console.log(`Existing rows without eligible supplier data (kept unchanged): ${unmatchedRows.join('; ')}`);
  }
  if (!args.apply) {
    console.log('Preview only. Add --apply to update Supabase.');
    return;
  }

  await fs.mkdir(backupDir, { recursive: true });
  const backupPath = path.join(backupDir, `${stamp}-before-sync.json`);
  await fs.writeFile(backupPath, JSON.stringify({ historyPath, rows: beforeRows, plan }, null, 2));
  await applyPlan(plan, stamp);

  const afterRows = await readSiteRows(config, affectedBrands);
  const afterMap = new Map(afterRows.map((row) => [`${row.brand}|${row.model}|${row.issue}`, row.price]));
  const failed = plan.updates.filter((item) => (
    afterMap.get(`${item.brand}|${item.model}|${item.issue}`) !== item.newPrice
  ));
  if (failed.length) throw new Error(`${failed.length} price row(s) failed verification.`);
  const obsoleteRemaining = afterRows.filter((row) => plan.obsoleteModels.includes(row.model));
  if (obsoleteRemaining.length) throw new Error(`${obsoleteRemaining.length} obsolete generic row(s) failed deletion verification.`);
  for (const brand of plan.replaceBrands) {
    const expected = plan.updates.filter((row) => row.brand === brand);
    const expectedKeys = new Set(expected.map((row) => `${row.model}|${row.issue}`));
    const actual = afterRows.filter((row) => row.brand === brand);
    const unexpected = actual.filter((row) => !expectedKeys.has(`${row.model}|${row.issue}`));
    if (actual.length !== expected.length || unexpected.length) {
      throw new Error(`${brand} replacement verification failed: expected ${expected.length} rows, found ${actual.length}.`);
    }
  }

  const changed = plan.updates.filter((item) => item.oldPrice !== item.newPrice).length;
  const inserted = plan.updates.filter((item) => plan.replaceBrands.includes(item.brand) || item.oldPrice === null).length;
  console.log(`Supabase price sync verified: ${plan.updates.length} rows checked, ${changed} changed, ${inserted} inserted/replaced.`);
  console.log(`Pre-sync backup: ${backupPath}`);
}

main().catch((error) => {
  console.error(`Crazy Parts Supabase sync failed: ${error.message}`);
  process.exitCode = 1;
});
