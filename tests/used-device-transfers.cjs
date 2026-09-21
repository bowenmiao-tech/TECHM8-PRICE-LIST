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
    const page = await browser.newPage({ viewport: { width: Number(process.env.TRANSFER_WIDTH || 1440), height: 1000 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));

    let sent = null, received = null;
    const photos = [];
    const stores = [{store_code:'toowong',store_name:'Toowong'},{store_code:'parkridge',store_name:'Park Ridge'}];
    const device = {id:'USED-TRANSFER-TEST', brand:'Apple',model:'iPhone 13',storage:'128GB',serial_number:'TEST-SERIAL',status:'inspection',store_code:'toowong'};
    const transfer = {transfer_code:'DTR-TEST',device_code:device.id,from_store_code:'toowong',from_store_name:'Toowong',to_store_code:'parkridge',to_store_name:'Park Ridge',status:'in_transit',device_snapshot:device};
    await page.route('https://**/*', async route => {
      const url=route.request().url();
      if(url.includes('/pos-used-device-updates')) {
        if(route.request().method()==='POST') {
          const data=route.request().postDataJSON();
          photos.push({...data,image_url:'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII='});
          return route.fulfill({json:{ok:true,id:data.id}});
        }
        return route.fulfill({json:{ok:true,uploads:photos}});
      }
      if(url.includes('/pos-used-devices')) {
        if(route.request().method()==='POST') {
          const data=route.request().postDataJSON();
          if(data.action==='transfer-send') sent=data;
          if(data.action==='transfer-receive') received=data;
          return route.fulfill({json:{ok:true}});
        }
        if(url.includes('resource=network')) return route.fulfill({json:{ok:true,devices:[device],stores}});
        if(url.includes('resource=transfers')) return route.fulfill({json:{ok:true,transfers:sent?[transfer]:[],summary:{}}});
        return route.fulfill({json:{ok:true,devices:[],checklists:{}}});
      }
      return route.abort();
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
    await page.evaluate(() => { window.Techm8StaffAuth.getToken=()=> 'test';state.storeId='toowong';state.selectedStaffName='Tester';setActiveView('used-devices');setUsedDeviceTab('transfers'); });
    await page.waitForFunction(()=>document.querySelector('#usedTransferSendForm [name="device_code"]')?.options.length>1);
    await page.selectOption('#usedTransferSendForm [name="device_code"]',device.id);
    await page.selectOption('#usedTransferSendForm [name="to_store_code"]','parkridge');
    await page.locator('#usedTransferSendForm button[type="submit"]').click();
    await page.waitForFunction(()=>document.body.textContent.includes('DTR-TEST'));
    assert.equal(sent.payload?.to_store_code || sent.to_store_code,'parkridge');
    await page.evaluate(()=>{state.storeId='parkridge';renderUsedDeviceView();});
    await page.locator('[data-used-receive="DTR-TEST"]').click();
    assert.equal(await page.locator('[data-receipt-confirm]').isDisabled(),true);
    assert.ok(await page.locator('#usedTransferReceiptDialog').evaluate(el => el.scrollWidth <= el.clientWidth + 1), 'Receipt dialog overflows horizontally');
    if (process.env.TRANSFER_SHOTS) { fs.mkdirSync(process.env.TRANSFER_SHOTS,{recursive:true}); await page.screenshot({path:path.join(process.env.TRANSFER_SHOTS,'receipt.png')}); }
    assert.equal(await page.locator('#usedTransferReceiptDialog [data-stage="seller_id"]').count(),0);
    await page.locator('#usedTransferReceiptDialog input[type=file]').setInputFiles({name:'receipt.png',mimeType:'image/png',buffer:await page.screenshot()});
    await page.waitForFunction(()=>!document.querySelector('[data-receipt-confirm]').disabled);
    await page.locator('[data-receipt-confirm]').click();
    await page.waitForFunction(()=>!document.querySelector('#usedTransferReceiptDialog'));
    assert.ok(received.payload?.receipt_intake_key || received.receipt_intake_key);
    assert.equal(photos.length,1);
    assert.deepEqual(errors,[]);
    console.log('PASS: transfers entry, destination selection, required photo upload and receipt confirmation');
  } finally {await browser.close();server.close();}
})();
