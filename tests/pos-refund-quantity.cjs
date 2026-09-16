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
    const page = await browser.newPage({viewport: {width: 1440, height: 1000}});
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('https://**/*', route => route.abort());
    await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);

    await page.evaluate(() => {
      state.refundOrder = {
        items: [{
          line_id: 22023,
          line_type: 'product',
          product_id: 99,
          sku: '8830389',
          name: '1M Ultra Tough USB-C to USB-C Cable',
          qty: 2,
          unit_price: 35,
          line_total: 70,
          refundable_quantity: 2,
          refundable_amount: 70
        }]
      };
      renderRefundLines();
      els.refundModal.classList.add('show');
      els.refundModal.setAttribute('aria-hidden', 'false');
    });

    const row = page.locator('[data-refund-line="22023"]');
    const checkbox = row.locator('[data-refund-check]');
    const amount = row.locator('[data-refund-amount]');
    const quantity = row.locator('[data-refund-quantity]');

    assert.equal(await checkbox.isChecked(), false, 'Refund line was preselected');
    assert.equal(await amount.inputValue(), '35.00', 'One returned item did not default to one unit price');
    assert.equal(await quantity.inputValue(), '1', 'Multi-quantity line did not default to one returned item');
    assert.equal(await page.locator('#refundSubmitBtn').isDisabled(), true, 'Refund submit started enabled');

    await checkbox.check();
    assert.equal(await page.locator('#refundTotal').innerText(), '$35.00');
    await quantity.fill('2');
    assert.equal(await amount.inputValue(), '70.00', 'Refund amount did not follow returned quantity');
    assert.equal(await page.locator('#refundTotal').innerText(), '$70.00');
    await quantity.fill('1');
    assert.equal(await amount.inputValue(), '35.00', 'Refund amount stayed at the full line after quantity returned to one');
    assert.equal(await page.locator('#refundTotal').innerText(), '$35.00');
    assert.equal(errors.length, 0, errors.join('\n'));

    console.log('PASS: refund lines require selection and refund amount follows returned quantity.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
