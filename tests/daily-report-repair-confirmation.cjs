const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

(async () => {
  const root = path.resolve(__dirname, '..');
  const server = http.createServer((request, response) => {
    const name = new URL(request.url, 'http://localhost').pathname;
    const file = path.join(root, name);
    if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) return response.writeHead(404).end();
    response.setHeader('Content-Type', name.endsWith('.js') ? 'application/javascript' : 'text/html');
    response.end(fs.readFileSync(file));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/supabase-config.js', route => route.fulfill({ body: 'window.TECHM8_SUPABASE = null;' }));
    await page.route('**/staff-auth.js*', route => route.fulfill({ body: `
      window.__repairSuggestions = [{
        source_key: 'ticket:1', source_signature: 'first', ticket_code: 'RPR-1',
        model_and_color: 'iPhone 14 Black', problem_and_parts_used: 'Screen replacement',
        tech_name: 'Sam', invoice_number: '123', amount: '159.00'
      }];
      window.Techm8StaffAuth = {
        init: () => Promise.resolve(), getToken: () => 'test',
        callRpc: async name => {
          if (name === 'get_daily_report_setup') return {
            stores: [{ store_code: 'fairfield', store_name: 'Fairfield' }],
            staff: [{ display_name: 'Sam' }], lcd_items: []
          };
          if (name === 'get_daily_report_draft') return { has_draft: false };
          if (name === 'get_daily_report_repair_suggestions') return { repair_lines: window.__repairSuggestions };
          if (name === 'list_daily_report_drafts') return { drafts: [], submitted_today: false };
          throw new Error('Unexpected RPC ' + name);
        }
      };
    ` }));
    await page.goto(`http://127.0.0.1:${server.address().port}/daily-report.html`);
    await page.waitForFunction(() => Boolean(document.querySelector('#app')?.__vue__));
    await page.evaluate(async () => {
      const app = document.querySelector('#app').__vue__;
      app.selectedStoreCode = 'fairfield';
      app.selectedStaffName = 'Sam';
      await app.enterReport();
    });
    assert.equal(await page.locator('.line-card.repair-row-confirmed').count(), 0);
    assert.equal(await page.locator('.repair-row-head').count(), 1, 'Completed repair should replace the blank row');
    assert.match(await page.locator('.repair-row-head').innerText(), /RPR-1/);
    await page.locator('.repair-row-actions button').click();
    assert.equal(await page.locator('.line-card.repair-row-confirmed').count(), 1);
    await page.locator('.grid-repair input').first().fill('iPhone 14 Blue');
    assert.equal(await page.locator('.line-card.repair-row-confirmed').count(), 0, 'Editing must clear confirmation');
    const rejected = await page.evaluate(() => {
      const app = document.querySelector('#app').__vue__;
      return app.validateBeforeSubmit(app.buildPayload());
    });
    assert.equal(rejected, false, 'Unconfirmed row must fail submission validation');
    await page.locator('.repair-row-actions button').click();
    const accepted = await page.evaluate(() => {
      const app = document.querySelector('#app').__vue__;
      return app.validateBeforeSubmit(app.buildPayload());
    });
    assert.equal(accepted, true);
    await page.evaluate(async () => {
      window.__repairSuggestions = window.__repairSuggestions.map(line => ({ ...line, source_signature: 'updated', amount: '169.00' }));
      await document.querySelector('#app').__vue__.refreshRepairSuggestions(true);
    });
    assert.equal(await page.locator('.line-card.repair-row-confirmed').count(), 0, 'Source changes must require a fresh confirmation');
    assert.equal(await page.locator('.grid-repair input').last().inputValue(), '169.00');
    await page.evaluate(async () => {
      const app = document.querySelector('#app').__vue__;
      app.removeRepairLine(0);
      await app.refreshRepairSuggestions(true);
    });
    assert.equal(await page.locator('.repair-row-head').count(), 1, 'Removing a suggestion must not add it back on refresh');
    assert.doesNotMatch(await page.locator('.repair-row-head').innerText(), /RPR-1/);
    const removedDraft = await page.evaluate(() => document.querySelector('#app').__vue__.buildPayload());
    assert.equal(removedDraft.dismissed_repair_sources[0].source_key, 'ticket:1');
    await page.evaluate(async draft => {
      const app = document.querySelector('#app').__vue__;
      app.applyDraft(draft);
      await app.refreshRepairSuggestions(true);
    }, removedDraft);
    assert.doesNotMatch(await page.locator('.repair-row-head').innerText(), /RPR-1/, 'Removed suggestion must stay removed after loading a draft');
    await page.getByText('Restore removed repairs').click();
    assert.match(await page.locator('.repair-row-head').innerText(), /RPR-1/);
    await page.evaluate(async () => {
      const app = document.querySelector('#app').__vue__;
      const manual = app.makeRepairLine();
      Object.assign(manual, { model_and_color: 'Xbox', problem_and_parts_used: 'Inspection', invoice_number: '4378', amount: '59.00', confirmed: true });
      app.repairLines.push(manual);
      window.__repairSuggestions.push({ source_key: 'inspection:2', source_signature: 'inspection-first', ticket_code: 'RPR-2', model_and_color: 'Xbox', problem_and_parts_used: 'Inspection', tech_name: 'Sam', invoice_number: '4378', amount: '59.00' });
      await app.refreshRepairSuggestions(true);
    });
    const inspectionState = await page.evaluate(() => {
      const app = document.querySelector('#app').__vue__;
      return { rows: app.repairLines.filter(line => line.invoice_number === '4378'), total: app.repairSalesTotal };
    });
    assert.equal(inspectionState.rows.length, 1, 'Paid inspection must attach to the confirmed manual row, not duplicate it');
    assert.equal(inspectionState.rows[0].source_key, 'inspection:2');
    assert.equal(inspectionState.rows[0].confirmed, true);
    assert.equal(inspectionState.total, 228, 'Inspection fee must count in repair sales');
    assert.deepEqual(errors, [], errors.join('\n'));
    console.log('PASS: completed repair confirmation, removal persistence, restore, paid inspection counting without duplication');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
