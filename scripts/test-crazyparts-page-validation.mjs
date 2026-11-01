import assert from 'node:assert/strict';
import fs from 'node:fs';
import { assertSupplierPage, assertProductResult, assertPublishableRun } from './crazyparts-page-validation.mjs';

for (const snapshot of [
  { status: 403, title: '请稍候…', heading: 'www.crazyparts.com.au', text: '正在进行安全验证 Ray ID: test 由 Cloudflare 提供的性能和安全服务' },
  { status: 200, title: 'Just a moment...', text: 'Verify you are human' },
  { status: 200, heading: 'www.crazyparts.com.au' },
  { status: 503, title: 'Service unavailable' },
]) assert.throws(() => assertSupplierPage(snapshot));

assert.doesNotThrow(() => assertSupplierPage({ heading: 'A17 5G (A176)', text: 'Diamond $48.90 +GST' }));
assert.doesNotThrow(() => assertProductResult({ heading: 'iMac A2438', text: '0 items', linkCount: 0, cardCount: 0 }));
assert.doesNotThrow(() => assertProductResult({ heading: 'A8 (A810/2016)', text: 'Sort By\nFeatured\nNo data\nSite Information', linkCount: 0, cardCount: 0 }));
assert.throws(() => assertProductResult({ heading: 'A8', text: 'No data has loaded yet', linkCount: 0, cardCount: 0 }));
assert.throws(() => assertProductResult({ heading: 'A17', text: '36 items', linkCount: 36, cardCount: 0, expectedCount: 36 }));
assert.throws(() => assertProductResult({ heading: 'A17', text: 'Loading...', linkCount: 0, cardCount: 0 }));
assert.throws(() => assertPublishableRun({ modelsSelected: 145, modelsProcessed: 145, repairRows: [], sourceRows: [] }));
assert.throws(() => assertPublishableRun({ priceValidationVersion: 2, modelsSelected: 1, modelsProcessed: 1, repairRows: [{ model: 'A71' }], sourceRows: [{ model: 'A71', available: true, memberPriceVerified: false }] }));
assert.throws(() => assertPublishableRun({ modelsSelected: 1, modelsProcessed: 1, repairRows: [{ model: 'www.crazyparts.com.au' }], sourceRows: [{ model: 'www.crazyparts.com.au' }] }));

// Verify compatibility with a previously published run and rejection of the
// actual all-empty run that preceded this incident, when available locally.
for (const [file, valid] of [
  ['20261007-020501.json', true],
  ['20261027-222807.json', false],
]) {
  const path = new URL(`../outputs/crazyparts-price-monitor/history/${file}`, import.meta.url);
  if (!fs.existsSync(path)) continue;
  const data = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (valid) assert.doesNotThrow(() => assertPublishableRun(data));
  else assert.throws(() => assertPublishableRun(data));
}
console.log('PASS: Chinese/English verification, HTTP errors, missing member prices, confirmed empty catalogues, and publish safety.');
