const fs=require('node:fs'),http=require('node:http'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
// iPad Safari opens the keyboard by shrinking window.visualViewport and
// scrolling it down to the field; the layout viewport keeps its full height.
// Chrome cannot show that keyboard, so the test drives a stand-in viewport.
(async()=>{
 const root=path.resolve(__dirname,'..');
 const server=http.createServer((req,res)=>{try{const name=new URL(req.url,'http://localhost').pathname;res.setHeader('Content-Type',name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(path.join(root,name)));}catch{res.writeHead(404).end();}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({channel:'chrome',headless:true});
 try {
 const page=await browser.newPage({viewport:{width:1180,height:820},isMobile:true,hasTouch:true}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 await page.route('https://**/*',route=>route.abort());
 await page.addInitScript(()=>{
  const view=new EventTarget();
  Object.assign(view,{width:innerWidth,height:innerHeight,offsetTop:0,offsetLeft:0,pageTop:0,pageLeft:0,scale:1});
  Object.defineProperty(window,'visualViewport',{configurable:true,get:()=>view});
  window.setKeyboard=(height,offsetTop)=>{Object.assign(view,{height,offsetTop,pageTop:offsetTop});view.dispatchEvent(new Event('resize'));view.dispatchEvent(new Event('scroll'));};
 });
 await page.goto(`http://127.0.0.1:${server.address().port}/pos.html?dashboard-test`);
 const frames=()=>page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>requestAnimationFrame(r)))));

 assert.match(await page.locator('meta[name=viewport]').getAttribute('content'),/maximum-scale=1/,'Fields under 16px would zoom on focus');
 assert.equal(await page.locator('.pos-app').evaluate(el=>getComputedStyle(el).position),'fixed');

 // Keyboard opens over the cart's customer field: 450px left, view scrolled 370px down.
 await page.evaluate(()=>setKeyboard(450,370));await frames();
 const app=await page.locator('.pos-app').boundingBox();
 assert.deepEqual([Math.round(app.y),Math.round(app.height)],[370,450],'App must fill exactly the part above the keyboard');
 const customer=await page.locator('#customerInput').boundingBox();
 assert(customer.y>=370&&customer.y+customer.height<=820,`Customer field hidden: ${JSON.stringify(customer)}`);

 // A field below the new bottom edge of its scrolling panel is brought into view.
 await page.evaluate(()=>setKeyboard(820,0));await frames();
 const panel='#targetDashboard';
 await page.evaluate(panel=>{const box=document.querySelector(panel);box.insertAdjacentHTML('beforeend','<input id="probeField" type="text">');box.scrollTop=0;},panel);
 const inView=()=>page.evaluate(()=>{const r=document.getElementById('probeField').getBoundingClientRect(),v=visualViewport;return r.height>0&&r.top>=v.offsetTop&&r.bottom<=v.offsetTop+v.height;});
 assert.equal(await inView(),false,'Probe must start below the fold');
 await page.evaluate(()=>document.getElementById('probeField').focus({preventScroll:true}));
 await page.waitForTimeout(450);
 assert(await inView(),'Focused field not scrolled into view');
 await page.evaluate(panel=>{document.querySelector(panel).scrollTop=0;},panel);
 assert.equal(await inView(),false);
 await page.evaluate(()=>setKeyboard(420,0));await frames();
 assert(await inView(),'Field left under the keyboard after it opened');

 // Keyboard closes: the app returns to the full screen.
 await page.evaluate(()=>setKeyboard(820,0));await frames();
 const closed=await page.locator('.pos-app').boundingBox();
 assert.deepEqual([Math.round(closed.y),Math.round(closed.height)],[0,820]);

 // Phones keep the sideways-scrolling document.
 await page.setViewportSize({width:700,height:820});
 assert.equal(await page.locator('.pos-app').evaluate(el=>getComputedStyle(el).position),'static');
 assert.equal(errors.length,0,errors.join('\n'));
 console.log('PASS: no focus zoom; app pinned to the area above the keyboard with no gap; hidden field scrolled into view on focus and on keyboard open; full height restored; phone layout unchanged.');
 } finally {await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exitCode=1;});
