const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const server = http.createServer((request, response) => {
  const pathname = new URL(request.url, 'http://localhost').pathname;
  const file = path.join(root, pathname.replace(/^\//, ''));
  if (!['quote.html', 'ipad-model-labels.js', 'data.json'].includes(path.basename(file))) {
    response.writeHead(404).end();
    return;
  }
  response.setHeader('Content-Type', file.endsWith('.js') ? 'application/javascript' : file.endsWith('.json') ? 'application/json' : 'text/html');
  fs.createReadStream(file).pipe(response);
});

(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({
    headless: true,
    executablePath: 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
  });
  try {
    const page = await browser.newPage();
    await page.route('**/supabase-config.js*', route => route.fulfill({ contentType: 'application/javascript', body: 'window.TECHM8_SUPABASE=null;' }));
    await page.route('**/staff-auth.js*', route => route.fulfill({ contentType: 'application/javascript', body: 'window.Techm8StaffAuth={init:()=>Promise.resolve()};' }));
    const response = await page.goto(`http://127.0.0.1:${server.address().port}/quote.html`);
    assert.equal(response.status(), 200);
    await page.locator('select.form-select').nth(0).selectOption('Apple iPad');
    const modelSelect = page.locator('select.form-select').nth(1);
    const pro = modelSelect.locator('option[value="iPad Pro 13 (2024)"]');
    await pro.waitFor({ state: 'attached' });
    assert.equal(await pro.innerText(), 'iPad Pro 13 (2024) (A2925 A2926 A3007)');
    const air = modelSelect.locator('option[value^="iPad AIR 6 (2024)"]');
    assert(!/A2786|A2787|A2788/.test(await air.innerText()));
    await modelSelect.selectOption('iPad Pro 13 (2024)');
    assert.equal(await modelSelect.inputValue(), 'iPad Pro 13 (2024)');
    assert((await page.locator('select.form-select').nth(2).locator('option').count()) > 1);
    console.log('PASS: iPad dropdown shows A-models while keeping the original quote value.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); server.close(); process.exit(1); });
