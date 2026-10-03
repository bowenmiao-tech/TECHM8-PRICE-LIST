const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

(async () => {
  const root = path.resolve(__dirname, '..');
  const server = http.createServer((request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      response.setHeader('Content-Type', pathname.endsWith('.js') ? 'application/javascript' : pathname.endsWith('.css') ? 'text/css' : 'text/html');
      response.end(fs.readFileSync(path.join(root, pathname)));
    } catch (_) {
      response.writeHead(404).end();
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const screenshotDir = path.join(root, '.codex-temp', 'test-screenshots');
  fs.mkdirSync(screenshotDir, { recursive: true });

  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    // POS Today card: store month target and staff month points replace the daily score.
    const pos = await browser.newPage({ viewport: { width: 1366, height: 900 } });
    const posErrors = [];
    pos.on('pageerror', error => posErrors.push(error.message));
    await pos.route('https://**/*', route => route.abort());
    await pos.goto(`${base}/pos.html?dashboard-test`);
    await pos.waitForFunction(() => document.body.dataset.dashboardTestReady === 'true');
    const card = pos.locator('.target-score-card');
    await card.waitFor();
    let text = await card.innerText();
    assert.match(text, /store target/i);
    assert.match(text, /\$14,250/);
    assert.match(text, /\/ \$40,000/);
    assert.match(text, /35%/);
    assert.match(text, /\$25,750 to go/);
    assert.match(text, /about \$954 a day/);
    assert.match(text, /55\s*pts/);
    assert.match(text, /\+30 pts/);
    assert.match(text, /6 reviews/);
    assert.match(text, /\+25 pts/);
    assert.match(text, /2 bundles/);
    assert.doesNotMatch(text, /today's score/i, 'The daily score should no longer be shown');
    assert.doesNotMatch(text, /default target/i, 'The daily target source should no longer be shown');
    await pos.screenshot({ path: path.join(screenshotDir, 'pos-store-month-target-desktop.png') });

    // A review taken today also counts toward the month total.
    await pos.locator('[data-google-review-add]').click();
    await pos.locator('#googleReviewCustomer').fill('Month Points Customer');
    await pos.locator('#googleReviewForm button[type=submit]').click();
    await pos.waitForFunction(() => state.todayProgress.staff_month_points.total_points === 60);
    text = await card.innerText();
    assert.match(text, /60\s*pts/);
    assert.match(text, /\+35 pts/);

    // No target yet, then a target that has been passed.
    await pos.evaluate(() => {
      state.todayProgress.store_month_sales.target = null;
      renderLiveTargetDashboard();
    });
    assert.match(await card.innerText(), /No [A-Za-z]+ target has been set for this store yet/);
    await pos.evaluate(() => {
      Object.assign(state.todayProgress.store_month_sales, { target: 12000, remaining: 0, daily_needed: 0 });
      renderLiveTargetDashboard();
    });
    text = await card.innerText();
    assert.match(text, /target reached/);
    assert.match(text, /118%/);
    assert.equal(await pos.locator('.target-score-track span').evaluate(el => el.style.width), '100%');

    // Older cached payloads without month figures still render.
    await pos.evaluate(() => {
      delete state.todayProgress.store_month_sales;
      delete state.todayProgress.staff_month_points;
      renderLiveTargetDashboard();
    });
    assert.match(await card.innerText(), /appear after the next refresh/);

    await pos.setViewportSize({ width: 390, height: 844 });
    await pos.evaluate(() => {
      state.todayProgress.store_month_sales = { month: brisbaneDateIso().slice(0, 7), days_left: 27, net_sales: 123456.78, target: 250000, remaining: 126543.22, daily_needed: 4686.79 };
      state.todayProgress.staff_month_points = { month: brisbaneDateIso().slice(0, 7), google_review_count: 1, google_review_points: 5, bundle_order_count: 0, bundle_points: 0, total_points: 5 };
      renderLiveTargetDashboard();
    });
    const overflow = await card.evaluate(el => el.scrollWidth - el.clientWidth);
    assert.ok(overflow <= 0, `Card overflows horizontally on a phone by ${overflow}px`);
    await card.screenshot({ path: path.join(screenshotDir, 'pos-store-month-target-mobile.png') });
    assert.deepEqual(posErrors, []);
    await pos.close();
    console.log('PASS: POS month target, month points, review update, empty/reached states and phone width.');

    // Admin Sales Overview: per-store monthly targets.
    const admin = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const adminErrors = [];
    admin.on('pageerror', error => adminErrors.push(error.message));
    await admin.route('**/staff-auth.js*', route => route.fulfill({
      contentType: 'application/javascript',
      body: `
        window.__targetCalls = [];
        window.__targets = { parkridge: 60000, toowong: null };
        const report = month => ({ ok: true, month: month.slice(0, 7), month_start: month, sales_to: month.slice(0, 7) === '2026-10' ? '2026-10-04' : null,
          days_in_month: 31, days_elapsed: month.slice(0, 7) === '2026-10' ? 4 : 0,
          stores: [
            { store_code: 'parkridge', store_name: 'Park Ridge Town Centre', sales_target: window.__targets.parkridge, net_sales: 66000, updated_by: window.__targets.parkridge ? 'Bowen' : null, updated_at: window.__targets.parkridge ? '2026-10-01T00:00:00Z' : null },
            { store_code: 'fairfield', store_name: 'Fairfield Gardens Shopping Centre', sales_target: null, net_sales: 4100.5, updated_by: null, updated_at: null },
            { store_code: 'northlakes', store_name: 'Westfield North Lakes Shopping Centre', sales_target: null, net_sales: 0, updated_by: null, updated_at: null },
            { store_code: 'toowong', store_name: 'Toowong Village Shopping Centre', sales_target: window.__targets.toowong, net_sales: 2855.9, updated_by: window.__targets.toowong ? 'Bowen' : null, updated_at: window.__targets.toowong ? '2026-10-04T01:00:00Z' : null },
            { store_code: 'brassall', store_name: 'Brassall', sales_target: null, net_sales: 0, updated_by: null, updated_at: null }
          ] });
        window.Techm8StaffAuth = {
          getToken: () => 'admin-test', init: async () => {}, logout: () => {},
          callRpc: async (name, params) => {
            if (name === 'get_admin_sales_overview') return { date_from: params.date_from, date_to: params.date_to, totals: {}, stores: [] };
            if (name === 'get_admin_store_sales_targets') { window.__targetCalls.push({ name, ...params }); return report(params.target_month_start); }
            if (name === 'set_admin_store_sales_target') {
              window.__targetCalls.push({ name, ...params });
              if (params.target_amount > 99999999) throw new Error('Target is too large');
              window.__targets[params.target_store_code] = params.target_amount || null;
              return report(params.target_month_start);
            }
            return { summary: {}, stores: [], tickets: [] };
          }
        };
      `
    }));
    await admin.route('https://**/*', route => route.abort());
    await admin.clock.setFixedTime(new Date('2026-10-04T02:00:00Z'));
    await admin.goto(`${base}/admin.html#sales`);
    await admin.locator('[data-target-row="toowong"]').waitFor();
    assert.equal(await admin.locator('#targetMonthLabel').innerText(), 'October 2026');
    assert.equal(await admin.locator('[data-target-row]').count(), 5);
    const parkRidge = await admin.locator('[data-target-row="parkridge"]').innerText();
    assert.match(parkRidge, /110%/);
    assert.match(parkRidge, /Reached/);
    assert.match(await admin.locator('#targetRangeLabel').innerText(), /day 4 of 31/);

    const toowongInput = admin.locator('[data-target-input="toowong"]');
    const toowongSave = admin.locator('[data-target-save="toowong"]');
    assert.equal(await toowongSave.isDisabled(), true, 'Save should wait for a change');
    await toowongInput.fill('45000');
    // An unsaved draft in another row must survive this save.
    await admin.locator('[data-target-input="fairfield"]').fill('30000');
    await toowongSave.click();
    await admin.locator('#targetStatus').getByText('Toowong target for October 2026 saved: $45,000.00.').waitFor();
    const saveCall = await admin.evaluate(() => window.__targetCalls.find(call => call.name === 'set_admin_store_sales_target'));
    assert.deepEqual(saveCall, { name: 'set_admin_store_sales_target', session_token: 'admin-test', target_store_code: 'toowong', target_month_start: '2026-10-01', target_amount: 45000 });
    const toowong = await admin.locator('[data-target-row="toowong"]').innerText();
    assert.match(toowong, /6%/);
    assert.match(toowong, /\$42,144\.10/);
    assert.equal(await admin.locator('[data-target-input="fairfield"]').inputValue(), '30000');
    assert.equal(await admin.locator('[data-target-save="fairfield"]').isDisabled(), false);

    // Enter saves; an empty amount removes the target.
    await admin.locator('[data-target-input="parkridge"]').fill('');
    assert.equal(await admin.locator('[data-target-save="parkridge"]').innerText(), 'Remove');
    await admin.locator('[data-target-input="parkridge"]').press('Enter');
    await admin.locator('#targetStatus').getByText('Park Ridge target for October 2026 removed.').waitFor();
    assert.match(await admin.locator('[data-target-row="parkridge"]').innerText(), /Not set/);

    // A rejected save keeps what was typed.
    await admin.locator('[data-target-input="northlakes"]').fill('100000000');
    await admin.locator('[data-target-save="northlakes"]').click();
    await admin.locator('#targetStatus[data-error="true"]').getByText('Target is too large').waitFor();
    assert.equal(await admin.locator('[data-target-input="northlakes"]').inputValue(), '100000000');

    await admin.locator('#targetNextMonth').click();
    await admin.waitForFunction(() => window.__targetCalls.some(call => call.target_month_start === '2026-11-01'));
    assert.equal(await admin.locator('#targetMonthLabel').innerText(), 'November 2026');
    await admin.locator('#targetRangeLabel').getByText(/has not started/).waitFor();
    await admin.locator('#targetPrevMonth').click();
    await admin.locator('#targetPrevMonth').click();
    await admin.waitForFunction(() => window.__targetCalls.some(call => call.target_month_start === '2026-09-01'));

    await admin.locator('#targetSection').scrollIntoViewIfNeeded();
    await admin.screenshot({ path: path.join(screenshotDir, 'admin-store-targets-desktop.png'), fullPage: true });
    await admin.setViewportSize({ width: 390, height: 844 });
    const pageOverflow = await admin.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    assert.ok(pageOverflow <= 0, `Admin page overflows horizontally on a phone by ${pageOverflow}px`);
    await admin.locator('.target-table').screenshot({ path: path.join(screenshotDir, 'admin-store-targets-mobile.png') });
    assert.deepEqual(adminErrors, []);
    await admin.close();
    console.log('PASS: admin monthly targets load, save, remove, keep drafts, reject, change month and fit a phone.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
