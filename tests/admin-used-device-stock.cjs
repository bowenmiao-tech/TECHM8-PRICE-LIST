// The admin Used Devices page: two lists (for sale, sold) with the store each
// device is in; a device opens on four pages (price and listing, pre-sale
// test, at purchase, history); the purchase inspection is read-only; a
// pre-sale test is recorded separately; a tested device is priced and put
// online. Every API is mocked; nothing here touches a real project.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const {chromium} = require('playwright');

const SIZES = [['desktop', 1440, 1000], ['ipad-landscape', 1024, 768], ['ipad-portrait', 768, 1024], ['phone', 390, 844]];

(async () => {
  const root = path.resolve(__dirname, '..');
  const shots = process.env.ADMIN_USED_SHOTS || '';
  if (shots) fs.mkdirSync(shots, {recursive: true});
  const server = http.createServer((request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      response.setHeader('Content-Type', pathname.endsWith('.js') ? 'application/javascript' : pathname.endsWith('.css') ? 'text/css' : 'text/html');
      response.end(fs.readFileSync(path.join(root, pathname)));
    } catch (_) {
      response.writeHead(404).end();
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));

  const staffAuthStub = `
    window.__rpcCalls = [];
    const checklist = [{key:'touch',label:'Touch working'},{key:'wireless_charging',label:'Wireless charging working'}];
    const base = {category:'Phone', condition_grade:'Good', website_status:'not_published', sale_price:0,
      ready_at:null, sold_at:null, sold_invoice_number:null, sold_amount:0, margin:null, status:'inspection'};
    const ready = Object.assign({}, base, {
      id:'USED-READY', device_code:'USED-READY', store_code:'toowong', store_name:'Toowong Village',
      brand:'Apple iPhone', model:'iPhone 13', storage:'128GB', color:'Midnight', battery_health:91,
      intake_battery_health:84, intake_condition_grade:'Fair', imei:'356938035643809', serial_number:'',
      purchase_cost:300, total_cost:340, buyback_number:12, acquired_at:'2026-09-10T01:00:00Z',
      listing_photo_count:2, intake_photo_count:3, days_held:8, blockers:[]
    });
    const untested = Object.assign({}, base, {
      id:'USED-UNTESTED', device_code:'USED-UNTESTED', store_code:'parkridge', store_name:'Park Ridge Town Centre',
      brand:'Apple iPhone', model:'iPhone 12 Pro Max', storage:'512GB', color:'', battery_health:78,
      intake_battery_health:78, intake_condition_grade:'Faulty', imei:'', serial_number:'SDFGSE4GSE4555',
      purchase_cost:5000, total_cost:5000, buyback_number:7, acquired_at:'2026-09-18T13:48:00Z',
      listing_photo_count:0, intake_photo_count:1, days_held:1,
      blockers:['No pre-sale test has been recorded yet','No listing photo has been added']
    });
    const sold = Object.assign({}, base, {
      id:'USED-SOLD', device_code:'USED-SOLD', store_code:'fairfield', store_name:'Fairfield Gardens',
      category:'Tablet', brand:'Apple iPad', model:'iPad Air 4', storage:'64GB', color:'Sky Blue',
      condition_grade:'As New', battery_health:95, intake_battery_health:95, intake_condition_grade:'Good',
      imei:'', serial_number:'DMPX1234', status:'sold', website_status:'withdrawn', sale_price:520,
      purchase_cost:300, total_cost:330, buyback_number:9, acquired_at:'2026-08-01T01:00:00Z',
      sold_at:'2026-09-01T03:00:00Z', sold_invoice_number:4120, sold_amount:520, margin:190,
      listing_photo_count:4, intake_photo_count:2, days_held:48, blockers:['This device has been sold']
    });
    window.__stock = {for_sale:[ready, untested], sold:[sold], closed:[]};
    window.__intake = {
      'USED-READY': {touch:'pass', wireless_charging:'fail'},
      'USED-UNTESTED': {touch:'fail', wireless_charging:'fail'},
      'USED-SOLD': {touch:'pass', wireless_charging:'na'}
    };
    window.__tests = {'USED-READY': [{id:'TEST-1', answers:{touch:'pass', wireless_charging:'pass'}, battery_health:91, notes:'', passed:true, failed_count:0, tested_by:'Bowen', tested_by_admin:false, tested_at:'2026-09-15T01:00:00Z'}]};
    window.__checklist = checklist;
    const find = code => [].concat(window.__stock.for_sale, window.__stock.sold).find(entry => entry.device_code === code);
    window.__findDevice = find;
    window.Techm8StaffAuth = {
      getToken: () => 'admin-test', init: async () => {}, logout: () => {},
      callRpc: async (name, params) => {
        window.__rpcCalls.push({name, params});
        if (name === 'get_admin_used_device_overview') {
          return {totals:{paid_out:5300,purchase_count:2,paid_out_cash:300,sold_revenue:520,sold_count:1,realized_margin:190,stock_cost:5340,in_stock:2,stock_retail:0,blocked_in_stock:0,missing_intake_evidence:0,aged_over_90:0,pending_checks:1},stores:[]};
        }
        if (name === 'get_admin_used_device_alerts') return {alerts:[],lookback_days:90};
        if (name === 'get_admin_used_device_reconciliation') return {rows:[]};
        if (name === 'get_admin_used_device_register') return {date_from:'2026-09-01',date_to:'2026-09-18',rows:[]};
        if (name === 'get_admin_used_device_stock') {
          const group = (params.payload || {}).group || 'for_sale';
          const store = (params.payload || {}).store_code || '';
          return {
            ok:true, group, devices: window.__stock[group].filter(device => !store || device.store_code === store),
            counts:{for_sale:2, sold:1, closed:0, live:0, unpriced:2, stock_cost:5340, stock_retail:0},
            stores:[{store_code:'parkridge',store_name:'Park Ridge Town Centre',count:1},{store_code:'toowong',store_name:'Toowong Village',count:1}]
          };
        }
        if (name === 'delete_admin_used_device') {
          if (window.__deleteFail) throw new Error('Deletion failed; please retry');
          for (const group of Object.keys(window.__stock)) window.__stock[group] = window.__stock[group].filter(device => device.device_code !== params.target_device_code);
          return {ok:true};
        }
        if (name === 'get_admin_used_device_detail') {
          const device = find(params.target_device_code);
          const intake = window.__intake[device.device_code];
          return {
            ok:true,
            device: Object.assign({refurb_cost:40, notes:'', clean_check_status:'Clean', clean_check_reference:'', activation_lock_removed:true, data_erased_confirmed:true, website_slug:'', acquired_by:'Bowen', updated_by:'Bowen'}, device),
            seller:{buyback_number:device.buyback_number, acquisition_code:'BUY-1', name:'Test Seller', phone:'0400000000', email:'', address:'1 Test Street', id_type:'Driver Licence', id_reference:'TEST-1', is_owner:true, owner_name:'', owner_address:'', acquisition_statement:'', payout_method:'Bank Transfer', payout_amount:device.purchase_cost, payout_reference_type:'PayID', payout_payid:'0400000000', payout_bsb:'', payout_account_number:'', payout_account_name:''},
            inspection: checklist.map(item => ({key:item.key, label:item.label, answer:intake[item.key] || '', retired:false})),
            costs:[{id:'c1',kind:'part',description:'Replacement battery',amount:40,repair_ticket_code:'',staff_name:'Bowen',created_at:'2026-09-12T01:00:00Z'}],
            transfers:[{transfer_code:'DTR-ADMIN-TEST',from_store_name:'Toowong',to_store_name:'Park Ridge',status:'received',sent_by:'Sender',received_by:'Receiver',sent_at:'2026-09-21T00:00:00Z',received_at:'2026-09-21T01:00:00Z',receipt_photo_ids:['receipt-1']}],
            ledger:[{type:'acquisition',amount:300,from_status:null,to_status:'inspection',staff_name:'Bowen',notes:'Device purchased from seller',created_at:'2026-09-10T01:00:00Z'}],
            photos:{intake:device.intake_photo_count, listing:device.listing_photo_count}
          };
        }
        if (name === 'save_admin_used_device_cost') {
          return {ok:true, id: params.payload.cost_id || 'new', amount: params.payload.amount, refurb_cost: Number(params.payload.amount || 0)};
        }
        if (name === 'set_admin_used_device_listing') {
          const device = find(params.payload.device_code);
          device.sale_price = params.payload.sale_price;
          if (params.payload.publish) { device.status = 'ready_for_sale'; device.website_status = 'queued'; }
          return {ok:true, device_code:device.device_code, store_code:device.store_code, status:device.status, sale_price:device.sale_price, website_status:device.website_status, published:params.payload.publish};
        }
        return {};
      }
    };
  `;

  const browser = await chromium.launch({channel: 'chrome', headless: true});
  try {
    for (const [label, width, height] of SIZES) {
      const page = await browser.newPage({viewport: {width, height}});
      const devicePhotos = [{id:'receipt-1',stage:'refurb',file_name:'Transfer DTR-ADMIN-TEST receipt'}, {id: 'photo-listing-1', stage: 'listing'}, {id: 'photo-listing-2', stage: 'listing'}, {id: 'photo-id-1', stage: 'seller_id'}];
      const photoRemovals = [];
      const pageErrors = [];
      page.on('pageerror', error => pageErrors.push(error.message));
      await page.route('**/staff-auth.js*', route => route.fulfill({contentType: 'application/javascript', body: staffAuthStub}));
      // The shared pre-sale test module talks to PostgREST directly.
      await page.route('https://**/rest/v1/rpc/**', async route => {
        const url = route.request().url();
        const body = route.request().postDataJSON() || {};
        const answer = await page.evaluate(({url, body}) => {
          window.__rpcCalls.push({name: url.split('/rpc/')[1], params: body});
          const device = window.__findDevice(body.target_device_code);
          const tests = window.__tests[device.device_code] || (window.__tests[device.device_code] = []);
          if (url.endsWith('/record_pos_used_device_sale_test')) {
            const answers = body.payload.answers || {};
            const failed = Object.values(answers).filter(value => value === 'fail').length;
            tests.unshift({id: `TEST-${tests.length + 2}`, answers, battery_health: body.payload.battery_health ? Number(body.payload.battery_health) : null,
              notes: body.payload.notes || '', passed: failed === 0, failed_count: failed, tested_by: 'Admin', tested_by_admin: true,
              tested_at: new Date().toISOString()});
            if (failed === 0) device.blockers = device.blockers.filter(item => !/pre-sale test/i.test(item));
            return {ok: true, test_code: tests[0].id, passed: failed === 0, failed_count: failed, withdrawn: false};
          }
          return {
            ok: true, device_code: device.device_code, category: device.category, status: device.status,
            checklist: window.__checklist,
            intake: {inspection: window.__intake[device.device_code], battery_health: device.intake_battery_health,
              condition_grade: device.intake_condition_grade, acquired_at: device.acquired_at, acquired_by: 'Bowen'},
            tests, passed: tests.length > 0 && tests[0].passed,
            writable: ['inspection', 'ready_for_sale'].includes(device.status)
          };
        }, {url, body});
        return route.fulfill({json: answer});
      });
      await page.route('https://**/*', route => {
        const url = route.request().url();
        if (url.includes('/rest/v1/rpc/')) return route.fallback();
        if (url.includes('/pos-used-device-publish')) return route.fulfill({json: {ok: true, results: [{ok: true}]}});
        if (url.includes('/pos-used-device-updates')) {
          if (route.request().method() === 'POST') {
            const body = route.request().postDataJSON();
            photoRemovals.push(body);
            const index = devicePhotos.findIndex(entry => entry.id === body.id);
            if (index >= 0) devicePhotos.splice(index, 1);
            return route.fulfill({json: {ok: true, id: body.id}});
          }
          return route.fulfill({json: {ok: true, writable: true, is_admin: true, updates: devicePhotos.map(entry => ({
            ...entry, kind: 'photo', image_url: 'https://example.test/photo.jpg', author: 'Bowen', created_at: '2026-09-21T01:20:54Z'
          }))}});
        }
        return route.abort();
      });

      await page.goto(`http://127.0.0.1:${server.address().port}/admin.html#used-devices`);

      // Two lists, both counted, with the store each device is sitting in.
      await page.locator('#usedStockBody .used-device-row').first().waitFor();
      assert.equal(await page.locator('#usedCountForSale').innerText(), '2', 'The for-sale count was wrong');
      assert.equal(await page.locator('#usedCountSold').innerText(), '1', 'The sold count was wrong');
      assert.ok(await page.locator('#usedClosedTab').isHidden(), 'The closed tab showed with nothing in it');
      const forSaleText = await page.locator('#usedStockBody').innerText();
      assert.match(forSaleText, /Toowong Village/, 'The store was not shown against a device');
      assert.match(forSaleText, /Park Ridge Town Centre/, 'The second store was not shown');
      assert.match(forSaleText, /Not priced/, 'An unpriced device did not say so');
      if (shots) await page.locator('#usedStockBody').screenshot({path: path.join(shots, `admin-list-${label}.png`)});

      await page.locator('[data-used-group="sold"]').click();
      await page.waitForFunction(() => document.querySelector('#usedStockBody').innerText.includes('iPad Air 4'));
      const soldText = await page.locator('#usedStockBody').innerText();
      assert.match(soldText, /Fairfield Gardens/, 'The sold list lost the store');
      assert.match(soldText, /#4120/, 'The sold list lost the invoice');
      assert.match(soldText, /\$190\.00/, 'The sold list lost the margin');
      await page.locator('[data-used-group="for_sale"]').click();

      // An untested device: cannot go online, and the reason leads to the test.
      await page.locator('[data-used-device="USED-UNTESTED"]').waitFor();
      await page.locator('[data-used-device="USED-UNTESTED"]').click();
      await page.locator('#usedListingPublish').waitFor();
      assert.ok(await page.locator('#usedListingPublish').isDisabled(), 'An untested device could still be published');
      assert.match(await page.locator('[data-used-detail-panel="listing"]').innerText(), /No pre-sale test has been recorded yet/);
      if (shots) await page.screenshot({path: path.join(shots, `admin-listing-${label}.png`)});

      // What it was bought as is shown read-only, and says it is locked.
      await page.locator('.used-detail-tabs [data-used-detail-tab="purchase"]').click();
      const purchaseText = await page.locator('[data-used-detail-panel="purchase"]').innerText();
      assert.match(purchaseText, /Locked/, 'The purchase inspection did not say it was locked');
      assert.match(purchaseText, /Faulty/, 'The purchase-time condition was not shown');
      assert.equal(await page.locator('[data-used-detail-panel="purchase"] input, [data-used-detail-panel="purchase"] select').count(), 0,
        'The purchase inspection offered something to edit');
      if (shots) await page.screenshot({path: path.join(shots, `admin-purchase-${label}.png`)});

      // Staff record the repair; the admin prices it here.
      await page.locator('.used-detail-tabs [data-used-detail-tab="history"]').click();
      await page.locator('#usedDeviceTransferPhotos .ude-photo').waitFor();
      assert.match(await page.locator('#usedDeviceDialogBody').innerText(), /Toowong → Park Ridge/);
      assert.equal(await page.locator('#usedDeviceTransferPhotos .ude-photo').count(), 1);
      assert.equal(await page.locator('#usedDeviceTransferPhotos [data-remove]').count(), 0);
      assert.match(await page.locator('#usedDeviceTransferPhotos').innerText(), /DTR-ADMIN-TEST/);
      await page.locator('[data-used-cost-amount="c1"]').fill('55');
      await page.locator('[data-used-cost-save="c1"]').click();
      await page.waitForFunction(() => window.__rpcCalls.some(call => call.name === 'save_admin_used_device_cost'));
      const priced = await page.evaluate(() => window.__rpcCalls.filter(call => call.name === 'save_admin_used_device_cost').pop());
      assert.equal(priced.params.payload.cost_id, 'c1');
      assert.equal(priced.params.payload.amount, '55');
      await page.locator('.used-detail-tabs [data-used-detail-tab="history"]').waitFor();
      await page.locator('[data-used-cost-new="description"]').fill('Replaced the charging port');
      await page.locator('[data-used-cost-new="amount"]').fill('35');
      await page.locator('[data-used-cost-add]').click();
      await page.waitForFunction(() => window.__rpcCalls.filter(call => call.name === 'save_admin_used_device_cost').length === 2);
      const added = await page.evaluate(() => window.__rpcCalls.filter(call => call.name === 'save_admin_used_device_cost').pop());
      assert.equal(added.params.payload.device_code, 'USED-UNTESTED');
      assert.equal(added.params.payload.description, 'Replaced the charging port');
      assert.equal(added.params.payload.amount, '35');

      // Photos taken by mistake can be removed from every tab, seller ID included.
      await page.locator('.used-detail-tabs [data-used-detail-tab="history"]').click();
      await page.locator('#usedDeviceDialogEvidence [data-stage="listing"]').click();
      await page.waitForFunction(() => document.querySelectorAll('#usedDeviceDialogEvidence .ude-remove').length === 2);
      if (shots) await page.locator('#usedDeviceDialogEvidence').screenshot({path: path.join(shots, `admin-photos-${label}.png`)});
      await page.locator('#usedDeviceDialogEvidence [data-stage="seller_id"]').click();
      await page.locator('#usedDeviceDialogEvidence .ude-remove').waitFor();
      await page.evaluate(() => { window.confirm = () => true; });
      await page.locator('#usedDeviceDialogEvidence .ude-remove').click();
      await page.waitForFunction(() => /Photo removed/.test(document.querySelector('#usedDeviceDialogEvidence .ude-status').textContent));
      assert.equal(photoRemovals.length, 1, 'Removing a photo sent nothing');
      assert.equal(photoRemovals[0].action, 'remove');
      assert.equal(photoRemovals[0].id, 'photo-id-1');
      assert.equal(photoRemovals[0].device_code, 'USED-UNTESTED');
      assert.equal(photoRemovals[0].store_code, 'parkridge', 'The removal was sent for the wrong store');
      assert.equal(await page.locator('#usedDeviceDialogEvidence .ude-photo').count(), 0, 'The removed ID photo is still shown');

      // The pre-sale test: an incomplete run is refused, a complete one saved.
      await page.locator('[data-used-detail-panel="listing"] [data-used-detail-tab="test"]').count();
      await page.locator('.used-detail-tabs [data-used-detail-tab="test"]').click();
      await page.locator('#usedDeviceDialogSaleTest .udt-save').waitFor();
      assert.equal(await page.locator('#usedDeviceDialogSaleTest .udt-intake').count(), 0,
        'The test page repeated the purchase record');
      await page.locator('#usedDeviceDialogSaleTest .udt-save').click();
      assert.match(await page.locator('#usedDeviceDialogSaleTest .udt-message').innerText(), /2 checks are still to answer/);
      for (const key of ['touch', 'wireless_charging']) {
        await page.locator(`#usedDeviceDialogSaleTest input[data-udt-key="${key}"][value="pass"]`).check({force: true});
      }
      await page.locator('#usedDeviceDialogSaleTest [data-udt-battery]').fill('100');
      await page.locator('#usedDeviceDialogSaleTest [data-udt-notes]').fill('New battery fitted');
      if (shots) await page.screenshot({path: path.join(shots, `admin-test-${label}.png`)});
      await page.locator('#usedDeviceDialogSaleTest .udt-save').click();
      await page.waitForFunction(() => window.__rpcCalls.some(call => call.name === 'record_pos_used_device_sale_test'));
      const testCall = await page.evaluate(() => window.__rpcCalls.find(call => call.name === 'record_pos_used_device_sale_test'));
      assert.deepEqual(testCall.params.payload.answers, {touch: 'pass', wireless_charging: 'pass'});
      assert.equal(testCall.params.payload.battery_health, '100');
      assert.equal(testCall.params.target_store_code, 'parkridge', 'The test was sent for the wrong store');
      await page.waitForFunction(() => /passed/i.test(document.querySelector('#usedDeviceDialogSaleTest .udt-message')?.textContent || ''));
      // The listing page no longer asks for a test, and the purchase record is untouched.
      await page.waitForFunction(() => !document.querySelector('[data-used-detail-panel="listing"]').innerText.includes('No pre-sale test'));
      assert.equal(await page.evaluate(() => window.__intake['USED-UNTESTED'].touch), 'fail', 'The purchase record changed');
      assert.ok(!(await page.locator('[data-used-detail-panel="test"]').isHidden()), 'Saving a test jumped away from the test page');
      await page.locator('#usedDeviceDialogClose').click();

      // A tested device: price it, see the margin, confirm, and it goes live.
      await page.locator('[data-used-device="USED-READY"]').click();
      await page.locator('#usedListingPrice').waitFor();
      assert.ok(!(await page.locator('#usedListingPublish').isDisabled()), 'A ready device could not be published');
      await page.locator('#usedListingPrice').fill('649');
      await page.waitForFunction(() => document.querySelector('#usedListingMargin').textContent.includes('Margin'));
      assert.match(await page.locator('#usedListingMargin').innerText(), /Margin \$309\.00/, 'The margin preview was wrong');
      await page.locator('#usedListingPublish').click();
      await page.waitForFunction(() => window.__rpcCalls.some(call => call.name === 'set_admin_used_device_listing'));
      const listingCall = await page.evaluate(() => window.__rpcCalls.find(call => call.name === 'set_admin_used_device_listing'));
      assert.equal(listingCall.params.payload.device_code, 'USED-READY');
      assert.equal(listingCall.params.payload.sale_price, 649);
      assert.equal(listingCall.params.payload.publish, true, 'Confirm did not ask to publish');
      await page.waitForFunction(() => document.querySelector('#usedStockBody').innerText.includes('$649.00'));
      assert.match(await page.locator('#usedStockBody').innerText(), /Going online|Live on the site/);

      // Cancelling sends nothing. An error keeps the record open; retry removes it.
      await page.evaluate(() => { window.confirm = () => false; });
      await page.locator('#usedDeviceDelete').click();
      assert.equal(await page.evaluate(() => window.__rpcCalls.filter(c => c.name === 'delete_admin_used_device').length), 0);
      await page.evaluate(() => { window.confirm = () => true; window.__deleteFail = true; });
      await page.locator('#usedDeviceDelete').click();
      await page.waitForFunction(() => document.querySelector('#usedDeviceDeleteStatus').textContent.includes('Deletion failed'));
      assert.equal(await page.locator('#usedDeviceDelete').isEnabled(), true);
      await page.evaluate(() => { window.__deleteFail = false; });
      await page.locator('#usedDeviceDelete').click();
      await page.waitForFunction(() => !document.querySelector('#usedDeviceDialog').open);
      const deletion = await page.evaluate(() => window.__rpcCalls.find(c => c.name === 'delete_admin_used_device'));
      assert.equal(deletion.params.target_device_code, 'USED-READY');
      assert.equal(deletion.params.confirmation_code, 'USED-READY');
      assert.equal(await page.locator('#usedStockBody').innerText().then(text => text.includes('iPhone 13')), false);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      assert.ok(overflow <= 0, `${label}: the page scrolls sideways by ${overflow}px`);
      assert.deepEqual(pageErrors, [], `${label} page errors: ${pageErrors.join(', ')}`);
      await page.close();
    }
    console.log('PASS: for-sale and sold lists with stores; four-page device detail; admin-only repair pricing; photo removal including seller ID; locked purchase record; incomplete test refused; complete test recorded without touching the purchase record; priced approval and website push; desktop, iPad and phone.');
  } finally {
    await browser.close();
    server.close();
  }
})();
