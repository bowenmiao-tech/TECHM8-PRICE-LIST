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
        window.__drilldownCalls = [];
        const sale = {event_type:'sale',event_key:'sale:1',transaction_at:'2026-09-16T01:00:00Z',store_code:'toowong',store_name:'Toowong',invoice_number:4001,order_code:'POS-1',customer_name:'Jane',customer_phone:'0400000000',staff_name:'Fiona',payment_method:'Card',payment_status:'paid',amount:406,ticket_codes:'',items:[{line_id:1,category:'product',name:'USB-C Cable',sku:'CABLE-1',quantity:2,unit_price:35,amount:70,ticket_code:'',note:''},{line_id:2,category:'product',name:'Phone Case',sku:'CASE-1',quantity:1,unit_price:336,amount:336,ticket_code:'',note:'Blue'}]};
        const refund = {event_type:'refund',event_key:'refund:1',transaction_at:'2026-09-16T02:00:00Z',store_code:'toowong',store_name:'Toowong',invoice_number:4000,order_code:'POS-0',refund_code:'RFD-1',reason:'Returned two cables',customer_name:'Walk-in Customer',customer_phone:'',staff_name:'Fiona',payment_method:'Card',payment_status:'paid',amount:-64,ticket_codes:'',items:[{line_id:3,category:'product',name:'USB-C Cable',sku:'CABLE-2',quantity:1,unit_price:35,amount:-35,ticket_code:'',note:''},{line_id:4,category:'product',name:'USB-C Cable',sku:'CABLE-3',quantity:1,unit_price:29,amount:-29,ticket_code:'',note:''}]};
        const more = {event_type:'sale',event_key:'sale:2',transaction_at:'2026-09-15T01:00:00Z',store_code:'toowong',store_name:'Toowong',invoice_number:3999,order_code:'POS-2',customer_name:'Alex',customer_phone:'',staff_name:'Bowen',payment_method:'Cash',payment_status:'paid',amount:20,ticket_codes:'',items:[{line_id:5,category:'product',name:'Adapter',sku:'ADAPTER',quantity:1,unit_price:20,amount:20,ticket_code:'',note:''}]};
        window.Techm8StaffAuth = {
          getToken: () => 'admin-test', init: async () => {}, logout: () => {},
          callRpc: async (name, params) => {
            if (name === 'get_admin_sales_overview') return {date_from:'2026-09-16',date_to:'2026-09-16',totals:{net_sales:730,payments_received:771,mis:0,invoice_count:14,refund_count:1,refunds:64,products:482,repairs:248,other:0,gst:66.36},stores:[{store_code:'toowong',store_name:'Toowong',net_sales:441,payments_received:482,invoice_count:11,average_sale:40.09,refunds:64,repairs:99,mis:0,products:342,other:0}]};
            if (name === 'get_admin_sales_drilldown') {
              window.__drilldownCalls.push(params);
              if (params.page_offset > 0) return {date_from:params.date_from,date_to:params.date_to,store_name:'Toowong',category:'product',summary:{sales:426,refunds:64,net:362,transaction_count:3},rows:[more],has_more:false};
              return {date_from:params.date_from,date_to:params.date_to,store_name:'Toowong',category:'product',summary:{sales:406,refunds:64,net:342,transaction_count:2},rows:[refund,sale],has_more:true};
            }
            return {summary:{},stores:[],tickets:[]};
          }
        };
      `
    }));
    await page.route('https://**/*', route => route.abort());
    await page.goto(`http://127.0.0.1:${server.address().port}/admin.html#sales`);

    const productButton = page.locator('[data-sales-store-code="toowong"][data-sales-category="product"]').first();
    await productButton.waitFor();
    await productButton.click();
    await page.locator('#salesDrilldown.show').waitFor();
    await page.getByText('Toowong · Products').waitFor();
    assert.equal(await page.locator('#salesDrilldownSummary').getByText('$342.00').count(), 1, 'Net product amount was not shown');
    assert.equal(await page.locator('[data-sales-event]').count(), 2, 'Sale and refund transactions were not listed');
    assert.equal(await page.locator('.sales-event-badge.refund').count(), 1, 'Refund was not identified');

    await page.locator('[data-sales-event="refund:1"]').click();
    assert((await page.locator('#salesDrilldownBody').innerText()).includes('Returned two cables'));
    assert((await page.locator('#salesDrilldownBody').innerText()).includes('CABLE-2'));

    await page.locator('#salesDrilldownMore').click();
    await page.waitForFunction(() => window.__drilldownCalls.some(call => call.page_offset === 2));
    assert.equal(await page.locator('[data-sales-event]').count(), 3, 'Load more did not append a transaction');

    await page.locator('#salesDrilldownSearch').fill('cable');
    await page.waitForFunction(() => window.__drilldownCalls.some(call => call.search_query === 'cable'));
    const calls = await page.evaluate(() => window.__drilldownCalls);
    assert.equal(calls[0].target_store_code, 'toowong');
    assert.equal(calls[0].target_category, 'product');
    assert.equal(calls[0].page_limit, 50);

    const screenshotDir = path.join(root, '.codex-temp', 'test-screenshots');
    fs.mkdirSync(screenshotDir, {recursive: true});
    await page.screenshot({path: path.join(screenshotDir, 'admin-sales-drilldown-desktop.png'), fullPage: true});
    await page.setViewportSize({width: 390, height: 844});
    assert.equal(await page.locator('.sales-drilldown-panel').evaluate(el => Math.round(el.getBoundingClientRect().width)), 390);
    await page.screenshot({path: path.join(screenshotDir, 'admin-sales-drilldown-mobile.png'), fullPage: true});
    assert.equal(pageErrors.length, 0, pageErrors.join('\n'));
    console.log('PASS: admin category drill-down, exact net summary, refunds, item expansion, search, pagination and mobile drawer.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
