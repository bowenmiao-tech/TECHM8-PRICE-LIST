import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputDir = path.join(projectRoot, 'outputs', 'crazyparts-price-monitor');
const historyDir = path.join(outputDir, 'history');
const backupDir = path.join(outputDir, 'supabase-backups');

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
    base: plain.match(/^\s*(A\d+(?:S|\+)?)/i)?.[1]?.toLowerCase() || '',
    codes: (text.match(/\bA\d{2,4}[A-Z]?\b/gi) || []).map((item) => item.toLowerCase()),
    network: /5g/i.test(text) ? '5g' : (/4g/i.test(text) ? '4g' : ''),
    clean: cleanModel(text),
    japanese: /japanese/i.test(text),
  };
}

function findBestModel(siteModel, candidates) {
  const site = describeModel(siteModel);
  let best = null;
  for (const candidate of candidates) {
    if (!site.base || candidate.description.base !== site.base) continue;
    let score = 0;
    if (site.codes.some((code) => candidate.description.codes.includes(code))) score += 100;
    if (site.clean === candidate.description.clean) score += 60;
    if (site.network) {
      score += candidate.description.network === site.network
        ? 35
        : (candidate.description.network ? -40 : 10);
    } else {
      score += candidate.description.network ? 0 : 25;
      if (site.base === 'a17' && candidate.description.network === '5g') score += 30;
    }
    if (candidate.description.japanese && !/japanese/i.test(siteModel)) score -= 80;
    if (!best || score > best.score) best = { candidate, score };
  }
  return best;
}

function repairTypeForIssue(issue) {
  if (issue === 'Screen Replacement') return 'Screen';
  if (issue === 'Battery (ORIGINAL )') return 'Battery';
  if (issue === 'Charging Socket/Microphone') return 'Charging Port';
  if (issue === 'Front Camera' || issue === 'Rear Camera') return 'Camera';
  return null;
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
    if (/A Series/i.test(parsed.scope || '') && parsed.modelsProcessed >= 80) return filePath;
  }
  throw new Error('No complete A Series history file was found.');
}

async function supabaseConfig() {
  const source = await fs.readFile(path.join(projectRoot, 'supabase-config.js'), 'utf8');
  const url = source.match(/url:\s*'([^']+)'/)?.[1];
  const anonKey = source.match(/anonKey:\s*'([^']+)'/)?.[1];
  if (!url || !anonKey) throw new Error('Supabase public configuration is missing.');
  return { url, anonKey };
}

async function readSiteRows(config) {
  const endpoint = `${config.url}/rest/v1/repair_prices?select=brand,model,issue,price&brand=eq.Samsung%20A%20Series&order=model.asc`;
  const response = await fetch(endpoint, {
    headers: { apikey: config.anonKey, Authorization: `Bearer ${config.anonKey}` },
  });
  if (!response.ok) throw new Error(`Could not read repair prices: ${await response.text()}`);
  return response.json();
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

  const updates = [];
  const unmatched = [];
  for (const siteRow of siteRows) {
    const repairType = repairTypeForIssue(siteRow.issue);
    if (!repairType) continue;
    const match = findBestModel(siteRow.model, candidates);
    const source = match?.candidate.rows.find((row) => row.repairType === repairType);
    if (!source) {
      unmatched.push({ model: siteRow.model, issue: siteRow.issue, sourceModel: match?.candidate.model || '' });
      continue;
    }
    const minimum = priceForPart(source.minPartPrice);
    const maximum = priceForPart(source.maxPartPrice);
    updates.push({
      brand: siteRow.brand,
      model: siteRow.model,
      issue: siteRow.issue,
      oldPrice: siteRow.price,
      newPrice: minimum === maximum ? String(minimum) : `${minimum} - ${maximum}`,
      sourceModel: match.candidate.model,
      repairType,
    });
  }
  return { updates, unmatched };
}

function sqlForUpdates(updates) {
  const payload = JSON.stringify(updates.map((item) => ({
    brand: item.brand,
    model: item.model,
    issue: item.issue,
    new_price: item.newPrice,
  })));
  return `begin;
with incoming as (
  select *
  from jsonb_to_recordset($techm8_sync$${payload}$techm8_sync$::jsonb)
    as row_data(brand text, model text, issue text, new_price text)
)
update public.repair_prices as target
set price = incoming.new_price,
    updated_at = now()
from incoming
where target.brand = incoming.brand
  and target.model = incoming.model
  and target.issue = incoming.issue;
commit;`;
}

async function applyPlan(plan, stamp) {
  const sqlPath = path.join(outputDir, `.supabase-price-sync-${stamp}.sql`);
  await fs.writeFile(sqlPath, sqlForUpdates(plan.updates), 'utf8');
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
  const config = await supabaseConfig();
  const beforeRows = await readSiteRows(config);
  const plan = makePlan(rawData, beforeRows);
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+/, '').replace('T', '-');

  console.log(`Matched ${plan.updates.length} existing Admin price row(s); ${plan.unmatched.length} target row(s) had no eligible supplier price.`);
  if (!args.apply) {
    console.log('Preview only. Add --apply to update Supabase.');
    return;
  }

  await fs.mkdir(backupDir, { recursive: true });
  const backupPath = path.join(backupDir, `${stamp}-before-sync.json`);
  await fs.writeFile(backupPath, JSON.stringify({ historyPath, rows: beforeRows, plan }, null, 2));
  await applyPlan(plan, stamp);

  const afterRows = await readSiteRows(config);
  const afterMap = new Map(afterRows.map((row) => [`${row.brand}|${row.model}|${row.issue}`, row.price]));
  const failed = plan.updates.filter((item) => (
    afterMap.get(`${item.brand}|${item.model}|${item.issue}`) !== item.newPrice
  ));
  if (failed.length) throw new Error(`${failed.length} price row(s) failed verification.`);

  const changed = plan.updates.filter((item) => item.oldPrice !== item.newPrice).length;
  console.log(`Supabase price sync verified: ${plan.updates.length} rows checked, ${changed} changed.`);
  console.log(`Pre-sync backup: ${backupPath}`);
}

main().catch((error) => {
  console.error(`Crazy Parts Supabase sync failed: ${error.message}`);
  process.exitCode = 1;
});
