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
    await page.route('https://abkjbhmifswfexpjkval.supabase.co/functions/v1/pos-sales-orders?*', route => {
      if (new URL(route.request().url()).searchParams.get('mode') !== 'store-credit-balance') {
        return route.abort();
      }
      return route.fulfill({status: 200, contentType: 'application/json', body: JSON.stringify({
        ok: true, customer_code: 'CUS-TEST', customer_name: 'Test Buyer', balance: 30
      })});
    });
    await page.route('https://abkjbhmifswfexpjkval.supabase.co/functions/v1/pos-shared-state?*', route => {
      return route.fulfill({status: 200, contentType: 'application/json', body: JSON.stringify({
        ok: true, customers: [{id: 'CUS-TEST', name: 'Test Buyer', phone: '0412345678'}]
      })});
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
    await page.evaluate(() => {
      state.storeId = 'toowong';
      state.selectedCustomerId = 'CUS-TEST';
      state.customers = [{id: 'CUS-TEST', name: 'Test Buyer', phone: '0412345678'}];
      state.cart = [{id: 'TEST', name: 'Test item', sale_price: 80, qty: 1}];
      state.paymentSession = {method: 'Card', payments: [], amount: ''};
      els.paymentModal.classList.add('show');
      els.paymentModal.setAttribute('aria-hidden', 'false');
      selectPaymentMethod('Store Credit');
    });
    await page.locator('#paymentCreditInfo').getByText('$30.00 available').waitFor();
    assert.equal(await page.locator('#paymentAmountInput').inputValue(), '30.00');
    await page.locator('#paymentAmountInput').fill('31.00');
    await page.locator('#paymentConfirmBtn').click();
    assert.match(await page.locator('#paymentError').innerText(), /Only \$30\.00 Store Credit/);
    assert.equal(await page.evaluate(() => state.paymentSession.payments.length), 0);
    await page.locator('#paymentFullBtn').click();
    assert.deepEqual(await page.evaluate(() => state.paymentSession.payments), [
      {method: 'Store Credit', amount: 30}
    ]);
    assert.equal(await page.evaluate(() => paymentRemaining()), 50);
    await page.evaluate(() => selectPaymentMethod('Card'));
    assert.equal(await page.locator('#paymentAmountInput').inputValue(), '50.00');

    await page.evaluate(() => {
      closePaymentModal();
      state.refundOrder = {
        id: 'POS-TEST', customer_name: 'Test Buyer', customer_phone: '0412345678',
        items: [{line_id: 123, line_type: 'product', name: 'Cable', qty: 1,
          unit_price: 35, line_total: 35, refundable_quantity: 1, refundable_amount: 35}]
      };
      els.refundCreditSearch.value = '0412345678';
      els.refundModal.classList.add('show');
      els.refundModal.setAttribute('aria-hidden', 'false');
      renderRefundLines();
    });
    await page.locator('#refundMethod').selectOption('Store Credit');
    await page.locator('#refundCreditSelected').getByText('Test Buyer').waitFor();
    await page.locator('[data-refund-line="123"] [data-refund-check]').check();
    assert.equal(await page.locator('#refundTotal').innerText(), '$35.00');
    assert.equal(await page.evaluate(() => refundCreditCustomer.id), 'CUS-TEST');
    assert.equal(await page.evaluate(() => refundCreditCustomerMatchesOrder({name: 'Other', phone: '0499999999'})), false);
    assert.equal(errors.length, 0, errors.join('\n'));
    console.log('PASS: Store Credit is account-bound, capped, can mix with Card, and refund selects the matching customer.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
