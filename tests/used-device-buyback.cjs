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
    const removals = [];
    await page.route('https://**/*', async route => {
      const url = route.request().url();
      if (url.includes('/pos-used-device-updates')) {
        if (route.request().method() === 'POST') {
          const body = route.request().postDataJSON();
          if (body.action === 'remove') {
            removals.push(body);
            const index = uploads.findIndex(entry => entry.id === body.id);
            if (index >= 0) uploads.splice(index, 1);
            return route.fulfill({ json: { ok: true, id: body.id } });
          }
          uploads.push(body);
          return route.fulfill({ json: { ok: true, id: 'stub' } });
        }
        return route.fulfill({ json: { ok: true, uploads: uploads.map((entry, index) => ({
          id: entry.id || `stub-${index}`, stage: entry.stage, image_url: 'https://example.test/photo.jpg',
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
      if (url.includes('resource=costs')) return route.fulfill({json:{ok:true,costs:[],can_view_costs:false,writable:true}});
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
    // counter uses the approved device price. Server-side price checks run
    // while the invoice is being written.
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

    // A photo taken by mistake on the buy form can be deleted before the
    // purchase is saved.
    uploads.push({ id: 'draft-photo-1', stage: 'intake' });
    await page.locator('#usedDeviceIntakeEvidence [data-action="refresh"]').click();
    await page.locator('#usedDeviceIntakeEvidence .ude-remove').waitFor();
    await page.evaluate(() => { window.confirm = () => true; });
    await page.locator('#usedDeviceIntakeEvidence .ude-remove').click();
    await page.waitForFunction(() => /Photo deleted/.test(document.querySelector('#usedDeviceIntakeEvidence .ude-status').textContent));
    assert.equal(removals.length, 1, 'Deleting a draft photo sent nothing');
    assert.equal(removals[0].id, 'draft-photo-1');
    assert.ok(removals[0].intake_key, 'A draft photo was removed without its intake key');
    assert.equal(await page.locator('#usedDeviceIntakeEvidence .ude-photo').count(), 0, 'The deleted photo is still shown');

    // Condition, sale price, the check reference and the inventory status all
    // belong to the listing step, not to the counter.
    for (const gone of ['condition_grade', 'sale_price', 'clean_check_reference', 'status']) {
      assert.equal(await page.locator(`#usedDeviceBuyForm [name="${gone}"]`).count(), 0,
        `${gone} is still on the intake form`);
    }

    // The device is identified first: category, then the model search, then
    // storage and battery, then the identifier.
    const deviceFieldOrder = await page.evaluate(() => Array.from(
      document.querySelectorAll('#usedDeviceBuyForm .used-form-section:first-of-type [name], #usedDeviceBuyForm .used-form-section:first-of-type #usedDeviceModelSearch')
    ).map(node => node.name || node.id));
    assert.deepEqual(deviceFieldOrder.slice(0, 4), ['category', 'usedDeviceModelSearch', 'brand', 'model'],
      `Unexpected device field order: ${deviceFieldOrder.join(', ')}`);
    assert.deepEqual(deviceFieldOrder.slice(-3), ['battery_health', 'imei', 'serial_number'],
      `Unexpected device field order: ${deviceFieldOrder.join(', ')}`);

    const tooFew = await page.evaluate(async () => {
      state.usedDeviceIntakeCounts = { intake: 0 };
      await submitUsedDevicePurchase(usedDeviceBuyFormEl());
      return usedDeviceBuyFormEl().querySelector('#usedDeviceBuyError').textContent;
    });
    assert.match(tooFew, /at least 1 intake photo/i, `Unexpected refusal: ${tooFew}`);

    // A blocked handset is refused outright, not merely kept off the shelf.
    const blocked = await page.evaluate(async () => {
      state.usedDeviceIntakeCounts = { intake: 1 };
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

    // Cash records nothing. A transfer has to say where the money went, and the
    // two ways of saying that ask for different things.
    const payout = await page.evaluate(() => {
      const form = usedDeviceBuyFormEl();
      const panel = form.querySelector('#usedDevicePayoutDetails');
      const hiddenForCash = panel.hidden;
      form.elements.payout_method.value = 'Bank Transfer';
      form.elements.payout_method.dispatchEvent(new Event('change', { bubbles: true }));
      const openForTransfer = !panel.hidden;
      const missing = usedDevicePayoutDetails(form).error;
      form.querySelector('[data-used-payout-type="Bank Account"]').click();
      const bankShown = !form.querySelector('[data-used-payout-field="Bank Account"]').hidden
        && form.querySelector('[data-used-payout-field="PayID"]').hidden;
      form.elements.payout_bsb.value = '12345';
      const shortBsb = usedDevicePayoutDetails(form).error;
      form.elements.payout_bsb.value = '123-456';
      form.elements.payout_account_number.value = '12345678';
      form.elements.payout_account_name.value = 'Test Seller';
      const bank = usedDevicePayoutDetails(form);
      form.querySelector('[data-used-payout-type="PayID"]').click();
      form.elements.payout_payid.value = 'seller@example.com';
      const payid = usedDevicePayoutDetails(form);
      form.elements.payout_method.value = 'Cash';
      form.elements.payout_method.dispatchEvent(new Event('change', { bubbles: true }));
      return { hiddenForCash, openForTransfer, missing, bankShown, shortBsb, bank, payid, closedAgain: panel.hidden };
    });
    assert.ok(payout.hiddenForCash, 'The payout destination panel was open for a cash payout');
    assert.ok(payout.openForTransfer, 'A bank transfer did not ask where the money went');
    assert.match(payout.missing, /PayID/i, `Unexpected payout refusal: ${payout.missing}`);
    assert.ok(payout.bankShown, 'The bank account fields did not replace the PayID field');
    assert.match(payout.shortBsb, /six digits/i, `Unexpected BSB refusal: ${payout.shortBsb}`);
    assert.deepEqual(payout.bank, {
      method: 'Bank Transfer', reference_type: 'Bank Account', payid: '',
      bsb: '123456', account_number: '12345678', account_name: 'Test Seller', error: ''
    });
    assert.equal(payout.payid.reference_type, 'PayID');
    assert.equal(payout.payid.payid, 'seller@example.com');
    assert.equal(payout.payid.error, '', `A valid PayID was refused: ${payout.payid.error}`);
    assert.ok(payout.closedAgain, 'The payout destination panel stayed open after switching back to cash');

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

    // Exercise the real form submit event, one photo, and the acquisition request.
    await page.evaluate(() => {
      const form = usedDeviceBuyFormEl();
      for (const [name, value] of Object.entries({seller_name:'Test Seller', seller_phone:'0400000000', seller_address:'1 Test Street', seller_id_type:'Passport', seller_id_reference:'TEST', purchase_cost:'300', clean_check_status:'Pending'})) form.elements[name].value = value;
      form.querySelectorAll('input[type="checkbox"][required]').forEach(input => input.checked = true);
      syncCurrentShiftWithDatabase = async () => ({id:'SHIFT-TEST', status:'open'});
      window.savedAcquisition = null;
      usedDeviceApiPost = async (action, payload) => { window.savedAcquisition = {action, payload}; return {ok:true}; };
    });
    await page.locator('[data-used-inspection="power"][value="pass"]').check();
    await page.locator('[data-used-inspection="touch"][value="fail"]').check();
    const preserved = await page.evaluate(() => {
      renderUsedDeviceView();
      refreshUsedDeviceCategoryFields();
      return {seller: usedDeviceBuyFormEl().elements.seller_name.value, inspection: collectUsedDeviceInspection(usedDeviceBuyFormEl(), 'buy')};
    });
    assert.equal(preserved.seller, 'Test Seller');
    assert.deepEqual(preserved.inspection, {power:'pass', touch:'fail'});
    assert.equal(await page.locator('#usedDeviceInspectionGrid select').count(), 0);
    await page.locator('#usedDeviceBuySubmit').click();
    await page.waitForFunction(() => window.savedAcquisition !== null);
    const saved = await page.evaluate(() => window.savedAcquisition);
    assert.equal(saved.action, 'acquire');
    assert.deepEqual(saved.payload.inspection, {power:'pass', touch:'fail'});
    assert.equal(saved.payload.status, 'inspection');
    assert.ok(saved.payload.intake_key);
    // A device arrives unpriced, and a failed check grades it faulty until
    // someone says otherwise.
    assert.equal(saved.payload.sale_price, 0, 'A purchase carried a sale price');
    assert.equal(saved.payload.condition_grade, 'Faulty', 'A failed check did not grade the device');
    assert.equal(saved.payload.payout_method, 'Cash');
    assert.equal(saved.payload.payout_reference_type, '', 'Cash recorded a payout destination');
    await page.waitForFunction(() => state.usedDeviceTab === 'inventory');

    // The device detail shows what it was bought as but cannot edit it, and
    // the pre-sale test is where sellability is decided.
    const detail = await page.evaluate(async () => {
      const device = {
        id: 'USED-DETAIL', device_code: 'USED-DETAIL', category: 'Phone', brand: 'Apple', model: 'iPhone 13',
        status: 'inspection', condition_grade: 'Good', intake_condition_grade: 'Faulty', battery_health: 90,
        intake_battery_health: 78, sale_price: 0, inspection: {touch: 'fail'}, seller: {}, acquisition: {buyback_number: 7}
      };
      state.usedDevices = [device];
      window.savedUpdate = null;
      usedDeviceApiPost = async (action, payload) => { window.savedUpdate = {action, payload}; return {ok: true}; };
      openUsedDeviceDetail('USED-DETAIL');
      const form = els.usedDeviceDetailBody.querySelector('#usedDeviceUpdateForm');
      await updateUsedDevice(form);
      return {
        editableChecks: els.usedDeviceDetailBody.querySelectorAll('[data-used-inspection-prefix="detail"]').length,
        testHost: Boolean(els.usedDeviceDetailBody.querySelector('#usedDeviceSaleTest')),
        summary: els.usedDeviceDetailBody.querySelector('.used-detail-summary').innerText,
        sentInspection: window.savedUpdate && Object.prototype.hasOwnProperty.call(window.savedUpdate.payload, 'inspection')
      };
    });
    assert.equal(detail.editableChecks, 0, 'The purchase inspection could still be edited from the device detail');
    assert.ok(detail.testHost, 'The pre-sale test was not mounted on the device detail');
    assert.match(detail.summary, /Faulty/, 'What the device was bought as was not shown');
    assert.equal(detail.sentInspection, false, 'A device save still sent an inspection');
    await page.evaluate(() => closeUsedDeviceDetail());

    await page.evaluate(async () => {
      els.usedDeviceDetailBody.innerHTML = '<div id="usedDeviceCostList"></div>';
      await loadUsedDeviceCosts({id:'USED-TEST'});
    });
    assert.match(await page.locator('#usedDeviceCostList').innerText(), /administrators only/);
    assert.deepEqual(errors, [], `Page errors: ${errors.join(', ')}`);
    console.log('PASS: draft photo deletion on the buy form, locked purchase inspection on the device detail with the pre-sale test mounted, device-first intake layout, unpriced purchase, payout destination rules, one-photo purchase submission, form preservation, direct inspection choices, cart price lock, zero-photo and blocked-device gates.');
  } finally {
    await browser.close();
    server.close();
  }
})();
