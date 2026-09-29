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
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('https://**/*', route => route.abort());
    await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
    await page.evaluate(() => {
      state.selectedStaffName = 'Andy';
      state.openingConfirmed = true;
      resolveCheckoutShift = async () => ({ id: 'SHIFT-TEST', status: 'open', date: brisbaneDateIso() });
      window.__refreshStarted = [];
      window.__refreshDone = [];
      window.__releaseRefresh = {};
      const slowRefresh = name => {
        window.__refreshStarted.push(name);
        return new Promise(resolve => {
          window.__releaseRefresh[name] = () => { window.__refreshDone.push(name); resolve(); };
        });
      };
      loadRepairTickets = () => slowRefresh('repairs');
      loadTodayProgress = () => slowRefresh('progress');
      loadProducts = () => slowRefresh('products');
      loadUsedDevices = () => slowRefresh('used');
      const originalFetch = window.fetch;
      window.fetch = (url, options = {}) => {
        if (String(url).includes('/pos-sales-orders') && ['POST', 'PUT'].includes(options.method)) {
          const submitted = JSON.parse(options.body);
          window.__saveStarted = true;
          return new Promise(resolve => {
            window.__releaseSave = success => resolve(new Response(JSON.stringify(success ? {
              ok: true,
              order: { ...submitted, id: submitted.order_id || submitted.id, invoice_number: 1234,
                total: 39, amount_paid: 39, payment_status: 'paid', balance_due: 0,
                items: submitted.items || [], sync_pending: false }
            } : { ok: false, message: 'Repair ticket intake is incomplete' }), { status: success ? 200 : 400 }));
          });
        }
        return originalFetch(url, options);
      };
      window.__startSale = () => {
        state.cart = [{ id: 'TEST', name: 'Charger', sale_price: 39, qty: 1, is_special: true }];
        state.exchangeReturn = null;
        state.paymentSession = { method: 'Card', payments: [], amount: '39', balanceOrderId: '' };
        renderCart();
        confirmPaymentAmount(true);
      };
      window.__startSale();
    });
    await page.waitForFunction(() => window.__saveStarted);
    assert.equal(await page.locator('#receiptCompleteModal').getAttribute('aria-hidden'), 'true',
      'Receipt must not claim success before the payment is saved');
    await page.evaluate(() => window.__releaseSave(true));
    await page.waitForFunction(() => document.querySelector('#receiptCompleteModal').getAttribute('aria-hidden') === 'false');
    assert.match(await page.locator('#receiptCompleteMeta').innerText(), /1234/);
    assert.equal(await page.evaluate(() => state.cart.length), 0);
    assert.deepEqual(await page.evaluate(() => window.__refreshDone), [],
      'The receipt should appear while the refreshes are still pending');
    await page.waitForFunction(() => window.__refreshStarted.length === 1);
    assert.deepEqual(await page.evaluate(() => window.__refreshStarted), ['progress'],
      'An ordinary sale should not reload the unrelated repair board');
    await page.evaluate(() => Object.values(window.__releaseRefresh).forEach(release => release()));

    // A failed payment save must still preserve the cart and keep the receipt closed.
    await page.evaluate(() => { closeReceiptCompleteModal(); window.__saveStarted = false; window.__startSale(); });
    await page.waitForFunction(() => window.__saveStarted);
    await page.evaluate(() => window.__releaseSave(false));
    await page.waitForFunction(() => document.body.innerText.includes('Checkout was not completed.'));
    assert.equal(await page.evaluate(() => document.body.innerText.includes('Repair ticket intake is incomplete')), true,
      'Checkout must show the server rejection instead of blaming the connection');
    assert.equal(await page.locator('#receiptCompleteModal').getAttribute('aria-hidden'), 'true');
    assert.equal(await page.evaluate(() => state.cart.length), 1);

    // Paying an invoice balance uses the same fast receipt path.
    await page.evaluate(() => {
      window.__refreshStarted = []; window.__refreshDone = []; window.__saveStarted = false;
      void submitBalancePayment('POS-BALANCE', [{ method: 'Card', amount: 39 }]);
    });
    await page.waitForFunction(() => window.__saveStarted);
    await page.evaluate(() => window.__releaseSave(true));
    await page.waitForFunction(() => document.querySelector('#receiptCompleteModal').getAttribute('aria-hidden') === 'false');
    assert.equal(await page.evaluate(() => state.lastCompletedOrder.id), 'POS-BALANCE');
    assert.deepEqual(await page.evaluate(() => window.__refreshDone), []);
    await page.evaluate(() => Object.values(window.__releaseRefresh).forEach(release => release()));

    // Used-device stock refresh must not delay printing or leave it sellable.
    await page.evaluate(() => {
      closeReceiptCompleteModal();
      window.__refreshStarted = []; window.__refreshDone = []; window.__saveStarted = false;
      state.usedDevices = [{ id: 'USED-TEST', status: 'ready_for_sale', sale_price: 39 }];
      state.cart = [{ id: 'USED-TEST', used_device_id: 'USED-TEST', is_used_device: true,
        name: 'Used phone', sale_price: 39, qty: 1 }];
      state.paymentSession = { method: 'Card', payments: [], amount: '39', balanceOrderId: '' };
      selectedRepairCustomer = () => ({ id: 'CUS-TEST', name: 'Buyer', phone: '0400000000' });
      confirmPaymentAmount(true);
    });
    await page.waitForFunction(() => window.__saveStarted);
    await page.evaluate(() => window.__releaseSave(true));
    await page.waitForFunction(() => document.querySelector('#receiptCompleteModal').getAttribute('aria-hidden') === 'false');
    assert.equal(await page.evaluate(() => state.usedDevices[0].status), 'sold');
    assert.deepEqual(await page.evaluate(() => window.__refreshDone), []);
    assert.deepEqual((await page.evaluate(() => window.__refreshStarted)).sort(), ['progress', 'used']);
    await page.evaluate(() => Object.values(window.__releaseRefresh).forEach(release => release()));

    // Background failures are contained and never dismiss the paid receipt.
    await page.evaluate(async () => {
      loadTodayProgress = async () => { throw new Error('Dashboard unavailable'); };
      await refreshAfterCheckout();
    });
    assert.equal(await page.locator('#receiptCompleteModal').getAttribute('aria-hidden'), 'false');
    assert.deepEqual(errors, []);
    console.log('PASS: Full Payment and balance receipts appear before slow refreshes; failed saves keep the cart; background failures preserve the receipt.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
