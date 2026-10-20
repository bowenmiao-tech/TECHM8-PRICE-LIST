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
      totals: { this_month_points: 15, device_points: 20, commission_points: 15, combined_points: 50 },
      staff: [
        { staff_name: 'Fiona', normalized_staff_name: 'fiona', active: true,
          this_month_points: 0, device_points: 20, personal_sales: 1000, commission_points: 10,
          transaction_count: 100, product_units: 200, products_per_transaction: 2, total_points: 30,
          this_month_reviews: 0, device_bundle_count: 2, total_reviews: 5 },
        { staff_name: 'Bowen', normalized_staff_name: 'bowen', active: true,
          this_month_points: 15, device_points: 0, personal_sales: 500, commission_points: 5,
          transaction_count: 10, product_units: 15, products_per_transaction: 1.5, total_points: 20,
          this_month_reviews: 3, device_bundle_count: 0, total_reviews: 4 }
      ],
      device_events: [{ normalized_staff_name: 'fiona', order_code: 'POS-TEST',
        business_date: '2026-10-03', store_name: 'Toowong', device_count: 1,
        accessory_count: 1, devices: [{ name: 'iPhone 16', quantity: 1 }],
        accessories: [{ name: 'MagSafe case', quantity: 2 }], points: 10 },
        { normalized_staff_name: 'fiona', event_type: 'manual_adjustment',
          business_date: '2026-10-21', store_name: 'Toowong', points: 10,
          reason: 'Owner-requested device points credit' }], events: []
    } : { ok: true, staff: [], stores: [] }) });
  });
  await page.goto(pathToFileURL(path.resolve(__dirname, '..', 'stocktake-admin.html')).href);
  await page.locator('.review-staff-card').first().waitFor();
  const summary = await page.locator('.points-panel').innerText();
  if (!summary.includes('50.00 pts') || !summary.includes('Fiona') || !summary.includes('15.00 pts')) throw new Error('Score overview is missing');
  if (!/Products per transaction\s*2\.00/.test(await page.locator('[data-review-staff="fiona"]').innerText())) throw new Error('Fiona average is missing from the staff card');
  if (!/Products per transaction\s*1\.50/.test(await page.locator('[data-review-staff="bowen"]').innerText())) throw new Error('Bowen average is missing from the staff card');
  if (await page.locator('#reviewHistory').isVisible()) throw new Error('Review history should start collapsed');
  if (process.env.SCORE_SCREENSHOT) await page.screenshot({ path: process.env.SCORE_SCREENSHOT });
  await page.locator('[data-review-staff="fiona"]').click();
  if (!await page.locator('#scoreDetail').isVisible()) throw new Error('Staff detail did not open');
  const detail = await page.locator('#scoreDetail').innerText();
  if (!detail.includes('2.00') || !detail.includes('100') || !detail.includes('200') || !detail.includes('Products & repairs') || !detail.includes('$1,000.00')) throw new Error('Sales and average product metrics are missing');
  if (!detail.includes('Toowong') || !detail.includes('iPhone 16') || !detail.includes('MagSafe case ×2') || !detail.includes('Owner-requested device points credit')) throw new Error('Device history item names or adjustment are missing');
  if (!await page.locator('#reviewHistory').isVisible()) throw new Error('Review history did not open');
  await page.setViewportSize({ width: 390, height: 844 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  if (overflow > 0) throw new Error(`Staff points page overflows a phone by ${overflow}px`);
  await browser.close();
  console.log('Staff points page: overview and drilldown passed');
})().catch(error => { console.error(error); process.exit(1); });
