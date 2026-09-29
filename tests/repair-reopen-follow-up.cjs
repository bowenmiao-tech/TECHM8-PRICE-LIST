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
 const closed={id:'RPR-REOPEN',title:'iPhone 13',issue:'Screen replacement',status:'closed',active:true,closedAt:'2026-09-03T06:42:03Z',resolution:'repaired',
  store_id:'toowong',price:'$199.00',customerName:'Test Customer',customerPhone:'0400000000',paymentStatus:'paid',baseInvoiced:true,canClose:true,
  invoiceOrderId:'POS-1',invoiceNumber:11885,invoiceHistory:[{orderId:'POS-1',invoiceNumber:11885,total:199,amountPaid:199,balanceDue:0,lines:[]}],jobs:[],intake:{},
  activity:[{id:'A1',type:'finished',text:'closed this repair card after invoice #11885 - repaired',staffName:'Staff',at:'2026-09-03T06:42:03Z'}]};
 await page.route('https://**/*',async route=>{
  const req=route.request();
  if(req.url().includes('/pos-repair-updates'))return route.fulfill({json:{ok:true,writable:true,updates:[]}});
  if(!req.url().includes('/pos-repair-tickets'))return route.abort();
  const b=req.postDataJSON();requests.push(b);
  if(fail){fail=false;return route.fulfill({status:400,json:{ok:false,message:'Test reopen failed'}});}
  assert.equal(b.action,'reopen');
  return route.fulfill({json:{ok:true,ticket:{...closed,id:b.ticket_code,status:b.status,closedAt:null,resolution:null,deviceInStore:b.device_in_store,
   activity:[{id:'A2',type:'status',reopened:true,text:'reopened this card for a follow-up check (was closed as repaired) in '+b.status,staffName:'Staff',at:new Date().toISOString()},...closed.activity]}}});
 });
 await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
 await page.evaluate(ticket=>{window.Techm8StaffAuth.getToken=()=>'test';state.storeId='toowong';state.repairTickets=[normalizeRepairTicket(ticket)];state.repairSearch='';els.repairWorkspace.innerHTML=repairBoardHtml();},closed);
 assert.equal(await page.locator('[data-ticket-id]').count(),0,'Done card must stay off the normal board');
 assert.match(await page.locator('#repairBoardSearch').getAttribute('placeholder'),/invoice #/);
 await page.evaluate(()=>{state.repairSearch='11885';els.repairWorkspace.innerHTML=repairBoardHtml();});
 assert.equal(await page.locator('[data-board-status=history] [data-ticket-id]').count(),1);

 await page.evaluate(()=>openTicketDetailModal('RPR-REOPEN'));
 assert.equal(await page.locator('#ticketReopenButton').isVisible(),true);
 assert.equal(await page.locator('#ticketFinishButton').isVisible(),false);
 await page.getByText('Customer back with a problem?').waitFor();

 await page.locator('#ticketReopenButton').click();
 assert.equal(await page.locator('#repairReopenStatus').inputValue(),'repairing');
 assert.equal(await page.locator('#repairReopenStatus option[value=over_3_months_uncollected]').count(),0);
 assert.equal(await page.locator('#repairReopenDevice').isChecked(),true);
 await page.locator('#repairReopenSave').click();
 await page.locator('#repairReopenError').getByText('Describe what the customer came back with.').waitFor();
 assert.equal(requests.length,0,'Blank reason must not reach the server');

 await page.locator('#repairReopenReason').fill('Screen flickers again after two weeks');
 await page.locator('#repairReopenStatus').selectOption('waiting_customer_confirmation');
 fail=true;await page.locator('#repairReopenSave').click();
 await page.locator('#repairReopenError').getByText('Test reopen failed').waitFor();
 assert.equal(await page.locator('#repairReopenReason').inputValue(),'Screen flickers again after two weeks','Reason lost after a failed save');

 await page.locator('#repairReopenSave').click();
 await page.waitForFunction(()=>!state.repairTickets[0].closedAt);
 const sent=requests.at(-1);
 assert.deepEqual([sent.ticket_code,sent.reason,sent.status,sent.device_in_store],['RPR-REOPEN','Screen flickers again after two weeks','waiting_customer_confirmation',true]);
 assert.equal(await page.locator('#repairReopenModal').isVisible(),false);
 assert.equal(await page.locator('#ticketReopenButton').isVisible(),false);
 assert.equal(await page.locator('#ticketDetailStatus').isDisabled(),false);
 assert.equal(await page.locator('#ticketDetailStatus').inputValue(),'waiting_customer_confirmation');
 assert.equal(await page.locator('.ticket-activity-list .bi-arrow-repeat').count(),1,'Reopen event missing from activity');
 await page.screenshot({path:path.join(root,'outputs/repair-reopen-detail.png')});

 await page.evaluate(()=>{closeTicketDetailModal();state.repairSearch='';els.repairWorkspace.innerHTML=repairBoardHtml();});
 const card=page.locator('[data-board-status=waiting_customer_confirmation] [data-ticket-id="RPR-REOPEN"]');
 assert.equal(await card.count(),1,'Reopened card must return to the chosen column');
 assert.equal(await card.locator('.ticket-tag',{hasText:'Follow-up'}).count(),1,'Follow-up tag missing');

 // Moving a Done card with the status list reopens it with no note.
 await page.evaluate(ticket=>{state.repairTickets.push(normalizeRepairTicket({...ticket,id:'RPR-MOVE'}));state.repairSearch='RPR';els.repairWorkspace.innerHTML=repairBoardHtml();},closed);
 assert.equal(await page.locator('[data-board-status=history] [data-ticket-id="RPR-MOVE"]').getAttribute('draggable'),'true','Done card must be draggable');
 await page.evaluate(()=>openTicketDetailModal('RPR-MOVE'));
 assert.equal(await page.locator('#ticketDetailStatus').isDisabled(),false,'Done card status list must not be locked');
 assert.equal(await page.locator('#ticketDetailStatus').inputValue(),'','Done card must not look like Need to order');
 await page.locator('#ticketDetailStatus').selectOption('repairing');
 await page.waitForFunction(()=>!state.repairTickets.find(t=>t.id==='RPR-MOVE').closedAt);
 assert.deepEqual([requests.at(-1).ticket_code,requests.at(-1).status,requests.at(-1).reason],['RPR-MOVE','repairing','']);
 assert.equal(await page.locator('#ticketDetailStatus').inputValue(),'repairing');
 assert.equal(await page.locator('[data-board-status=repairing] [data-ticket-id="RPR-MOVE"]').count(),1,'Moved card missing from its new column');
 assert.equal(errors.length,0,errors.join('\n'));
 console.log('PASS: invoice search hint; Done card only in search; reopen button + closed note; reason required; failure keeps input; request payload; card back in chosen column with Follow-up tag; Done card draggable and movable from the status list; no runtime errors.');
 } finally {await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exitCode=1;});
