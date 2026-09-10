const fs=require('node:fs'),http=require('node:http'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
(async()=>{
 const root=path.resolve(__dirname,'..');
 const server=http.createServer((req,res)=>{try{const name=new URL(req.url,'http://localhost').pathname;res.setHeader('Content-Type',name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(path.join(root,name)));}catch{res.writeHead(404).end();}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({channel:'chrome',headless:true});
 try {
 const page=await browser.newPage({viewport:{width:1440,height:1000}}),errors=[],cards=new Map();let fail=false;
 page.on('pageerror',e=>errors.push(e.message));
 await page.route('https://**/*',async route=>{
 const req=route.request();
 if(req.url().includes('/pos-repair-updates'))return route.fulfill({json:{ok:true,writable:true,updates:[]}});
 if(!req.url().includes('/pos-repair-tickets'))return route.abort();
 const b=req.postDataJSON();
 if(fail){fail=false;return route.fulfill({status:500,json:{ok:false,message:'Test save failed'}});}
 let t=cards.get(b.ticket_code);
 if(b.action==='create-memo'){t={id:b.ticket_code,cardKind:'memo',title:'Memo card',status:b.status,active:true,price:'$0.00',store_id:'toowong',canClose:true,jobs:[],activity:[],intake:{}};cards.set(t.id,t);}
 if(b.action==='create-memo'||b.action==='save-memo')Object.assign(t,{displayLabel:b.display_label,customerName:b.customer_name,customerPhone:b.customer_phone,intake:{memoNotes:b.notes}});
 if(b.action==='move-memo')t.status=b.status;
 if(b.action==='finish-memo')t.closedAt=new Date().toISOString();
 return route.fulfill({json:{ok:true,ticket:t}});
 });
 await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
 await page.evaluate(()=>{window.Techm8StaffAuth.getToken=()=> 'test';state.storeId='toowong';state.repairTickets=[];els.repairWorkspace.innerHTML=repairBoardHtml();});
 assert.equal(await page.locator('[data-new-memo]').count(),6);
 await page.evaluate(()=>openNewMemo('need_to_order'));
 await page.locator('#memoSave').click();
 await page.waitForFunction(()=>state.selectedTicketId.startsWith('MEMO-'));
 assert.equal(cards.size,1);assert.equal(await page.locator('#memoCustomer').inputValue(),'');
 assert.equal(await page.locator('#ticketFinishButton').isEnabled(),true);
 assert.equal(await page.locator('[data-job-cart="__base__"]').count(),0);
 await page.locator('#memoTitle').fill('Order PS5 power supply');await page.locator('#memoNotes').fill('Customer coming back for warranty.\nCall when parts arrive.');
 fail=true;await page.locator('#memoSave').click();await page.locator('#memoError').getByText('Test save failed').waitFor();assert.equal(await page.locator('#memoTitle').inputValue(),'Order PS5 power supply');
 await page.locator('#memoSave').click();await page.getByRole('heading',{name:'Order PS5 power supply',exact:true}).waitFor();
 await page.locator('#ticketDetailStatus').selectOption('waiting_shipping');await page.waitForFunction(()=>state.repairTickets[0].status==='waiting_shipping');
 await page.screenshot({path:path.join(root,'outputs/repair-memo-detail.png')});
 await page.locator('#ticketFinishButton').click();await page.waitForFunction(()=>!!state.repairTickets[0].closedAt);
 assert.equal(await page.locator('#memoNotes').isDisabled(),true);
 await page.evaluate(()=>{closeTicketDetailModal();state.repairSearch='';els.repairWorkspace.innerHTML=repairBoardHtml();});assert.equal(await page.locator('[data-ticket-id]').count(),0);
 await page.evaluate(()=>{state.repairSearch='PS5';els.repairWorkspace.innerHTML=repairBoardHtml();});assert.equal(await page.locator('[data-board-status=history] [data-ticket-id]').count(),1);
 await page.evaluate(()=>{state.repairTickets.push(normalizeRepairTicket({id:'NORMAL',title:'iPhone repair',status:'repairing',store_id:'toowong',price:'99',customerName:'Customer',customerPhone:'0400000000'}));openTicketDetailModal('NORMAL');});
 assert.equal(await page.locator('#ticketLabelInput').count(),1);assert.equal(await page.locator('#ticketFinishButton').isDisabled(),true);
 assert.equal(errors.length,0,errors.join('\n'));
 console.log('PASS: six column buttons; empty creation; editing; failure/retry; movement without contact; finish/history; original repair UI; no runtime errors.');
 } finally {await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exitCode=1;});
