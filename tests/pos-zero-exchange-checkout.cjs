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
    await page.route('https://abkjbhmifswfexpjkval.supabase.co/functions/v1/pos-shared-state?*', route => {
      return route.fulfill({status: 200, contentType: 'application/json', body: JSON.stringify({
        ok: true,
        customers: [{id: 'CUS-EXCHANGE', name: 'Exchange Buyer', phone: '0412345678'}]
      })});
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);

    await page.evaluate(() => {
      state.selectedStaffName = 'Andy';
      state.cart = [{id: 'FREE', name: 'Free adjustment', sale_price: 0, qty: 1, is_special: true}];
      state.exchangeReturn = null;
      window.__checkoutCalls = [];
      checkout = (payments, options) => window.__checkoutCalls.push({payments, options});
      renderCart();
      openPaymentModal();
    });
    assert.deepEqual(await page.evaluate(() => window.__checkoutCalls), [
      {payments: [], options: {noCharge: true}}
    ]);
    assert.equal(await page.locator('#payBtn').innerText(), '$0.00 Checkout');

    await page.evaluate(() => {
      window.__checkoutCalls = [];
      state.cart = [];
      state.exchangeReturn = null;
      state.refundOrder = {
        id: 'POS-ORIGINAL', invoice_number: 101,
        customer_name: 'Exchange Buyer', customer_phone: '0412345678',
        items: [{line_id: 501, line_type: 'product', name: 'Returned cable', qty: 1,
          unit_price: 35, line_total: 35, refundable_quantity: 1, refundable_amount: 35}]
      };
      els.refundCreditSearch.value = '0412345678';
      els.refundModal.classList.add('show');
      els.refundModal.setAttribute('aria-hidden', 'false');
      renderRefundLines();
      els.refundMethod.value = 'Exchange';
      updateRefundCreditMethod();
    });
    await page.locator('#refundCreditSelected').getByText('Exchange Buyer').waitFor();
    await page.locator('[data-refund-line="501"] [data-refund-check]').check();
    await page.locator('#refundReason').fill('Customer changed product');
    await page.locator('#refundSubmitBtn').click();
    assert.equal(await page.evaluate(() => state.exchangeReturn.total), 35);
    assert.match(await page.locator('#cartArea').innerText(), /Return for exchange/);

    await page.evaluate(() => {
      state.cart = [{id: 'NEW', name: 'Replacement charger', sale_price: 50, qty: 1}];
      renderCart();
      openPaymentModal();
    });
    assert.deepEqual(await page.evaluate(() => state.paymentSession.payments), [
      {method: 'Exchange Credit', amount: 35}
    ]);
    assert.equal(await page.evaluate(() => paymentRemaining()), 15);
    assert.equal(await page.locator('#paymentAmountInput').inputValue(), '15.00');
    assert.equal(await page.locator('#summaryReturnCredit').innerText(), '-$35.00');

    await page.evaluate(() => {
      closePaymentModal();
      window.__checkoutCalls = [];
      state.cart = [{id: 'EQUAL', name: 'Equal replacement', sale_price: 35, qty: 1}];
      renderCart();
      openPaymentModal();
    });
    assert.deepEqual(await page.evaluate(() => window.__checkoutCalls), [{
      payments: [{method: 'Exchange Credit', amount: 35}],
      options: {noCharge: false}
    }]);

    const receipt = await page.evaluate(() => thermalReceiptContent({
      id: 'POS-NEW', invoice_number: 102, total: 25, amount_paid: 25,
      payment_status: 'paid', payment_method: 'Store Credit',
      payments: [{method: 'Store Credit', amount: 25}],
      items: [{name: 'Replacement', qty: 1, unit_price: 25, line_total: 25}],
      exchange_source: {invoice_number: 101, credit_issued: 35, credit_used: 25},
      store_credit_remaining: 10
    }));
    assert.match(receipt, /Return from invoice #101/);
    assert.match(receipt, /Exchange credit remaining/);
    assert.equal(errors.length, 0, errors.join('\n'));
    console.log('PASS: zero checkout and atomic exchange credit UI paths are correct.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
