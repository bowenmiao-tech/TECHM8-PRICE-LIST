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
      const file = path.join(root, pathname);
      response.setHeader('Content-Type', pathname.endsWith('.js') ? 'application/javascript' : pathname.endsWith('.css') ? 'text/css' : 'text/html');
      response.end(fs.readFileSync(file));
    } catch (_) {
      response.writeHead(404).end();
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));

  const browser = await chromium.launch({channel: 'chrome', headless: true});
  try {
    const page = await browser.newPage({viewport: {width: 1440, height: 1000}});
    const pageErrors = [];
    const cardRequests = [];
    const photoRequests = [];
    let rejectCreate = true;
    page.on('pageerror', error => pageErrors.push(error.message));

    await page.route('https://**/*', async route => {
      const request = route.request();
      if (request.url().includes('/pos-repair-cards')) {
        const body = request.postDataJSON();
        cardRequests.push(body);
        if (rejectCreate) {
          return route.fulfill({status: 400, json: {ok: false, message: 'Customer phone is required for repair tickets'}});
        }
        return route.fulfill({json: {ok: true, ticket: body.ticket_payload, signature: {signed_customer_name: body.signed_customer_name}}});
      }
      if (request.url().includes('/pos-repair-updates')) {
        if (request.method() === 'POST') photoRequests.push(request.postDataJSON());
        return route.fulfill({json: {ok: true, writable: true, updates: []}});
      }
      return route.abort();
    });

    await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
    await page.evaluate(() => {
      window.Techm8StaffAuth.getToken = () => 'test-token';
      state.storeId = 'toowong';
      state.selectedStaffName = 'Bowen';
      state.customers = [{id: 'CUS-TEST', name: 'Jane', phone: '0400000000'}];
      state.selectedCustomerId = 'CUS-TEST';
      els.customerInput.value = 'Jane';
      state.repairTickets = [];
      state.repairCardTerms = 'Test repair terms.';
    });

    // Owner-approved special repairs must continue accepting a zero-dollar draft.
    await page.evaluate(() => openSpecialRepairModal());
    await page.locator('#specialRepairName').fill('Warranty inspection');
    await page.locator('#specialRepairPrice').fill('0');
    await page.evaluate(() => addSpecialRepairOrder());
    assert.equal(await page.evaluate(() => state.pendingRepairDraft.specialPrice), '0.00');
    await page.evaluate(() => closeTicketDetailsModal());

    await page.evaluate(() => {
      resetRepairState();
      Object.assign(state.repair, {
        started: true,
        intakeOpen: true,
        status: 'repairing',
        deviceInStore: true,
        quote: {brand: 'Apple', model: 'iPhone 15', issue: 'Inspection', price: '49.00'},
        brand: 'Apple',
        model: 'iPhone 15',
        issue: 'Inspection',
        quotedPrice: '$49.00',
        customerId: 'CUS-TEST',
        customerName: 'Jane',
        customerPhone: '0400000000',
        passwordType: 'none',
        passwordNoneReason: 'Customer did not provide it',
        testable: 'no',
        cannotTestReason: 'Device will not power on',
        deviceIdType: 'none',
        deviceIdUnavailable: 'Label is unreadable',
        media: [{type: 'image', src: 'data:image/jpeg;base64,/9j/2Q==', fileName: 'Intake.jpg', uploadId: crypto.randomUUID()}]
      });
      renderRepairWorkspace();
    });

    await page.evaluate(() => openRepairCardSignature());
    await page.locator('#repairCardReadiness').getByText('Tick the terms and conditions box to unlock signing.').waitFor();
    await page.locator('#repairCardAck').check();
    await page.evaluate(() => { state.repairCard.hasInk = true; updateRepairCardSubmitState(); });

    await page.locator('#repairCardSubmit').click();
    await page.locator('#repairCardError').getByText('Customer phone is required for repair tickets').waitFor();
    assert.equal(await page.evaluate(() => state.repair.ticketId), '');
    assert.equal(await page.evaluate(() => state.repairTickets.length), 0);
    assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem('techm8_pos_repair_tickets') || '[]').length), 0);
    assert(cardRequests[0].ticket_payload);
    assert(!('src' in cardRequests[0].ticket_payload.intake.media[0]));

    rejectCreate = false;
    await page.locator('#repairCardSubmit').click();
    await page.waitForFunction(() => state.repair.ticketId.startsWith('RPR-'));
    assert.equal(await page.evaluate(() => state.repairTickets.length), 1);
    assert.equal(photoRequests.length, 1);
    assert.equal(photoRequests[0].kind, 'photo');
    assert(photoRequests[0].data_url.startsWith('data:image/jpeg;base64,'));
    assert.equal(pageErrors.length, 0, pageErrors.join('\n'));

    console.log('PASS: special $0 remains allowed; exact create error; no ghost ticket; atomic ticket/signature request; image metadata separation and follow-up upload.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
