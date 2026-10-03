const { chromium } = require('playwright');
const { pathToFileURL } = require('url');
const path = require('path');

(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath: 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  await page.route('**/staff-auth.js*', route => route.fulfill({
    contentType: 'application/javascript',
    body: 'window.Techm8StaffAuth={getToken:()=>"test",init:()=>Promise.resolve()};'
  }));
  await page.route('**/functions/v1/pos-staff-management*', route => {
    const points = route.request().url().includes('mode=points');
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify(points ? {
      ok: true, this_month_start: '2026-10-01',
      totals: { this_month_points: 15, device_points: 20, combined_points: 35 },
      staff: [
        { staff_name: 'Fiona', normalized_staff_name: 'fiona', active: true,
          this_month_points: 0, device_points: 20, total_points: 20,
          this_month_reviews: 0, device_bundle_count: 2, total_reviews: 5 },
        { staff_name: 'Bowen', normalized_staff_name: 'bowen', active: true,
          this_month_points: 15, device_points: 0, total_points: 15,
          this_month_reviews: 3, device_bundle_count: 0, total_reviews: 4 }
      ],
      device_events: [{ normalized_staff_name: 'fiona', order_code: 'POS-TEST',
        business_date: '2026-10-03', store_name: 'Toowong', device_count: 1,
        accessory_count: 1, points: 10 }], events: []
    } : { ok: true, staff: [], stores: [] }) });
  });
  await page.goto(pathToFileURL(path.resolve(__dirname, '..', 'stocktake-admin.html')).href);
  await page.locator('.review-staff-card').first().waitFor();
  const summary = await page.locator('.points-panel').innerText();
  if (!summary.includes('35 pts') || !summary.includes('Fiona')) throw new Error('Score overview is missing');
  if (await page.locator('#reviewHistory').isVisible()) throw new Error('Review history should start collapsed');
  if (process.env.SCORE_SCREENSHOT) await page.screenshot({ path: process.env.SCORE_SCREENSHOT });
  await page.locator('[data-review-staff="fiona"]').click();
  if (!await page.locator('#scoreDetail').isVisible()) throw new Error('Staff detail did not open');
  if (!await page.locator('#reviewHistory').isVisible()) throw new Error('Review history did not open');
  await browser.close();
  console.log('Staff points page: overview and drilldown passed');
})().catch(error => { console.error(error); process.exit(1); });
