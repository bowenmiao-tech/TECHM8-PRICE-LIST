const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

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

  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await page.route('https://**/*', route => route.abort());
    await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?placeholder-sku-test`);
    const result = await page.evaluate(() => {
      const repair = {
        line_type: 'repair', name: 'Screen Replacement (OLED)',
        repair_device: 'Apple iPhone iPhone 16', ticket_id: 'RPR-TEST',
        qty: 1, unit_price: 249, line_total: 249, sku: 'REPAIR'
      };
      const product = {
        line_type: 'retail', name: '30W Type C Wall Charger',
        qty: 2, unit_price: 25, line_total: 50
      };
      const invoice = invoiceDetailsHtml({
        id: 'POS-TEST', invoice_number: 4340, customer_name: 'Test Customer',
        customer_phone: '0400000000', staff_name: 'Bowen',
        payment_status: 'paid', created_at: '2026-10-19T00:00:00Z',
        items: [repair, product], total: 299, amount_paid: 299
      });
      state.performanceError = '';
      state.performanceLoading = false;
      state.performanceOpen = { repair: true, retail: true };
      state.performance = {
        totals: { net: 299, received: 299, refunded: 0, order_count: 1 },
        categories: [
          { type: 'repair', net: 249, units: 1, order_count: 1, orders: [{
            order_code: 'POS-TEST', invoice_number: 4340,
            customer_name: 'Test Customer', net: 249, paid_on: '2026-10-19',
            items: [{ device: repair.repair_device, name: repair.name, qty: 1 }]
          }] },
          { type: 'retail', net: 50, units: 2, order_count: 1, orders: [{
            order_code: 'POS-TEST', invoice_number: 4340,
            customer_name: 'Test Customer', net: 50, paid_on: '2026-10-19',
            items: [{ name: product.name, qty: 2 }]
          }] }
        ],
        payment_totals: [], hourly_trend: [], daily_trend: []
      };
      renderPerformanceReport();
      return {
        invoice,
        repairRow: document.querySelector('[data-perf-category="repair"] .perf-order').textContent,
        productRow: document.querySelector('[data-perf-category="retail"] .perf-order').textContent
      };
    });
    assert.match(result.invoice, /Apple iPhone 16/);
    assert.match(result.invoice, /Repair work<\/span><strong>Screen Replacement \(OLED\)/);
    assert.ok(result.invoice.indexOf('invoice-repair-overview') < result.invoice.indexOf('invoice-detail-grid'));
    assert.doesNotMatch(result.invoice, /Checkout staff|Order reference|Payment status|SKU REPAIR/);
    assert.match(result.repairRow, /Apple iPhone 16 — Screen Replacement \(OLED\)/);
    assert.doesNotMatch(result.repairRow, /Wall Charger|Collected by/);
    assert.match(result.productRow, /2 × 30W Type C Wall Charger/);
    assert.doesNotMatch(result.productRow, /Screen Replacement|Collected by/);
    console.log('Invoice and performance lists show device, repair work, and product names.');
  } finally {
    await browser.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
