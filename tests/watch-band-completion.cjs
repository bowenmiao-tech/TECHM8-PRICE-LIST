const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');

(async () => {
  const root = path.resolve(__dirname, '..');
  const fixture = require('./fixtures/watch-band-completion.json');
  const baseline = require('./fixtures/watch-band-baseline.json');
  const additions = fixture.variants;
  assert.equal(additions.length, 51);
  assert.equal(additions.filter(x => x.synthetic).length, 3);
  const all = [...baseline, ...additions];
  assert.equal(new Set(all.map(x => x.sku)).size, 112);
  const groups = [...new Set(all.map(x => x.group_code))];
  assert.equal(groups.length, 56);
  for (const group of groups) {
    assert.deepEqual(all.filter(x => x.group_code === group).map(x => x.size).sort(), ['38/40mm', '42/44mm']);
  }
  for (const row of additions) {
    assert(row.reference_price > 0 && row.reference_cost > 0);
    assert(row.image.startsWith('https://dghyt15qon7us.cloudfront.net/'));
    assert(baseline.some(x => x.sku === row.reference_sku));
    if (row.synthetic) assert.equal(row.source_id, null);
    else assert.equal(row.sku, `TM8-WB-${row.source_id}`);
  }
  const livePath = process.argv[2];
  if (!livePath) return console.log('PASS: 51 additions; 56 groups; 112 unique size variants.');
  const live = JSON.parse(fs.readFileSync(livePath, 'utf8'));
  assert.equal(live.length, 112);
  const browser = await chromium.launch({channel: 'chrome', headless: true});
  try {
    const context = await browser.newContext({viewport: {width: 1440, height: 1000}});
    await context.route('http://localhost:9876/**', async route => {
      const pathname = new URL(route.request().url()).pathname;
      const file = path.join(root, pathname === '/' ? 'pos.html' : pathname);
      if (!file.startsWith(root) || !fs.existsSync(file)) return route.fulfill({status: 404});
      return route.fulfill({body: fs.readFileSync(file), contentType: file.endsWith('.html') ? 'text/html' : file.endsWith('.js') ? 'application/javascript' : file.endsWith('.css') ? 'text/css' : 'application/octet-stream'});
    });
    const page = await context.newPage();
    await page.goto('http://localhost:9876/pos.html?catalog-test&catalog-watch-band');
    await page.waitForFunction(() => document.body.dataset.catalogTestResult);
    const initialize = await page.evaluate(rows => {
      state.products = normalizeProducts(rows.map(p => ({...p, sale_price: Number(p.retail_price), qty_on_hand: 0})));
      state.search = ''; state.category = 'Watch Accessories'; state.subcategory = 'Watch Bands';
      state.productBrowseMode = 'all'; state.cart = [];
      closeProductVariantModal(); setActiveView('products'); renderProductBrowser(); renderCart();
      return productTiles(state.products).length;
    }, live);
    assert.equal(initialize, 56);
    for (const group of groups) {
      const result = await page.evaluate(code => {
        openProductVariantModal(code);
        return {sizes: [...els.productVariantList.querySelectorAll('.product-variant-size')].map(x => x.textContent.trim()), prices: [...els.productVariantList.querySelectorAll('.product-variant-option-price')].map(x => x.textContent.trim())};
      }, group);
      assert.deepEqual(result.sizes.sort(), ['38/40mm', '42/44mm']);
      assert(result.prices.every(x => !x.includes('$0.00')));
    }
    const imageResults = await page.evaluate(async rows => {
      const urls = [...new Set(rows.map(x => x.image_url))];
      const results = [];
      for (const url of urls) {
        const ok = await new Promise(resolve => {
          const img = new Image(); const timeout = setTimeout(() => resolve(false), 10000);
          img.onload = () => {clearTimeout(timeout); resolve(img.naturalWidth > 0);};
          img.onerror = () => {clearTimeout(timeout); resolve(false);}; img.src = url;
        });
        if (!ok) results.push(url);
      }
      return results;
    }, live);
    assert.deepEqual(imageResults, []);
    await page.evaluate(() => openProductVariantModal('TM8-GRP-WB-SILICONE-BLUE-FLOWER'));
    await page.screenshot({path: path.join(root, 'outputs/watch-band-desktop.png')});
    await page.setViewportSize({width: 390, height: 844});
    await page.screenshot({path: path.join(root, 'outputs/watch-band-mobile.png')});
    console.log('PASS: live 56 cards / 112 sizes, positive prices, all original images load, desktop/mobile screenshots.');
  } finally { await browser.close(); }
})().catch(error => {console.error(error); process.exitCode = 1;});
