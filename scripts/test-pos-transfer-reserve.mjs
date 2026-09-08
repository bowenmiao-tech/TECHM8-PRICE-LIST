import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
const html = fs.readFileSync('pos.html','utf8');
for (const script of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) {
  if (script[1].trim()) new vm.Script(script[1]);
}
function source(name) {
  const start = html.indexOf('    function '+name+'(');
  const next = /\n    (?:async )?function /.exec(html.slice(start+5));
  assert.ok(start >= 0 && next, name);
  return html.slice(start,start+5+next.index);
}
const browser=await chromium.launch({headless:true,channel:process.env.PLAYWRIGHT_CHANNEL || 'msedge'});
try {
  const page=await browser.newPage({viewport:{width:1100,height:1000}});
  const css=[...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/gi)][0][1];
  await page.setContent('<style>'+css+'</style><main style="max-width:980px;margin:auto;padding:24px"><h2>New Stock Transfer</h2><p id="help"></p><div id="body"></div></main>');
  await page.addScriptTag({content:`
    const state = {storeId:'park-ridge',prTransferReserves:{'10':999,'11':0},transferDraft:{source:'park-ridge',destination:'toowong',items:[],search:'',note:''},
      transferStores:[{slug:'park-ridge',name:'Park Ridge'},{slug:'toowong',name:'Toowong'},{slug:'north-lakes',name:'North Lakes'}],
      products:[{id:10,name:'Screen protector',sku:'TEST-10',store_inventory:[{store_slug:'park-ridge',quantity:-2},{store_slug:'toowong',quantity:4},{store_slug:'north-lakes',quantity:3}]}]};
    const els={transferModalBody:document.getElementById('body')};
    const escapeHtml = value => String(value ?? '').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
    const productImage = () => 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="80" height="80"><rect width="80" height="80" fill="lightgray"/></svg>';
    const openTransferModalShell=(title,subtitle)=>document.getElementById('help').textContent=subtitle;
    const stopTransferScanner=()=>{};
    const showToast=()=>{};
    ${['normalizeStoreKey','getProductStock','transferProductStock','transferStoreOptions','transferProductMatches','transferSearchProducts','renderTransferProductResults','renderNewTransferModal','addTransferDraftProduct'].map(source).join('\n')}
    window.runChecks=()=>{
      const p=state.products[0];
      const checks=[transferProductStock(p,'park-ridge')===999,getProductStock(p)===-2,
        transferProductStock(p,'toowong')===4,transferProductStock(p,'north-lakes')===3,
        transferProductStock({id:11},'park-ridge')===0,transferProductStock({id:999999},'park-ridge')===0];
      renderNewTransferModal();
      return checks;
    };
    document.addEventListener('click',event=>{
      const b=event.target.closest('[data-transfer-add-product]');
      if(b) addTransferDraftProduct(b.dataset.transferAddProduct);
    });
    window.testState=state;
  `});
  assert.ok((await page.evaluate(()=>window.runChecks())).every(Boolean));
  await page.getByRole('button',{name:'Add',exact:true}).click();
  assert.equal(await page.getByRole('spinbutton',{name:'Transfer quantity'}).getAttribute('max'),'999');
  await page.getByRole('spinbutton',{name:'Transfer quantity'}).fill('5');
  fs.mkdirSync('.codex-temp/transfer-reserve-tests',{recursive:true});
  await page.screenshot({path:'.codex-temp/transfer-reserve-tests/desktop.png',fullPage:true});
  await page.setViewportSize({width:390,height:844});
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  await page.screenshot({path:'.codex-temp/transfer-reserve-tests/mobile.png',fullPage:true});
  console.log('PASS: syntax, PR transfer 999, actual PR stock preserved, TW/NL stock preserved, exhausted/unknown reserve fail closed, adding PR product and quantity cap, desktop/mobile rendering.');
} finally {await browser.close();}
