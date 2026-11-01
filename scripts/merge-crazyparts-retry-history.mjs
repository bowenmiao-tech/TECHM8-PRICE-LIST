import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

function normalise(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, '');
}

function usage() {
  console.log('Usage: node scripts/merge-crazyparts-retry-history.mjs <base-history.json> <retry-history.json>');
}

async function main() {
  const [, , baseArg, retryArg] = process.argv;
  if (!baseArg || !retryArg) {
    usage();
    process.exitCode = 1;
    return;
  }

  const basePath = path.resolve(baseArg);
  const retryPath = path.resolve(retryArg);
  const base = JSON.parse(await fs.readFile(basePath, 'utf8'));
  const retry = JSON.parse(await fs.readFile(retryPath, 'utf8'));
  const failedModels = (base.exceptions || []).filter((row) => row.issue === 'Model page failed');
  if (!failedModels.length) throw new Error('The base history has no failed model pages to retry.');

  const matchedFailures = new Set();
  const matchFailure = (row) => failedModels.find((item) => (
    normalise(row.model || row.heading || row.name).endsWith(normalise(item.model))
    || ((row.href || row.modelUrl) && new URL(item.url).pathname === (row.href || row.modelUrl))
  ));
  for (const row of retry.modelResults || []) {
    const failed = matchFailure(row);
    if (!failed || row.validated !== true) throw new Error(`Retry page was not a verified failed model: ${row.heading}`);
    matchedFailures.add(normalise(failed.model));
  }
  const correctedRows = (retry.sourceRows || []).map((row) => {
    const failed = matchFailure(row);
    if (!failed) throw new Error(`Retry model did not match a failed page: ${row.model}`);
    matchedFailures.add(normalise(failed.model));
    const catalog = (base.modelCatalog || []).find((model) => model.href === new URL(failed.url).pathname);
    return { ...row, brand: catalog?.brand || row.brand, family: catalog?.family || row.family };
  });

  if (matchedFailures.size !== failedModels.length) {
    throw new Error(`Retry history recovered ${matchedFailures.size}/${failedModels.length} failed model pages.`);
  }

  const merged = {
    ...base,
    capturedAt: retry.capturedAt || base.capturedAt,
    modelsProcessed: Number(base.modelsProcessed || 0) + matchedFailures.size,
    modelResults: [...(base.modelResults || []), ...(retry.modelResults || [])],
    productCatalog: [...(base.productCatalog || []), ...(retry.productCatalog || [])],
    repairRows: [...(base.repairRows || []), ...(retry.repairRows || [])],
    sourceRows: [...(base.sourceRows || []), ...correctedRows],
    exceptions: [
      ...(base.exceptions || []).filter((row) => (
        row.issue !== 'Model page failed' || !matchedFailures.has(normalise(row.model))
      )),
      ...(retry.exceptions || []),
    ],
  };

  if (merged.modelsProcessed !== Number(merged.modelsSelected || 0)) {
    throw new Error(`Merged history is incomplete: ${merged.modelsProcessed}/${merged.modelsSelected} model pages.`);
  }

  await fs.writeFile(retryPath, JSON.stringify(merged, null, 2), 'utf8');
  console.log(`Merged ${matchedFailures.size} recovered model page(s) into ${retryPath}`);
}

main().catch((error) => {
  console.error(`Crazy Parts retry merge failed: ${error.message}`);
  process.exitCode = 1;
});
