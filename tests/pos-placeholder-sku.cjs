const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const {chromium} = require('playwright');

(async () => {
  const root = path.resolve(__dirname, '..');
  const server = http.createServer((request, response) => {
    try {
      const pathname = new URL(request.url, 'http://localhost').pathname;
      response.setHeader('Content-Type', pathname.endsWith('.js') ? 'application/javascript' : 'text/html');
      response.end(fs.readFileSync(path.join(root, pathname)));
    } catch (_) {
      response.writeHead(404).end();
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));

  const browser = await chromium.launch({channel: 'chrome', headless: true});
  try {
    const page = await browser.newPage();
    await page.route('https://**/*', route => route.abort());
    await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?placeholder-sku-test`);
    const result = await page.evaluate(() => {
      const item = {name: '55W 4 Port Wall Charger', qty: 1, unit_price: 39,
        line_total: 39, category: 'Charging & Power',
        sku: 'A stock-keeping unit (SKU) is a scannable barcode to track the movement of inventory.'};
      const order = {id: 'TEST', invoice_number: 4079, total: 39,
        created_at: '2026-09-28T00:00:00Z', items: [item]};
      const invalid = [invoiceDetailsHtml(order), thermalReceiptContent(order)];
      const normalizedInvalid = normalizeProducts([item])[0].sku;
      item.sku = 'CHARGER-55W';
      const valid = [invoiceDetailsHtml(order), thermalReceiptContent(order)];
      return {invalid, valid, normalizedInvalid, normalizedValid: normalizeProducts([item])[0].sku};
    });
    for (const html of result.invalid) {
      assert.doesNotMatch(html, /stock-keeping unit|scannable barcode/);
      assert.match(html, /55W 4 Port Wall Charger/);
    }
    for (const html of result.valid) assert.match(html, /CHARGER-55W/);
    assert.equal(result.normalizedInvalid, '');
    assert.equal(result.normalizedValid, 'CHARGER-55W');
    console.log('Placeholder SKU hidden; valid SKU and item details retained.');
  } finally {
    await browser.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
