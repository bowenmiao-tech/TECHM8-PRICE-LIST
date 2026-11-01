import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'techm8-price-merge-'));
try {
  const baseFile = path.join(directory, 'base.json');
  const retryFile = path.join(directory, 'retry.json');
  await fs.writeFile(baseFile, JSON.stringify({
    priceValidationVersion: 2, selectionComplete: true, modelsSelected: 2, modelsProcessed: 1,
    requestedFamilies: ['A Series', 'Tab A Series'],
    modelCatalog: [{ family: 'Tab A Series', brand: 'Samsung', href: '/collection/tab' }],
    modelResults: [{ href: '/collection/a71', validated: true }],
    repairRows: [{ model: 'A71', repairType: 'Screen' }], sourceRows: [{ model: 'A71' }],
    exceptions: [{ issue: 'Model page failed', model: 'Tab A', url: 'https://www.crazyparts.com.au/collection/tab' }],
  }));
  await fs.writeFile(retryFile, JSON.stringify({
    modelResults: [{ heading: 'Tab A', href: '/collection/tab', validated: true }],
    repairRows: [{ model: 'Tab A', family: 'Tab A Series', repairType: 'Screen' }],
    sourceRows: [{ model: 'Tab A', family: 'Tab A Series', available: true, memberPriceVerified: true }], exceptions: [],
  }));
  execFileSync(process.execPath, ['scripts/merge-crazyparts-retry-history.mjs', baseFile, retryFile]);
  const result = JSON.parse(await fs.readFile(retryFile, 'utf8'));
  assert.equal(result.modelsProcessed, 2);
  assert.equal(result.modelResults.length, 2);
  assert.equal(result.repairRows.length, 2);
  assert.equal(result.sourceRows[1].family, 'Tab A Series');
  assert.equal(result.sourceRows[1].memberPriceVerified, true);
  assert.equal(result.exceptions.length, 0);
  assert.equal(result.priceValidationVersion, 2);
  assert.equal(result.selectionComplete, true);
  console.log('PASS: recovered page counts, repair rows, model validation, family mapping, and member-price evidence are preserved.');
} finally {
  for (const entry of await fs.readdir(directory)) await fs.unlink(path.join(directory, entry));
  await fs.rmdir(directory);
}
