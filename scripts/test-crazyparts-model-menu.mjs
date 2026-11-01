import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { discoverModels } from './crazyparts-price-monitor.mjs';

const link = (name, slug) => `<a href="/collection/${slug}">${name}</a>`;
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage();
  await page.route('http://price-menu.test/**', (route) => route.fulfill({ contentType: 'text/html', body: `
    <title>Model menu fixture</title><h1>Catalogue</h1><div class="hidden">
      <nav aria-label="Apple">${link('iMac','imac')}${link('iMac A1419','a1419')}</nav>
      <nav aria-label="Samsung">${link('A Series','a-series')}${link('A07 4G (A075)','a07')}</nav>
      <nav aria-label="Google"></nav>
      <nav aria-label="Other Models">
        ${link('All Nintendo','nintendo')}${link('Xbox','xbox')}${link('Valve','valve')}
        ${link('R17 Pro','r17')}${link('P60 Pro','p60')}${link('Xiaomi','xiaomi')}${link('Xiaomi 14T Pro','xiaomi14')}
        ${link('Redmi Note 5','redmi5')}${link('Razr 60','razr60')}${link('Nokia 9','nokia9')}
        ${link('OnePlus 15R','oneplus15')}${link('Realme Series','realme')}${link('Realme Neo7','neo7')}
        ${link('Vivo Y01','y01')}${link('Xperia Series','sony')}${link('Xperia Z5','z5')}${link('Honor','honor')}
      </nav>
    </div>` }));
  const models = await discoverModels(page, { baseUrl: 'http://price-menu.test/', navigationTimeoutMs: 2000 });
  assert.equal(models.some((model) => /Xbox|Valve|Nintendo/.test(model.name)), false);
  assert.equal(models.find((model) => model.name === 'R17 Pro').family, 'Oppo');
  assert.equal(models.find((model) => model.name === 'P60 Pro').family, 'Huawei');
  assert.equal(models.find((model) => model.name === 'Razr 60').family, 'Motorola');
  assert.equal(models.find((model) => model.name === 'A07 4G (A075)').family, 'A Series');
  assert.equal(models.find((model) => model.name === 'Xperia Z5').family, 'Sony');
  assert.equal(models.length, 12);
  console.log('PASS: gaming menu exclusion and supported-brand boundaries, including A07.');
} finally { await browser.close(); }
