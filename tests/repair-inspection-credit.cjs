const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');

(async () => {
  const root = path.resolve(__dirname, '..');
  const server = http.createServer((req, res) => {
    try {
      const name = new URL(req.url, 'http://localhost').pathname;
      res.setHeader('Content-Type', name.endsWith('.js') ? 'application/javascript' : 'text/html');
      res.end(fs.readFileSync(path.join(root, name)));
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = [];
    const requests = [];
    page.on('pageerror', error => errors.push(error.message));
    const ticket = {
      id: 'RPR-CREDIT', title: 'Dell laptop', issue: '(Hardware) Laptop/PC Inspection',
      baseJobName: '(Hardware) Laptop/PC Inspection', basePrice: 99, price: '$99.00',
      store_id: 'toowong', status: 'need_to_order', active: true,
      customerName: 'Test Customer', customerPhone: '0400000000',
      baseInvoiced: true, invoiceNumber: 4159, paymentStatus: 'paid',
      invoiceHistory: [{ invoiceNumber: 4159, paymentStatus: 'paid', balanceDue: 0, total: 99, amountPaid: 99 }],
      jobs: [], intake: {}, activity: []
    };
    await page.route('https://**/*', async route => {
      if (!route.request().url().includes('/pos-repair-tickets')) return route.abort();
      if (route.request().method() !== 'POST') return route.fulfill({ json: { ok: true, ticket } });
      const body = route.request().postDataJSON();
      requests.push(body);
      ticket.jobs = [{ id: 'RJB-CREDIT', jobCode: 'RJB-CREDIT', name: body.name,
        price: Number(body.price), inspectionCredit: Number(body.inspection_credit),
        status: body.status, approvalMethod: body.approval_method,
        note: body.note || '', invoiced: false }];
      ticket.outstandingTotal = 100;
      return route.fulfill({ json: { ok: true, ticket: { ...ticket } } });
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
    await page.evaluate(record => {
      window.Techm8StaffAuth.getToken = () => 'test';
      state.storeId = 'toowong';
      state.selectedStaffName = 'Test Staff';
      state.repairQuotes = [{ brand: 'Dell', model: 'laptop', issue: 'battery repair', price: 199 }];
      state.repairTickets = [normalizeRepairTicket(record)];
    }, ticket);

    await page.evaluate(() => openRepairJobModal(state.repairTickets[0]));
    assert.equal(await page.locator('#repairJobCreditChoice').isVisible(), true);
    await page.locator('#repairJobName').fill('battery repair');
    await page.locator('#repairJobName').press('Tab');
    await page.locator('#repairJobPrice').fill('199.00');
    await page.locator('#repairJobUseInspectionCredit').check();
    assert.equal(await page.locator('#repairJobInspectionCredit').inputValue(), '99.00');
    await page.locator('#repairJobStatus').selectOption('approved');
    await page.locator('#repairJobApproval').selectOption('phone');
    await page.locator('#repairJobSave').click();
    await page.waitForFunction(() => state.repairTickets[0].jobs.length === 1, null, { timeout: 5000 }).catch(async error => {
      console.error('Save diagnostic:', { requests, formError: await page.locator('#repairJobError').innerText(), errors });
      throw error;
    });
    assert.equal(requests[0].price, '199.00');
    assert.equal(requests[0].inspection_credit, '99.00');
    assert.equal(await page.evaluate(() => state.repairTickets[0].jobs[0].price), 199);
    assert.equal(await page.evaluate(() => state.repairTickets[0].jobs[0].inspectionCredit), 99);
    await page.evaluate(() => openRepairJobModal(state.repairTickets[0]));
    assert.equal(await page.locator('#repairJobCreditChoice').isVisible(), false,
      'The inspection fee must not be offered to a second job');
    await page.evaluate(() => closeRepairJobModal());

    await page.evaluate(() => addRepairTicketToCart('RPR-CREDIT', 'RJB-CREDIT'));
    const cart = await page.evaluate(() => ({
      price: state.cart[0].sale_price,
      gross: state.cart[0].original_unit_price,
      credit: state.cart[0].inspection_credit,
      line: posOrderLineFromCartItem(state.cart[0]),
      receipt: thermalReceiptContent({ id: 'POS-TEST', invoice_number: 4160,
        total: 100, items: [posOrderLineFromCartItem(state.cart[0])], payments: [{ method: 'Cash', amount: 100 }] })
    }));
    assert.equal(cart.price, 100);
    assert.equal(cart.gross, 199);
    assert.equal(cart.credit, 99);
    assert.equal(cart.line.inspection_credit, 99);
    assert.match(cart.receipt, /Repair price \$199\.00/);
    assert.match(cart.receipt, /inspection fee credit −\$99\.00/);
    assert.equal(await page.locator('[data-cart-price]').count(), 0);
    assert.match(await page.locator('#cartArea').innerText(), /due \$100\.00/);

    const sameInvoice = await page.evaluate(() => {
      state.cart = [];
      const record = normalizeRepairTicket({ ...state.repairTickets[0], id: 'RPR-SAME',
        baseInvoiced: false, invoiceNumber: '', paymentStatus: 'unpaid', invoiceHistory: [],
        jobs: [{ ...state.repairTickets[0].jobs[0], id: 'RJB-SAME', jobCode: 'RJB-SAME' }] });
      state.repairTickets = [record];
      addRepairTicketToCart('RPR-SAME', '__base__');
      addRepairTicketToCart('RPR-SAME', 'RJB-SAME');
      return { prices: state.cart.map(item => item.sale_price), total: cartTotal() };
    });
    assert.deepEqual(sameInvoice.prices, [99, 100]);
    assert.equal(sameInvoice.total, 199);
    assert.deepEqual(errors, []);
    console.log('PASS: $199 repair, $99 inspection credit, $100 later invoice; same-invoice total $199.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
