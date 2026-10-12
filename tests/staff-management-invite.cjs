const assert = require('node:assert/strict');
const { chromium } = require('playwright');
const { pathToFileURL } = require('node:url');
const path = require('node:path');

(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath: 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const errors = [];
  const actions = [];
  const stores = [{ store_code: 'toowong', store_name: 'Toowong' },
    { store_code: 'parkridge', store_name: 'Park Ridge' }];
  const staff = [{ staff_id: 1, display_name: 'Bowen', email: 'techm8contact@gmail.com',
    job_role: 'admin', active: true, stocktake_enabled: true, credentials_ready: true,
    assigned_stores: [] }];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/staff-auth.js*', route => route.fulfill({
    contentType: 'application/javascript',
    body: 'window.Techm8StaffAuth={getToken:()=>"test",init:()=>Promise.resolve()};'
  }));
  await page.route('**/functions/v1/pos-staff-management*', async route => {
    const request = route.request();
    const method = request.method();
    const url = request.url();
    const body = request.postDataJSON?.() || {};
    if (method === 'GET' && url.includes('mode=')) {
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify({
        ok: true, totals: {}, staff: [], events: [], device_events: []
      }) });
    }
    if (method === 'POST') {
      actions.push(body);
      if (body.action === 'create') {
        staff.push({ staff_id: 2, display_name: body.display_name, email: body.email,
          job_role: 'staff', active: true, stocktake_enabled: body.stocktake_enabled,
          credentials_ready: false,
          assigned_stores: body.store_codes.map(code => ({ store_code: code, store_name: stores.find(s => s.store_code === code).store_name })) });
      }
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true }) });
    }
    if (method === 'DELETE') {
      actions.push({ action: 'delete', ...body });
      staff.splice(staff.findIndex(row => row.staff_id === body.staff_id), 1);
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true }) });
    }
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, staff, stores }) });
  });
  try {
    await page.goto(pathToFileURL(path.resolve(__dirname, '..', 'stocktake-admin.html')).href);
    await page.locator('[data-staff-row="1"]').waitFor();
    assert.equal(await page.locator('[data-staff-row="1"] [data-delete-staff]').count(), 0);
    await page.locator('#addStaffBtn').click();
    await page.locator('#newStaffName').fill('New Colleague');
    await page.locator('#newStaffEmail').fill('new@example.com');
    await page.locator('#createStaffBtn').click();
    assert.match(await page.locator('#newStaffError').innerText(), /Select at least one store/);
    await page.locator('#newStaffStores label').filter({ hasText: 'Toowong' }).click();
    await page.locator('#createStaffBtn').click();
    await page.locator('[data-staff-row="2"]').waitFor();
    if (process.env.STAFF_SCREENSHOT) await page.screenshot({ path: process.env.STAFF_SCREENSHOT, fullPage: true });
    assert.deepEqual(actions[0], { action: 'create', display_name: 'New Colleague',
      email: 'new@example.com', store_codes: ['toowong'], stocktake_enabled: false });
    await page.locator('[data-staff-row="2"] [data-resend-staff]').click();
    await page.waitForFunction(() => document.querySelector('#toast').textContent.includes('Invitation sent'));
    assert.deepEqual(actions[1], { action: 'invite', staff_id: 2 });
    page.once('dialog', dialog => dialog.accept());
    await page.locator('[data-staff-row="2"] [data-delete-staff]').click();
    await page.locator('[data-staff-row="2"]').waitFor({ state: 'detached' });
    assert.deepEqual(actions[2], { action: 'delete', staff_id: 2 });
    const setupPage = await browser.newPage();
    const resetCalls = [];
    await setupPage.route('**/staff-auth.js*', route => route.fulfill({
      contentType: 'application/javascript',
      body: 'window.Techm8StaffAuth={storageIsPersistent:()=>true};'
    }));
    await setupPage.route('**/functions/v1/pos-staff-password-reset', route => {
      const payload = route.request().postDataJSON();
      resetCalls.push(payload);
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify(
        payload.action === 'verify'
          ? { ok: true, valid: true, first_setup: true, staff_name: 'New Colleague', staff_email: 'new@example.com' }
          : { ok: true }
      ) });
    });
    await setupPage.goto(pathToFileURL(path.resolve(__dirname, '..', 'index.html')).href + '?reset=' + 'a'.repeat(64));
    await setupPage.locator('#resetForm').waitFor({ state: 'visible' });
    assert.equal(await setupPage.locator('#resetPin').getAttribute('required'), '');
    assert.match(await setupPage.locator('#resetIntro').innerText(), /password and four-digit POS PIN/);
    await setupPage.locator('#resetPassword').fill('new-secret-pass');
    await setupPage.locator('#resetConfirmPassword').fill('new-secret-pass');
    await setupPage.locator('#resetPin').fill('4782');
    await setupPage.locator('#resetButton').click();
    await setupPage.locator('#loginStep').waitFor({ state: 'visible' });
    assert.deepEqual(resetCalls[1], { action: 'complete', token: 'a'.repeat(64),
      password: 'new-secret-pass', pin: '4782' });
    assert.deepEqual(errors, []);
    console.log('Staff management add, resend, delete and admin protection passed');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exit(1); });
