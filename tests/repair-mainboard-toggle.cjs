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
  if(req.method()!=='POST')return route.fulfill({json:{ok:true,ticket:ticket}});
  const b=req.postDataJSON();requests.push(b);
  if(fail){fail=false;return route.fulfill({status:400,json:{ok:false,message:'Test mainboard failed'}});}
  assert.equal(b.action,'mainboard');
  ticket.motherboardRepair=b.motherboard_repair;
  ticket.activity=[{id:'A'+requests.length,type:'mainboard',text:b.motherboard_repair?'marked this card as a mainboard repair':'removed the mainboard repair mark',staffName:'Staff',at:new Date().toISOString()},...ticket.activity];
  return route.fulfill({json:{ok:true,ticket:{...ticket}}});
 });
 await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
 await page.evaluate(t=>{window.Techm8StaffAuth.getToken=()=>'test';state.storeId='toowong';state.repairTickets=[normalizeRepairTicket(t)];state.repairSearch='';els.repairWorkspace.innerHTML=repairBoardHtml();},ticket);
 const boardTag=()=>page.locator('[data-ticket-id="RPR-BOARD"] .ticket-tag.danger',{hasText:'Mainboard'}).count();
 assert.equal(await boardTag(),0,'Inspection card must start without the Mainboard tag');

 await page.evaluate(()=>openTicketDetailModal('RPR-BOARD'));
 const toggle=page.locator('#ticketMainboardToggle');
 assert.equal(await toggle.getAttribute('aria-checked'),'false');

 fail=true;await toggle.click();
 await page.waitForFunction(()=>!document.getElementById('ticketMainboardToggle').disabled);
 assert.equal(await toggle.getAttribute('aria-checked'),'false','Failed save must leave the switch off');
 assert.equal(await page.evaluate(()=>state.repairTickets[0].motherboardRepair),false);

 await toggle.click();
 await page.waitForFunction(()=>state.repairTickets[0].motherboardRepair===true);
 assert.deepEqual([requests.at(-1).ticket_code,requests.at(-1).motherboard_repair],['RPR-BOARD',true]);
 assert.equal(await page.locator('#ticketMainboardToggle').getAttribute('aria-checked'),'true');
 assert.equal(await page.locator('.ticket-activity-list .bi-cpu').count(),1,'Mainboard event missing from activity');
 await page.screenshot({path:path.join(root,'outputs/repair-mainboard-toggle.png')});
 assert.equal(await boardTag(),1,'Board card must show the Mainboard tag');

 await page.locator('#ticketMainboardToggle').click();
 await page.waitForFunction(()=>state.repairTickets[0].motherboardRepair===false);
 assert.equal(requests.at(-1).motherboard_repair,false);
 assert.equal(await page.locator('#ticketMainboardToggle').getAttribute('aria-checked'),'false');
 assert.equal(await boardTag(),0,'Mainboard tag must go when switched off');
 assert.equal(errors.length,0,errors.join('\n'));
 console.log('PASS: switch off by default; failed save keeps it off; on sends mainboard=true, shows the Mainboard tag on the board card and a cpu activity line; off removes the tag; no runtime errors.');
 } finally {await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exitCode=1;});
