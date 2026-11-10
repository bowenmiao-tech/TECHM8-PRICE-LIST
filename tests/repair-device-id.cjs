const fs=require('node:fs'),http=require('node:http'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
(async()=>{
 const root=path.resolve(__dirname,'..');
 const server=http.createServer((req,res)=>{try{const name=new URL(req.url,'http://localhost').pathname;res.setHeader('Content-Type',name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(path.join(root,name)));}catch{res.writeHead(404).end();}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({channel:'chrome',headless:true});
 try {
 const page=await browser.newPage({viewport:{width:1440,height:1000}}),errors=[],requests=[];let fail=false;
 page.on('pageerror',e=>errors.push(e.message));
 const ticket={id:'RPR-BOARD',title:'Apple iPad 10th',issue:'(Hardware) Phone/Tablet Inspection',status:'need_to_order',active:true,cardKind:'repair',
  store_id:'toowong',price:'$0.00',customerName:'Test Customer',customerPhone:'0400000000',paymentStatus:'paid',deviceInStore:true,motherboardRepair:false,
  baseInvoiced:true,jobs:[],intake:{},activity:[{id:'A1',type:'created',text:'created this repair ticket',staffName:'Staff',at:'2026-09-25T04:59:00Z'}]};
 await page.route('https://**/*',async route=>{
  const req=route.request();
  if(req.url().includes('/pos-repair-updates'))return route.fulfill({json:{ok:true,writable:true,updates:[]}});
  if(!req.url().includes('/pos-repair-tickets'))return route.abort();
  const b=req.postDataJSON();requests.push(b);
  if(fail){fail=false;return route.fulfill({status:400,json:{ok:false,message:'Save failed'}});}
  assert.equal(b.action,'device-id');
  if(b.device_imei)ticket.intake.deviceImei=b.device_imei;
  if(b.device_serial)ticket.intake.deviceSerial=b.device_serial;
  ticket.intake.deviceIdType=ticket.intake.deviceImei?'imei':'sn';
  return route.fulfill({json:{ok:true,ticket}});
 });
 await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
 await page.evaluate(t=>{window.Techm8StaffAuth.getToken=()=> 'test';state.storeId='toowong';state.repairTickets=[normalizeRepairTicket(t)];openTicketDetailModal(t.id);},ticket);
 await page.locator('[data-ticket-section="imei"]').click();
 await page.locator('#ticketDeviceIdSave').click();
 assert.equal(requests.length,0);
 await page.locator('#ticketDeviceImei').fill('123');
 await page.locator('#ticketDeviceIdSave').click();
 assert.equal(requests.length,0);
 await page.locator('#ticketDeviceImei').fill('123456789012345');
 fail=true;await page.locator('#ticketDeviceIdSave').click();
 await page.locator('#ticketDeviceIdError').getByText('Could not save device ID. Please retry.').waitFor();
 assert.equal(await page.locator('#ticketDeviceImei').inputValue(),'123456789012345');
 await page.locator('#ticketDeviceIdSave').click();
 await page.waitForFunction(()=>!document.getElementById('ticketDeviceImei'));
 await page.locator('#ticketDeviceSerial').fill('SN-123');
 await page.locator('#ticketDeviceIdSave').click();
 await page.waitForFunction(()=>!document.getElementById('ticketDeviceIdSave'));
 assert.match(await page.locator('.ticket-detail-content').innerText(),/SN-123/);
 await page.evaluate(()=>{const t=state.repairTickets[0];t.closedAt=new Date().toISOString();t.intake={deviceIdType:'none'};renderTicketDetailModal();});
 assert.equal(await page.locator('#ticketDeviceIdSave').count(),1);
 const labels=await page.evaluate(()=>{
   const t=state.repairTickets[0];
   return [{passwordType:'text',password:'123<&'}, {passwordType:'pattern',patternValue:'1-2-3-6'},
    {passwordType:'none',password:'stale',passwordNoneReason:'forgot'}, {password:''}].map(intake=>repairLabelDocument({...t,intake}));
 });
 assert.match(labels[0],/Password<\/span><strong[^>]*>123&lt;&amp;/);
 assert.match(labels[1],/Pattern<\/span><strong[^>]*>1-2-3-6/);
 assert(!labels[2].includes('stale'));assert(!labels[2].includes('forgot'));
 assert(!labels[3].includes('<span>Password</span>'));
 assert.equal(errors.length,0,errors.join('\n'));
 console.log('PASS: validation; save failure and retry; IMEI then SN; completed repair entry; conditional escaped password and pattern printing.');
 } finally {await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exitCode=1;});
