const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');
(async () => {
 const root=path.resolve(__dirname,'..');
 const server=http.createServer((req,res)=>{try{const name=new URL(req.url,'http://localhost').pathname;res.setHeader('Content-Type',name.endsWith('.js')?'application/javascript':'text/html');res.end(fs.readFileSync(path.join(root,name)));}catch{res.writeHead(404).end();}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch({channel:'chrome',headless:true});
 try {
  const page=await browser.newPage({viewport:{width:1440,height:1000}});const errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://**/*',route=>route.abort());
  await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
  await page.evaluate(()=>{
   state.storeId='north-lakes';state.selectedStaffName='Test Staff';
   const common={invoice_number:5246,store_id:'north-lakes',store_db_code:'northlakes',store_name:'TechM8 North Lakes',customer_name:'Test Customer',customer_phone:'0400000000',staff_name:'Test Staff',balance_due:0,payment_status:'paid',refund_status:'paid'};
   const first={...common,id:'POS-INSPECTION',total:99,amount_paid:99,refundable_total:99,created_at:'2026-11-08T01:00:00Z',items:[{line_id:100,name:'Laptop inspection',line_type:'repair',is_repair:true,unit_price:99,line_total:99,qty:1}],payments:[{payment_number:1,method:'Card',amount:99,taken_at:'2026-11-08T01:00:00Z'}]};
   const second={...common,id:'POS-REPAIR',total:20,amount_paid:20,refundable_total:20,created_at:'2026-11-09T02:06:00Z',items:[{line_id:101,name:'Charger repair',line_type:'repair',is_repair:true,unit_price:20,line_total:20,qty:1,inspection_credit:99,original_unit_price:119}],payments:[{payment_number:1,method:'Card',amount:20,taken_at:'2026-11-09T02:06:00Z'}]};
   const parts=[first,second];
   const invoice={...first,checkouts:parts,total:119,amount_paid:119,refundable_total:119,items:parts.flatMap((p,i)=>p.items.map(item=>({...item,checkout_number:i+1,checkout_at:p.created_at,checkout_order_id:p.id}))),payments:parts.flatMap((p,i)=>p.payments.map(payment=>({...payment,checkout_number:i+1,checkout_order_id:p.id})))};
   window.__first={...first,invoice};window.__second={...second,invoice};
   state.invoiceOrders=[window.__second,window.__first];renderInvoiceHistory();
   openReceiptCompleteModal(window.__second);
  });
  assert.equal(await page.locator('.invoice-row').count(),1);
  assert.match(await page.locator('.invoice-row').innerText(),/\$119\.00/);
  assert.match(await page.locator('.invoice-row').innerText(),/2 checkouts/);
  assert.match(await page.locator('#receiptCompleteTotal').innerText(),/\$20\.00 paid this checkout/);
  const details=await page.locator('#receiptInvoiceDetails').innerText();
  for(const text of ['Checkout 1','Checkout 2','Laptop inspection','Charger repair','$99.00','$20.00']) assert.ok(details.includes(text),text);
  assert.equal(await page.locator('[data-payment-order="POS-INSPECTION"]').count(),1);
  assert.equal(await page.locator('[data-payment-order="POS-REPAIR"]').count(),1);
  await page.screenshot({path:'/tmp/techm8-grouped-receipt.png',fullPage:true});
  await page.evaluate(()=>{state.customerHistoryOrders=[window.__second,window.__first];renderCustomerHistory(state.customerHistoryOrders,false);});
  assert.equal(await page.locator('#customerHistoryList .customer-history-row').count(),1);
  assert.match(await page.locator('#customerHistorySummary').innerText(),/\$119\.00/);
  const receipt=await page.evaluate(()=>thermalReceiptContent(window.__second));
  for(const text of ['Laptop inspection','Charger repair','$119.00','$99.00','$20.00','Checkout 1','Checkout 2','08/11/2026','09/11/2026']) assert.ok(receipt.includes(text),text);
  await page.evaluate(()=>openReceiptCompleteModal(window.__first,{history:true}));
  assert.match(await page.locator('#receiptCompleteTotal').innerText(),/\$119\.00 paid/);
  // Colliding payment_number=1 must target the correct checkout.
  await page.evaluate(()=>{
   window.prompt=(()=>{const answers=['1','Correction regression'];return()=>answers.shift();})();
   window.fetch=async(url,options)=>{window.__correction=JSON.parse(options.body);return new Response(JSON.stringify({ok:true,order:window.__second}));};
  });
  await page.locator('[data-payment-order="POS-REPAIR"]').click();
  await page.waitForFunction(()=>window.__correction);
  assert.equal(await page.evaluate(()=>window.__correction.order_id),'POS-REPAIR');
  // Refund actions retain each checkout's own lines and amounts.
  await page.evaluate(()=>{invoiceOrderById=async id=>id==='POS-INSPECTION'?window.__first:window.__second;});
  await page.locator('[data-refund-checkout="POS-INSPECTION"]').click();
  await page.waitForFunction(()=>state.refundOrder);
  assert.equal(await page.evaluate(()=>state.refundOrder.total),99);
  assert.match(await page.locator('#refundLines').innerText(),/Laptop inspection/);
  assert.doesNotMatch(await page.locator('#refundLines').innerText(),/Charger repair/);
  assert.deepEqual(errors,[]);
  console.log('Grouped repair invoice: list, receipt, checkouts, correction and refund passed');
 }finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(e=>{console.error(e);process.exitCode=1;});
