import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

const html = fs.readFileSync('pos.html', 'utf8');
for (const script of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) {
  if (script[1].trim()) new vm.Script(script[1]);
}
function source(name) {
  const match = new RegExp('    (?:async )?function ' + name + '\\(').exec(html);
  assert.ok(match, name);
  const start = match.index;
  const next = /\n    (?:async )?function |\n    const warrantyClaimRequests/.exec(html.slice(start + match[0].length));
  return html.slice(start, start + match[0].length + next.index);
}
const browser = await chromium.launch({ headless: true, channel: process.env.PLAYWRIGHT_CHANNEL || 'msedge' });
try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 950 } });
  page.on('pageerror', error => { throw error; });
  await page.route('https://warranty.test/', route => route.fulfill({contentType:'text/html',body:'<!doctype html><html><body></body></html>'}));
  await page.goto('https://warranty.test/');
  const styles = [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/gi)][0][1];
  await page.setContent('<style>' + styles + '</style><main id="details" class="receipt-invoice-details" style="padding:24px;max-width:1040px;margin:auto"></main>');
  await page.addScriptTag({ content: `
    const state = { invoiceOrders: [] };
    const els = { receiptInvoiceDetails: document.getElementById('details'), receiptCompleteModal: { classList: { contains: () => true } } };
    const POS_SALES_ORDERS_ENDPOINT = 'https://example.test/orders';
    const warrantyClaimRequests = new Map();
    const posOrderApiHeaders = () => ({});
    const showToast = text => window.lastToast = text;
    const orderBalanceDue = () => 0;
    const money = value => '$' + Number(value).toFixed(2);
    const numberValue = value => Number(value) || 0;
    const escapeHtml = value => String(value ?? '').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
    const invoiceRepairRecordsHtml = () => '';
    ${['formatDateTime','usefulLegacyValue','invoiceDetailField','invoiceWarrantyButtonHtml','invoiceWarrantyHistoryHtml','claimInvoiceWarranty','invoiceDetailsHtml','parsePosApiResponse'].map(source).join('\n')}
    const order = { id: 'TEST-3137', store_db_code: 'toowong', customer_name: 'Test Customer', staff_name: 'Test Staff', created_at: '2026-06-30T00:11:00Z', items: [
      { line_id: 4153, name: 'Samsung 9H Polmernano screen Protector (One Time Free Replacement in 12 Months)', sku: '605655', qty: 1, unit_price:60, warranty: { eligible:true, can_claim:true, duration:'12 Months', expires_on:'2027-06-30', one_time:true, remaining:1, claims:[] } },
      { line_id: 4154, name:'S25 Plus Hanman case mint', qty:1, unit_price:39, warranty: { eligible:true, can_claim:true, duration:'6 Months', expires_on:'2026-12-30', claims:[] } },
      { line_id: 4155, name:'Expired accessory', qty:1, unit_price:20, warranty:{eligible:true,can_claim:false,reason:'Warranty expired',claims:[]} },
      { line_id: 4156, name:'No warranty item', qty:1, unit_price:5 }
    ] };
    state.lastCompletedOrder = order;
    state.invoiceOrders = [order];
    els.receiptInvoiceDetails.innerHTML = invoiceDetailsHtml(order);
    document.addEventListener('click', event => {
      const button = event.target.closest('[data-warranty-line]');
      if (button) claimInvoiceWarranty(button.dataset.warrantyLine,button);
    });
    let requests = [];
    let attempt = 0;
    window.fetch = async (url, options) => {
      requests.push(JSON.parse(options.body));
      if (++attempt === 1) throw new Error('Simulated network failure');
      await new Promise(resolve => setTimeout(resolve, 60));
      const saved = structuredClone(order);
      Object.assign(saved.items[0].warranty,{can_claim:false,remaining:0,reason:'Free replacement claimed',claims:[{id:'test',claimed_at:'2026-09-08T08:50:00Z',staff_name:'Test Staff'}]});
      return {ok:true,json:async()=>({ok:true,order:saved})};
    };
    window.testState = () => ({requests,order});
  `});
  assert.equal(await page.locator('[data-warranty-line]').count(),3);
  assert.equal(await page.locator('[data-warranty-line="4155"]').isDisabled(),true);
  await page.locator('[data-warranty-line="4153"]').click();
  await page.getByRole('button',{name:'Retry claim'}).waitFor();
  await page.getByRole('button',{name:'Retry claim'}).click();
  await page.getByRole('button',{name:'Free replacement claimed'}).waitFor();
  const state = await page.evaluate(() => window.testState());
  assert.equal(state.requests.length,2);
  assert.equal(state.requests[0].request_id,state.requests[1].request_id);
  assert.equal(state.order.items[0].warranty.claims.length,1);
  assert.ok(await page.getByText('Claimed 08/09/2026, 06:50 pm · Test Staff · Brisbane time').count());
  fs.mkdirSync('.codex-temp/warranty-tests',{recursive:true});
  await page.screenshot({path:'.codex-temp/warranty-tests/desktop.png',fullPage:true});
  await page.setViewportSize({width:390,height:844});
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
  await page.screenshot({path:'.codex-temp/warranty-tests/mobile.png',fullPage:true});
  console.log('PASS: script syntax, eligible/expired/no-warranty controls, network retry UUID reuse, saved history/date, disabled one-time claim, mobile overflow.');
} finally {
  await browser.close();
}
