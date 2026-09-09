const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require('playwright');

(async () => {
  const root = path.resolve(__dirname, '..');
  for (const file of ['admin.html', 'pos.html']) {
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    for (const match of source.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) new Function(match[1]);
    assert(source.includes('repair-ticket-updates.js'));
    assert(source.includes('Techm8RepairUpdates.mount'));
  }
  const script = fs.readFileSync(path.join(root, 'repair-ticket-updates.js'), 'utf8');
  new Function(script);
  const browser = await chromium.launch({headless: true, channel: 'chrome'});
  try {
    const context = await browser.newContext({viewport: {width: 1100, height: 900}});
    const entries = [];
    let failPost = false;
    const errors = [];
    await context.route('https://repair.test/**', async route => {
      const url = new URL(route.request().url());
      if (url.pathname.includes('/functions/')) {
        const post = route.request().method() === 'POST';
        if (post && failPost) return route.fulfill({status: 500, json: {ok: false, message: 'Temporary failure'}});
        if (post) {
          const data = route.request().postDataJSON();
          assert.equal(data.ticket_code, 'TEST-REPAIR');
          assert.equal(data.store_code, 'toowong');
          if (!entries.some(entry => entry.id === data.id)) entries.push({...data, author: 'Bowen', created_at: new Date().toISOString(), image_url: data.kind === 'photo' ? 'https://repair.test/image.jpg' : undefined});
          return route.fulfill({json: {ok: true, id: data.id}});
        }
        return route.fulfill({json: {ok: true, writable: true, updates: entries}});
      }
      if (url.pathname === '/image.jpg') return route.fulfill({contentType: 'image/png', body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64')});
      return route.fulfill({contentType: 'text/html', body: `<!doctype html><meta name="viewport" content="width=device-width"><style>body{font-family:Arial;margin:0;background:#eff4f5}dialog{width: min(700px,calc(100% - 40px));max-height:85vh;border:1px solid #dce4e9;border-radius:8px;padding:20px} ${fs.readFileSync(path.join(root, 'repair-ticket-updates.css'),'utf8')}</style><dialog open><h2>Repair ticket</h2><div id="updates"></div></dialog><script>window.TECHM8_SUPABASE={url:'https://repair.test',anonKey:'test'};</script><script>${script}</script><script>window.options={ticketCode:'TEST-REPAIR',storeCode:'toowong',getToken:()=> 'test-token',mode:'all'};Techm8RepairUpdates.mount(document.querySelector('#updates'),options);</script>`});
    });
    const page = await context.newPage();
    page.on('pageerror', error => errors.push(error.message));
    await page.goto('https://repair.test/');
    await page.getByRole('textbox').waitFor();
    await page.waitForFunction(() => !document.querySelector('textarea').disabled);
    await page.getByRole('textbox').fill('Battery inspected. Customer approved replacement. <script>safe</script>');
    failPost = true;
    await page.getByRole('button', {name: 'Save comment'}).click();
    await page.getByText('Temporary failure').waitFor();
    assert((await page.getByRole('textbox').inputValue()).includes('Battery inspected'));
    failPost = false;
    await page.getByRole('button', {name: 'Save comment'}).click();
    await page.getByText('Comment saved.').waitFor();
    assert.equal(entries.length, 1);
    assert.equal(await page.getByRole('textbox').inputValue(), '');
    const png = await page.screenshot();
    await page.locator('input[type=file]').setInputFiles({name: 'inspection.png', mimeType:'image/png', buffer:png});
    await page.getByText('Images saved.').waitFor();
    assert.equal(entries.length, 2);
    assert(entries[1].data_url.startsWith('data:image/jpeg;base64,'));
    assert(await page.locator('.rtu-photo img').evaluate(img => img.complete && img.naturalWidth > 0));
    await page.getByRole('textbox').fill('Draft survives tab changes');
    await page.evaluate(() => Techm8RepairUpdates.mount(document.querySelector('#updates'), options));
    assert.equal(await page.getByRole('textbox').inputValue(), 'Draft survives tab changes');
    await page.waitForFunction(() => !document.querySelector('textarea').disabled);
    await page.getByRole('textbox').focus();
    await page.evaluate(async () => {
      const canvas = document.createElement('canvas'); canvas.width=300; canvas.height=100;
      const ctx=canvas.getContext('2d'); ctx.fillStyle='#008b79'; ctx.fillRect(0,0,300,100);
      const blob = await new Promise(resolve => canvas.toBlob(resolve));
      const data = new DataTransfer(); data.items.add(new File([blob], 'Screenshot.png', {type:'image/png'}));
      document.querySelector('textarea').dispatchEvent(new ClipboardEvent('paste',{clipboardData:data,bubbles:true,cancelable:true}));
    });
    await page.waitForFunction(() => document.querySelectorAll('.rtu-photo').length === 2);
    assert.equal(entries.length, 3);
    // A separate portal loads the same saved records, not the first tab's cache.
    const admin = await context.newPage(); await admin.goto('https://repair.test/');
    await admin.waitForFunction(() => document.querySelectorAll('.rtu-photo').length === 2);
    assert.equal(await admin.locator('.rtu-comment').count(),1);
    await admin.addStyleTag({content:'dialog{box-sizing:border-box}'});
    assert.equal(await admin.getByRole('button', {name:'Retry upload'}).count(), 0);
    const output = path.join(process.env.TEMP || root, 'repair-updates-desktop.png');
    await admin.screenshot({path:output,fullPage:true});
    await admin.setViewportSize({width:390,height:844});
    await admin.screenshot({path:path.join(process.env.TEMP || root,'repair-updates-mobile.png'),fullPage:true});
    assert(await admin.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    assert.equal(errors.length, 0, errors.join('\n'));
    console.log('PASS: syntax, portal wiring, comments, escaped content, retry, file upload, image paste, draft retention, shared records, mobile layout.');
    console.log('Screenshots: '+ output);
  } finally { await browser.close(); }
})().catch(error => {console.error(error); process.exitCode=1;});
