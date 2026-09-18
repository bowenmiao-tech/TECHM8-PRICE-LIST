// The admin Used Devices page: two lists (for sale, sold), the store each
// device is in, the drill-down, and pricing a device and putting it online.
// Every API is mocked; nothing here touches a real project.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const {chromium} = require('playwright');

(async () => {
  const root = path.resolve(__dirname, '..');
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

  const browser = await chromium.launch({channel: 'chrome', headless: true});
  try {
    const page = await browser.newPage({viewport: {width: 1440, height: 1000}});
    const pageErrors = [];
    page.on('pageerror', error => pageErrors.push(error.message));

    await page.route('**/staff-auth.js*', route => route.fulfill({
      contentType: 'application/javascript',
      body: `
        window.__rpcCalls = [];
        const ready = {
          id:'USED-READY', device_code:'USED-READY', store_code:'toowong', store_name:'Toowong Village',
          category:'Phone', brand:'Apple iPhone', model:'iPhone 13', storage:'128GB', color:'Midnight',
          condition_grade:'Good', battery_health:91, imei:'356938035643809', serial_number:'',
          status:'inspection', website_status:'not_published', sale_price:0, purchase_cost:300,
          total_cost:340, buyback_number:12, acquired_at:'2026-09-10T01:00:00Z', ready_at:null,
          sold_at:null, sold_invoice_number:null, sold_amount:0, margin:null,
          listing_photo_count:2, intake_photo_count:3, days_held:8, blockers:[]
        };
        const blocked = {
          id:'USED-BLOCKED', device_code:'USED-BLOCKED', store_code:'parkridge', store_name:'Park Ridge Town Centre',
          category:'Phone', brand:'Samsung', model:'Galaxy S23', storage:'256GB', color:'',
          condition_grade:'Good', battery_health:88, imei:'', serial_number:'RZ8W10ABCD',
          status:'inspection', website_status:'not_published', sale_price:0, purchase_cost:420,
          total_cost:420, buyback_number:13, acquired_at:'2026-09-14T01:00:00Z', ready_at:null,
          sold_at:null, sold_invoice_number:null, sold_amount:0, margin:null,
          listing_photo_count:0, intake_photo_count:1, days_held:4,
          blockers:['2 inspection checks still to pass','No listing photo has been added']
        };
        const sold = {
          id:'USED-SOLD', device_code:'USED-SOLD', store_code:'fairfield', store_name:'Fairfield Gardens',
          category:'Tablet', brand:'Apple iPad', model:'iPad Air 4', storage:'64GB', color:'Sky Blue',
          condition_grade:'As New', battery_health:95, imei:'', serial_number:'DMPX1234',
          status:'sold', website_status:'withdrawn', sale_price:520, purchase_cost:300,
          total_cost:330, buyback_number:9, acquired_at:'2026-08-01T01:00:00Z', ready_at:'2026-08-03T01:00:00Z',
          sold_at:'2026-09-01T03:00:00Z', sold_invoice_number:4120, sold_amount:520, margin:190,
          listing_photo_count:4, intake_photo_count:2, days_held:48, blockers:['This device has been sold']
        };
        window.__stock = {
          for_sale: [ready, blocked],
          sold: [sold],
          closed: []
        };
        window.Techm8StaffAuth = {
          getToken: () => 'admin-test', init: async () => {}, logout: () => {},
          callRpc: async (name, params) => {
            window.__rpcCalls.push({name, params});
            if (name === 'get_admin_used_device_overview') {
              return {totals:{paid_out:720,purchase_count:2,paid_out_cash:300,sold_revenue:520,sold_count:1,realized_margin:190,stock_cost:760,in_stock:2,stock_retail:0,blocked_in_stock:0,missing_intake_evidence:0,aged_over_90:0,pending_checks:1},stores:[]};
            }
            if (name === 'get_admin_used_device_alerts') return {alerts:[],lookback_days:90};
            if (name === 'get_admin_used_device_reconciliation') return {rows:[]};
            if (name === 'get_admin_used_device_register') return {date_from:'2026-09-01',date_to:'2026-09-18',rows:[]};
            if (name === 'get_admin_used_device_stock') {
              const group = (params.payload || {}).group || 'for_sale';
              const store = (params.payload || {}).store_code || '';
              const devices = window.__stock[group].filter(device => !store || device.store_code === store);
              return {
                ok:true, group, devices,
                counts:{for_sale:2, sold:1, closed:0, live:0, unpriced:2, stock_cost:760, stock_retail:0},
                stores:[{store_code:'parkridge',store_name:'Park Ridge Town Centre',count:1},{store_code:'toowong',store_name:'Toowong Village',count:1}]
              };
            }
            if (name === 'get_admin_used_device_detail') {
              const device = [].concat(window.__stock.for_sale, window.__stock.sold)
                .find(entry => entry.device_code === params.target_device_code);
              return {
                ok:true,
                device: Object.assign({refurb_cost:40, notes:'Small scuff on the corner', clean_check_status:'Clean', clean_check_reference:'AMTA-1', activation_lock_removed:true, data_erased_confirmed:true, website_slug:'', acquired_by:'Bowen', updated_by:'Bowen'}, device),
                seller:{buyback_number:device.buyback_number, acquisition_code:'BUY-1', name:'Test Seller', phone:'0400000000', email:'', address:'1 Test Street', id_type:'Driver Licence', id_reference:'TEST-1', is_owner:true, owner_name:'', owner_address:'', acquisition_statement:'', payout_method:'Bank Transfer', payout_amount:device.purchase_cost, payout_reference_type:'PayID', payout_payid:'0400000000', payout_bsb:'', payout_account_number:'', payout_account_name:''},
                inspection:[{key:'touch',label:'Touch working',answer:'pass',retired:false},{key:'wireless_charging',label:'Wireless charging working',answer:device.device_code === 'USED-BLOCKED' ? '' : 'pass',retired:false}],
                costs:[{id:'c1',kind:'part',description:'Replacement battery',amount:40,repair_ticket_code:'',staff_name:'Bowen',created_at:'2026-09-12T01:00:00Z'}],
                ledger:[{type:'acquisition',amount:300,from_status:null,to_status:'inspection',staff_name:'Bowen',notes:'Device purchased from seller',created_at:'2026-09-10T01:00:00Z'}],
                photos:{intake:device.intake_photo_count, listing:device.listing_photo_count}
              };
            }
            if (name === 'set_admin_used_device_listing') {
              const device = window.__stock.for_sale.find(entry => entry.device_code === params.payload.device_code);
              device.sale_price = params.payload.sale_price;
              if (params.payload.publish) {
                device.status = 'ready_for_sale';
                device.website_status = 'queued';
              }
              return {ok:true, device_code:device.device_code, store_code:device.store_code, status:device.status, sale_price:device.sale_price, website_status:device.website_status, published:params.payload.publish};
            }
            return {};
          }
        };
      `
    }));
    await page.route('https://**/*', route => {
      const url = route.request().url();
      if (url.includes('/pos-used-device-publish')) {
        return route.fulfill({json: {ok: true, device_code: 'USED-READY', results: [{ok: true}]}});
      }
      if (url.includes('/pos-used-device-updates')) {
        return route.fulfill({json: {ok: true, uploads: []}});
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

    await page.locator('[data-used-group="sold"]').click();
    await page.waitForFunction(() => document.querySelector('#usedStockBody').innerText.includes('iPad Air 4'));
    const soldText = await page.locator('#usedStockBody').innerText();
    assert.match(soldText, /Fairfield Gardens/, 'The sold list lost the store');
    assert.match(soldText, /#4120/, 'The sold list lost the invoice');
    assert.match(soldText, /\$190\.00/, 'The sold list lost the margin');

    // A device that is not ready cannot be put online, and says why.
    await page.locator('[data-used-group="for_sale"]').click();
    await page.locator('[data-used-device="USED-BLOCKED"]').waitFor();
    await page.locator('[data-used-device="USED-BLOCKED"]').click();
    await page.locator('#usedListingPublish').waitFor();
    assert.ok(await page.locator('#usedListingPublish').isDisabled(), 'A blocked device could still be published');
    const blockedText = await page.locator('#usedDeviceDialogBody').innerText();
    assert.match(blockedText, /No listing photo has been added/, 'The blockers were not shown');
    assert.match(blockedText, /Test Seller/, 'The seller was not shown in the detail');
    assert.match(blockedText, /Wireless charging working/, 'The checklist was not shown in the detail');
    assert.match(blockedText, /Replacement battery/, 'Refurbishment costs were not shown');
    await page.locator('#usedDeviceDialogClose').click();

    // The ready one: price it, see the margin, confirm, and it goes live.
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
    assert.match(await page.locator('#usedStockBody').innerText(), /Going online|Live on the site/,
      'The list did not show the device going online');

    // Saving a price without publishing leaves the device where it is.
    await page.locator('#usedStockSearch').fill('galaxy');
    await page.waitForFunction(() => window.__rpcCalls.some(call =>
      call.name === 'get_admin_used_device_stock' && (call.params.payload || {}).q === 'galaxy'));

    assert.deepEqual(pageErrors, [], `Page errors: ${pageErrors.join(', ')}`);
    console.log('PASS: for-sale and sold lists with stores, drill-down detail, blocked publish, priced approval and website push, search.');
  } finally {
    await browser.close();
    server.close();
  }
})();
