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

  const family = (base.requestedFamilies || [])[0]
    || (base.sourceRows || []).find((row) => row.family)?.family;
  const brand = (base.sourceRows || []).find((row) => row.brand)?.brand;
  if (!family || !brand) throw new Error('Could not determine the original brand and family.');

  const matchedFailures = new Set();
  const correctedRows = (retry.sourceRows || []).map((row) => {
    const rowKey = normalise(row.model);
    const failed = failedModels.find((item) => rowKey.endsWith(normalise(item.model)));
    if (!failed) throw new Error(`Retry model did not match a failed page: ${row.model}`);
    matchedFailures.add(normalise(failed.model));
    return { ...row, brand, family };
  });

  if (matchedFailures.size !== failedModels.length) {
    throw new Error(`Retry history recovered ${matchedFailures.size}/${failedModels.length} failed model pages.`);
  }

  const merged = {
    ...base,
    capturedAt: retry.capturedAt || base.capturedAt,
    modelsProcessed: Number(base.modelsProcessed || 0) + matchedFailures.size,
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
