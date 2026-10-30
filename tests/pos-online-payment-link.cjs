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
    const savedOrders = [];
    let linkPolls = 0;
    const acknowledged = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('https://**/*', route => route.abort());
    await page.route('https://abkjbhmifswfexpjkval.supabase.co/functions/v1/pos-sales-orders*', route => {
      const request = route.request();
      const mode = new URL(request.url()).searchParams.get('mode');
      if (request.method() === 'POST' && !mode) {
        const order = JSON.parse(request.postData());
        savedOrders.push(order);
        return route.fulfill({status: 200, contentType: 'application/json', body: JSON.stringify({
          ok: true,
          order: {...order, invoice_number: 501, payment_status: 'deposit', amount_paid: 0, balance_due: 80, payments: []},
          payment_link: {link_code: 'PL-TEST', status: 'sent', amount: 80,
            customer_email: 'buyer@example.com', email_sent_at: new Date().toISOString(), invoice_number: 501},
          inventory: {ok: true}
        })});
      }
      if (request.method() === 'GET' && mode === 'payment-links') {
        linkPolls += 1;
        assert.equal(new URL(request.url()).searchParams.get('unacknowledged'), '1');
        const links = [{link_code: 'PL-DEP', status: 'paid', paid_method: 'Online Payment', paid_amount: 20,
          invoice_number: 400, order_id: 'POS-400', order_total: 189, order_amount_paid: 20, order_balance_due: 169,
          order_items: 'Screen replacement', paid_at: new Date().toISOString(),
          customer_name: 'Repair Buyer', customer_phone: '0400000000', customer_email: 'repair@example.com'}]
          .filter(link => !acknowledged.includes(link.link_code));
        if (linkPolls > 1) links.push({link_code: 'PL-TEST', status: 'paid', paid_method: 'Online Afterpay',
          afterpay_fee: 5.1, paid_amount: 85.1, invoice_number: 501, order_id: 'POS-501',
          order_total: 85.1, order_amount_paid: 85.1, order_balance_due: 0, order_items: 'Test item, Afterpay processing fee',
          paid_at: new Date().toISOString(), customer_name: 'Test Buyer', customer_email: 'buyer@example.com'});
        return route.fulfill({status: 200, contentType: 'application/json', body: JSON.stringify({ok: true, payment_links: links})});
      }
      if (request.method() === 'POST' && mode === 'payment-link-acknowledge') {
        const body = JSON.parse(request.postData());
        acknowledged.push(body.link_code);
        return route.fulfill({status: 200, contentType: 'application/json', body: JSON.stringify({ok: true})});
      }
      return route.abort();
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);

    // The modal: a customer is required, the email comes from their record,
    // and the one button says exactly what will be sent.
    await page.evaluate(() => {
      state.storeId = 'toowong';
      state.selectedStaffName = 'Andy';
      state.selectedCustomerId = '';
      els.customerInput.value = '';
      state.customers = [{id: 'CUS-TEST', name: 'Test Buyer', phone: '0412345678', email: 'Buyer@Example.com'}];
      state.cart = [{id: 'TEST', name: 'Test item', sale_price: 80, qty: 1, is_special: true}];
      state.exchangeReturn = null;
      window.__realCheckout = checkout;
      window.__checkoutCalls = [];
      checkout = (payments, options) => window.__checkoutCalls.push({payments, options});
      openPaymentModal();
    });
    assert.match(await page.locator('#paymentMethodList').innerText(), /Online Payment/);
    await page.locator('[data-payment-method="Online Payment"]').click();
    assert.equal(await page.locator('#paymentLinkFields').isVisible(), true);
    assert.match(await page.locator('#paymentLinkCustomer').innerText(), /Select or add the customer/);
    assert.equal(await page.locator('#paymentConfirmBtn').isDisabled(), true);
    assert.equal(await page.locator('#paymentQuickGrid').isVisible(), false);
    assert.equal(await page.locator('#paymentFullBtn').isVisible(), false);
    assert.equal(await page.locator('.payment-link-fields small').count(), 0);

    await page.evaluate(() => {
      closePaymentModal();
      state.selectedCustomerId = 'CUS-TEST';
      els.customerInput.value = 'Test Buyer';
      openPaymentModal();
      selectPaymentMethod('Online Payment');
    });
    assert.match(await page.locator('#paymentLinkCustomer').innerText(), /Test Buyer[\s\S]*0412345678/);
    assert.equal(await page.locator('#paymentLinkEmail').inputValue(), 'Buyer@Example.com');
    assert.equal(await page.locator('#paymentConfirmBtn').innerText(), 'Send link for $80.00');
    assert.match(await page.locator('#paymentLinkSplit').innerText(), /Full amount: link for \$80\.00/);

    await page.locator('#paymentAmountInput').fill('50');
    assert.match(await page.locator('#paymentLinkSplit').innerText(), /Deposit: link for \$50\.00 · \$30\.00 stays owing/);
    assert.equal(await page.locator('#paymentConfirmBtn').innerText(), 'Send link for $50.00');
    await page.locator('#paymentAmountInput').fill('0.20');
    assert.equal(await page.locator('#paymentConfirmBtn').isDisabled(), true);
    await page.locator('#paymentAmountInput').fill('81');
    assert.equal(await page.locator('#paymentConfirmBtn').isDisabled(), true);

    await page.locator('#paymentAmountInput').fill('80');
    await page.locator('#paymentLinkEmail').fill('not-an-email');
    await page.locator('#paymentConfirmBtn').click();
    assert.match(await page.locator('#paymentError').innerText(), /email address/);
    assert.equal(await page.evaluate(() => window.__checkoutCalls.length), 0);

    await page.locator('#paymentLinkEmail').fill('buyer@example.com');
    await page.locator('#paymentConfirmBtn').click();
    await page.waitForFunction(() => window.__checkoutCalls.length === 1);
    assert.deepEqual(await page.evaluate(() => window.__checkoutCalls), [
      {payments: [], options: {paymentLink: {email: 'buyer@example.com', amount: 80}}}
    ]);
    assert.equal(await page.evaluate(() => els.paymentModal.classList.contains('show')), false);

    // Used devices are refused before anything is sent.
    await page.evaluate(() => {
      window.__checkoutCalls = [];
      state.cart = [{id: 'USED', name: 'Used phone', sale_price: 300, qty: 1, is_used_device: true, used_device_id: 'D1'}];
      openPaymentModal();
      selectPaymentMethod('Online Payment');
    });
    await page.locator('#paymentConfirmBtn').click();
    assert.match(await page.locator('#paymentError').innerText(), /Used devices/);
    assert.equal(await page.evaluate(() => window.__checkoutCalls.length), 0);

    // The real checkout saves the sale owing, with the link request attached.
    await page.evaluate(async () => {
      closePaymentModal();
      checkout = window.__realCheckout;
      const today = brisbaneDateIso();
      resolveCheckoutShift = async () => ({id: 'SHIFT-TEST', status: 'open', date: today, startedAt: new Date().toISOString()});
      state.openingConfirmed = true;
      state.cart = [{id: 'TEST', name: 'Test item', sale_price: 80, qty: 1, is_special: true}];
      state.paymentSession = {method: 'Online Payment', payments: [], amount: ''};
      await checkout([], {paymentLink: {email: 'buyer@example.com', amount: 80}});
    });
    assert.equal(savedOrders.length, 1);
    const saved = savedOrders[0];
    assert.deepEqual(saved.payment_link, {email: 'buyer@example.com', amount: 80});
    assert.deepEqual(saved.payments, []);
    assert.equal(saved.payment_method, 'Online Payment');
    assert.equal(saved.payment_status, 'deposit');
    assert.equal(saved.balance_due, 80);
    assert.equal(await page.evaluate(() => state.cart.length), 0);
    await page.locator('.toast, #toast, [role="status"]').filter({hasText: 'Payment link for $80.00 emailed to buyer@example.com'}).first().waitFor();
    const stored = await page.evaluate(() => readLocalArray(POS_ORDERS_KEY).find(order => order.invoice_number === 501));
    assert.equal(stored.payment_link, undefined, 'A saved sale must not ask for another link on retry');

    // Paid links stay on screen as notices until someone at the store presses Got it.
    await page.evaluate(() => checkPaymentLinkUpdates());
    const deposit = page.locator('.payment-notice').filter({hasText: 'Invoice #400'});
    await deposit.waitFor();
    assert.match(await deposit.innerText(), /Deposit paid/);
    assert.match(await deposit.innerText(), /\$20\.00 paid · \$169\.00 still owing of \$189\.00/);
    assert.match(await deposit.innerText(), /Repair Buyer · 0400000000/);
    assert.match(await deposit.innerText(), /Screen replacement/);

    await page.evaluate(() => checkPaymentLinkUpdates());
    const full = page.locator('.payment-notice').filter({hasText: 'Invoice #501'});
    await full.waitFor();
    assert.match(await full.innerText(), /Paid in full/);
    assert.match(await full.innerText(), /\$85\.10 paid \(incl\. \$5\.10 Afterpay fee\)/);
    assert.match(await full.innerText(), /Afterpay/);
    assert.equal(await page.locator('.payment-notice').count(), 2);

    await deposit.getByRole('button', {name: 'Got it'}).click();
    await page.waitForFunction(() => document.querySelectorAll('.payment-notice').length === 1);
    assert.deepEqual(acknowledged, ['PL-DEP']);
    await page.evaluate(() => checkPaymentLinkUpdates());
    assert.equal(await page.locator('.payment-notice').count(), 1, 'An acknowledged notice came back');

    assert.equal(errors.length, 0, errors.join('\n'));
    console.log('PASS: online payment link checkout, validation and paid notice work.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
