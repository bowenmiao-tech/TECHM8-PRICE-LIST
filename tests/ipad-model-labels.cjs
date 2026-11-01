const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { label } = require('../ipad-model-labels.js');

const root = path.resolve(__dirname, '..');
const readJson = name => JSON.parse(fs.readFileSync(path.join(root, name), 'utf8').replace(/^\uFEFF/, ''));
const prices = readJson('data.json');
const appleModels = readJson('apple_a_model_map.json').ipad;
const catalogModels = new Set(prices
  .filter(row => /ipad/i.test(row.brand) || /^ipad/i.test(row.model))
  .map(row => row.model));
// Present in the live price table but not yet in the local fallback data.
[
  'iPad Air 11 (2025)', 'iPad Air 11 (2026)', 'iPad Air 13 (2025)',
  'iPad Air 13 (2026)', 'iPad mini 7 (2024)', 'iPad Pro 11 (2025)',
  'iPad Pro 13 (2025)'
].forEach(model => catalogModels.add(model));

for (const model of catalogModels) {
  const display = label(model);
  const codes = display.match(/\bA\d{4}\b/g) || [];
  assert(codes.length, `No Apple A-model shown for ${model}`);
  assert.equal(new Set(codes).size, codes.length, `Duplicate A-model in ${display}`);
  for (const code of codes) assert(appleModels[code], `${code} is not an iPad model in the Apple lookup`);
}

assert.equal(label('iPad Pro 13 (2024)'), 'iPad Pro 13 (2024) (A2925 A2926 A3007)');
assert.equal(label('iPad AIR 13 (2024) (A2898 A2899)'), 'iPad AIR 13 (2024) (A2898 A2899 A2900)');
assert(!/A2786|A2787|A2788/.test(label('iPad AIR 6 (2024) (A2786 A2787 A2788)')));
assert.equal(label('Samsung S23 Ultra'), 'Samsung S23 Ultra');
console.log(`PASS: ${catalogModels.size} iPad price-list models display verified Apple A-model numbers.`);
