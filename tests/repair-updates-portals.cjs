const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const assert = require('node:assert/strict');
const {chromium} = require('playwright');
(async () => {
  const root=path.resolve(__dirname,'..');
  const server=http.createServer((req,res)=>{
    const name=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
    try {res.setHeader('Content-Type',name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(path.join(root,name)));}
    catch {res.writeHead(404).end();}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const browser=await chromium.launch({channel:'chrome',headless:true});
  try {
    const context=await browser.newContext({viewport:{width:1440,height:1000}});
    const entries=[];
    await context.route('https://**/*',async route=>{
      if (!route.request().url().includes('/pos-repair-updates')) return route.abort();
      if(route.request().method()==='POST') {const data=route.request().postDataJSON();entries.push({...data,author:'Bowen',created_at:new Date().toISOString()});return route.fulfill({json:{ok:true}});}
      return route.fulfill({json:{ok:true,writable:true,updates:entries}});
    });
    const url=`http://127.0.0.1:${server.address().port}`;
    const page=await context.newPage(); const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto(url+'/pos.html?dashboard-test');
    await page.evaluate(()=>{
      window.Techm8StaffAuth.getToken=()=> 'test-session';
      state.storeId='toowong';
      state.repairTickets=[normalizeRepairTicket({id:'TEST-PORTAL',store_id:'toowong',title:'Battery repair',issue:'Battery replacement',price:'99',status:'repairing',active:true,customerName:'Test Customer',customerPhone:'0400000000',activity:[]})];
      openTicketDetailModal('TEST-PORTAL');
    });
    await page.waitForFunction(()=>!document.querySelector('#ticketSharedUpdates textarea').disabled);
    await page.locator('#ticketSharedUpdates textarea').fill('Customer approved battery replacement.');
    await page.locator('#ticketSharedUpdates [data-action=save]').click();
    await page.getByText('Comment saved.').waitFor();
    assert.equal(entries[0].ticket_code,'TEST-PORTAL');assert.equal(entries[0].store_code,'toowong');
    await page.locator('[data-ticket-section=photos]').click();
    await page.locator('#ticketPhotoUpdates [data-action=upload]').waitFor();
    assert.equal(await page.locator('#ticketSharedUpdates .rtu-comment').count(),1);
    await page.screenshot({path:path.join(process.env.TEMP,'repair-updates-pos.png')});
    const admin=await context.newPage();admin.on('pageerror',e=>errors.push(e.message));
    await admin.route('**/staff-auth.js*',route=>route.fulfill({contentType:'application/javascript',body:`window.Techm8StaffAuth={getToken:()=> 'admin-test',init:async()=>{},logout:()=>{},callRpc:async(name)=>name==='get_admin_repair_follow_up'?{summary:{active:1},stores:[{store_code:'toowong',store_name:'Toowong',active:1}],tickets:[{ticket_code:'TEST-PORTAL',store_code:'toowong',store_name:'Toowong',title:'Battery repair',issue:'Battery replacement',status:'repairing',price:99,customer_name:'Test Customer',customer_phone:'0400000000',active:true,jobs:[]}]}:{totals:{},stores:[]}};`}));
    await admin.goto(url+'/admin.html#repairs');
    await admin.locator('[data-ticket-code="TEST-PORTAL"]').click();
    await admin.locator('#adminRepairUpdates .rtu-comment').waitFor();
    assert((await admin.locator('#adminRepairUpdates').innerText()).includes('Customer approved battery replacement.'));
    await admin.screenshot({path:path.join(process.env.TEMP,'repair-updates-admin.png')});
    await admin.setViewportSize({width:390,height:844});
    await admin.screenshot({path:path.join(process.env.TEMP,'repair-updates-admin-mobile.png')});
    assert(await admin.locator('#adminRepairUpdates').evaluate(el=>el.scrollWidth<=el.clientWidth));
    assert.equal(errors.length,0,errors.join('\n'));
    console.log('PASS: actual POS and admin pages, ticket identity, saved comment shared, photos tab, mobile panel, no runtime errors.');
  } finally {await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);process.exitCode=1;});
