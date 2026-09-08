import fs from 'node:fs';
import http from 'node:http';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

const server = http.createServer((req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname;
  try {
    res.setHeader('Content-Type', path.endsWith('.js') ? 'application/javascript' : path.endsWith('.css') ? 'text/css' : 'text/html');
    res.end(fs.readFileSync('.' + (path === '/' ? '/pos.html' : path)));
  } catch { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const browser = await chromium.launch({ headless: true, channel: 'msedge' });
try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('https://**/*', route => route.abort());
  await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`, { waitUntil: 'domcontentloaded' });
  await page.evaluate(() => {
    const base = { store_id:'toowong',title:'Test phone',issue:'Inspection',price:'10',status:'repairing',createdAt:new Date().toISOString(),statusUpdatedAt:new Date().toISOString(),customerName:'Test customer',customerPhone:'0400000000',active:true,activity:[] };
    state.repairTickets = [
      { ...base,id:'ACTIVE' },
      { ...base,id:'DELETED',active:false,activity:[{id:'D',type:'deleted',text:'deleted this repair ticket',staffName:'Delete Employee',at:'2026-09-09T02:00:00Z'}] },
      { ...base,id:'DONE',status:'closed',closedAt:new Date().toISOString(),activity:[{id:'F',type:'finished',text:'marked this repair card Done',staffName:'Done Employee',at:'2026-09-09T03:00:00Z'}] }
    ].map(normalizeRepairTicket);
    state.repairSearch = '';
    els.repairWorkspace.innerHTML = repairBoardHtml();
    els.repairWorkspace.style.display = 'block';
  });
  assert.equal(await page.locator('[data-ticket-id]').count(), 1);
  assert.equal(await page.locator('[data-ticket-delete]').count(), 0);
  await page.evaluate(() => openTicketDetailModal('ACTIVE'));
  assert.equal(await page.locator('#ticketDeleteButton').isVisible(), true);
  await page.evaluate(() => { closeTicketDetailModal(); state.repairSearch='Test'; els.repairWorkspace.innerHTML=repairBoardHtml(); });
  assert.equal(await page.locator('[data-ticket-id]').count(), 3);
  assert.equal(await page.locator('[data-board-status="history"] [data-ticket-id]').count(), 2);
  assert.equal(await page.locator('[data-ticket-id="DELETED"]').getAttribute('draggable'), 'false');
  await page.evaluate(() => openTicketDetailModal('DELETED'));
  assert.equal(await page.locator('#ticketDeleteButton').isVisible(), false);
  assert.equal(await page.locator('#ticketDetailStatus').isDisabled(), true);
  assert.match(await page.locator('#ticketDetailSide').innerText(), /Delete Employee.*deleted this repair ticket/s);
  assert.equal(await page.locator('#ticketCommentInput').count(), 0);
  await page.evaluate(() => { closeTicketDetailModal(); return openTicketDetailModal('DONE'); });
  assert.match(await page.locator('#ticketDetailSide').innerText(), /Done Employee.*marked this repair card Done/s);
  assert.equal(await page.locator('#ticketDeleteButton').isVisible(), true);
  assert.deepEqual(errors, []);
  console.log('PASS: real browser, board has no Delete, detail has Delete, archived search, disabled archived actions, employee activity and Done details. No live requests or data changes.');
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
