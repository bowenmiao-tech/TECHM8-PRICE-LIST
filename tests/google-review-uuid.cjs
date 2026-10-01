const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

(async () => {
  const root = path.resolve(__dirname, '..');
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  const server = http.createServer((request, response) => {
    try {
      const pathname = new URL(request.url, 'http://localhost').pathname;
      response.setHeader('Content-Type', pathname.endsWith('.js') ? 'application/javascript' : 'text/html');
      response.end(fs.readFileSync(path.join(root, pathname)));
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    for (const fallback of [false, true]) {
      const page = await browser.newPage();
      const errors = [];
      const requests = [];
      page.on('pageerror', error => errors.push(error.message));
      if (fallback) await page.addInitScript(() => {
        Object.defineProperty(window.crypto, 'randomUUID', { value: undefined, configurable: true });
      });
      await page.route('https://**/*', route => route.abort());
      // Catalog mode skips login/bootstrap but leaves the real review API path enabled.
      await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?catalog-test`);
      await page.evaluate(() => {
        initializeLocalDashboardUiTest();
        window.Techm8StaffAuth.getToken = () => 'test-session';
      });
      const progress = await page.evaluate(() => structuredClone(state.todayProgress));
      await page.route('**/functions/v1/pos-sales-orders?mode=google-review', async route => {
        requests.push(route.request().postDataJSON());
        assert.equal(route.request().headers()['x-staff-session'], 'test-session');
        progress.metrics.google_review_count += 1;
        progress.metrics.google_review_points += 5;
        progress.score.earned_points += 5;
        progress.score.remaining_points -= 5;
        await route.fulfill({ json: progress });
      });
      await page.locator('[data-google-review-add]').click();
      await page.locator('#googleReviewCustomer').fill('Review Test Customer');
      await page.locator('#googleReviewForm button[type=submit]').click();
      await page.waitForFunction(() => state.todayProgress.metrics.google_review_count === 3 && !state.googleReviewSaving);
      assert.equal(requests.length, 1);
      assert.match(requests[0].event_code, uuidPattern);
      assert.equal(requests[0].customer_name, 'Review Test Customer');
      assert.equal(requests[0].store_code, 'toowong');
      assert.equal(requests[0].staff_name, 'Bowen');
      assert.equal(await page.evaluate(() => state.todayProgress.metrics.google_review_points), 15);
      const ids = await page.evaluate(() => Array.from({ length: 1000 }, () => window.techm8RandomUUID()));
      assert.equal(new Set(ids).size, ids.length);
      ids.forEach(id => assert.match(id, uuidPattern));
      assert.deepEqual(errors, []);
      await page.close();
      console.log(`Google Review submission passed (${fallback ? 'without randomUUID' : 'native UUID'}).`);
    }
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
