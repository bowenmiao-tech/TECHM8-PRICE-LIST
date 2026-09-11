// Buyback front end: the evidence gate, the locked used-device price, the
// server-driven checklist, and the website panel. APIs are mocked; nothing
// here touches a real project.
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');

(async () => {
  const root = path.resolve(__dirname, '..');
  const server = http.createServer((request, response) => {
    try {
      const name = new URL(request.url, 'http://localhost').pathname;
      response.setHeader('Content-Type',
        name.endsWith('.js') ? 'application/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html');
      response.end(fs.readFileSync(path.join(root, name)));
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ channel: 'chrome', headless: true });

  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));

    const uploads = [];
    await page.route('https://**/*', async route => {
      const url = route.request().url();
      if (url.includes('/pos-used-device-updates')) {
        if (route.request().method() === 'POST') {
          uploads.push(route.request().postDataJSON());
          return route.fulfill({ json: { ok: true, id: 'stub' } });
        }
        return route.fulfill({ json: { ok: true, uploads: uploads.map((entry, index) => ({
          id: `stub-${index}`, stage: entry.stage, image_url: 'https://example.test/photo.jpg',
          author: 'Tester', created_at: new Date().toISOString()
        })) } });
      }
      if (url.includes('/pos-used-device-publish')) {
        return route.fulfill({ json: {
          ok: true, website_status: 'not_published', website_slug: '',
          listing_photo_count: 0, can_publish: false, pending: null
        } });
      }
      if (url.includes('resource=checklists')) {
        return route.fulfill({ json: { ok: true, checklists: {
          Phone: [{ key: 'power', label: 'Server-driven power check' }, { key: 'touch', label: 'Server-driven touch check' }]
        } } });
      }
      if (url.includes('/pos-used-devices')) {
        return route.fulfill({ json: { ok: true, devices: [], summary: {}, transactions: [] } });
      }
      return route.abort();
    });

    await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
    await page.evaluate(() => {
      window.Techm8StaffAuth.getToken = () => 'test';
      state.storeId = 'toowong';
      state.selectedStaffName = 'Tester';
    });

    // A used-device line shows its price but cannot be edited in the cart: the
    // database refuses a line whose price differs from the device record, and
    // it refuses it while the invoice is being written.
    await page.evaluate(() => {
      state.cart = [{
        id: 'used-USED-TEST', sku: 'USED-TEST', name: 'Apple iPhone 13', category: 'Used Devices',
        cost_price: 300, sale_price: 649, qty: 1, is_used_device: true, used_device_id: 'USED-TEST',
        buyer_name: 'Buyer', buyer_phone: '0400000000', buyer_address: '1 Test Street'
      }];
      renderCart();
    });
    assert.equal(await page.locator('.cart-price-input').count(), 0, 'A used device price was editable in the cart');
    assert.equal(await page.locator('.cart-price-locked').count(), 1, 'The locked price was not shown');
    assert.match(await page.locator('.cart-repair-hint').first().innerText(), /Used Devices/,
      'The cart did not say where to change a used device price');

    // The buy form refuses to save without intake photos, before anything else
    // is checked, because the payout happens in the same step.
    await page.evaluate(() => { setActiveView('used-devices'); setUsedDeviceTab('buy'); });
    await page.waitForSelector('#usedDeviceBuyForm');
    assert.equal(await page.locator('#usedDeviceIntakeEvidence .ude-tabs').count(), 1,
      'The intake evidence panel did not mount on the buy form');
    assert.equal(await page.locator('[name="status"]').inputValue(), 'Inspection',
      'A purchase no longer starts in inspection');

    const tooFew = await page.evaluate(async () => {
      state.usedDeviceIntakeCounts = { intake: 2 };
      await submitUsedDevicePurchase(usedDeviceBuyFormEl());
      return usedDeviceBuyFormEl().querySelector('#usedDeviceBuyError').textContent;
    });
    assert.match(tooFew, /at least 3 intake photos/i, `Unexpected refusal: ${tooFew}`);

    // A blocked handset is refused outright, not merely kept off the shelf.
    const blocked = await page.evaluate(async () => {
      state.usedDeviceIntakeCounts = { intake: 3 };
      const form = usedDeviceBuyFormEl();
      form.querySelector('[name="imei"]').value = '356938035643809';
      form.querySelector('[name="storage"]').value = '128GB';
      form.querySelector('#usedDeviceBrandInput').value = 'Apple';
      form.querySelector('#usedDeviceModelInput').value = 'iPhone 13';
      form.querySelector('[name="clean_check_status"]').value = 'Blocked';
      await submitUsedDevicePurchase(form);
      return form.querySelector('#usedDeviceBuyError').textContent;
    });
    assert.match(blocked, /lost or stolen/i, `Unexpected refusal: ${blocked}`);

    // The checklist the screen draws is the one the database enforces.
    const labels = await page.evaluate(() => {
      state.usedDeviceChecklists = { Phone: [
        { key: 'power', label: 'Server-driven power check' },
        { key: 'touch', label: 'Server-driven touch check' }
      ] };
      refreshUsedDeviceCategoryFields();
      return Array.from(document.querySelectorAll('#usedDeviceInspectionGrid .used-inspection-item span'))
        .map(node => node.textContent.trim()).join(' | ');
    });
    assert.match(labels, /Server-driven power check/, 'The POS ignored the checklist from the database');

    assert.deepEqual(errors, [], `Page errors: ${errors.join(', ')}`);
    console.log('PASS: cart price lock, intake photo gate, blocked refusal, server checklist, evidence panel.');
  } finally {
    await browser.close();
    server.close();
  }
})();
