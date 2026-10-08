// Exercise production shift/transfer functions with mocked transport, no live writes.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '../pos.html'), 'utf8');
function extract(start, end) {
  const at = source.indexOf(`    ${start}`);
  assert.ok(at >= 0);
  return source.slice(at, source.indexOf(`    ${end}`, at));
}
function fixture() {
  const remote = {id:'SHIFT-SHARED',business_date:'2026-10-09',status:'open',opened_by:'Bowen',current_staff_name:'Bowen',last_staff_name:'Bowen'};
  let local = {id:'SHIFT-OLD',date:'2026-10-09',status:'open',storeId:'north-lakes'};
  const calls = [];
  const ctx = {Headers, Date, Object, Error, console:{error(){}},
    state:{selectedStaffName:'Jinny',storeId:'north-lakes'},
    readActiveShift:()=>local,clearActiveShiftCache:()=>{local=null;},
    writeActiveShift:v=>{local=v;},loadOpeningRecords:()=>({'SHIFT-OLD':{total:250}}),
    getSharedState:async()=>({shift:remote}),
    postSharedState:async()=>{throw Error('Must not open or change a shift for transfers');},
    cacheRemoteShiftOpening:()=>{},brisbaneDateIso:()=> '2026-10-09',
    storeById:()=>({code:'NL'}),repairTicketStoreCode:()=> 'northlakes',
    window:{Techm8StaffAuth:{getToken:()=> 'test-token'}},
    fetch:async(url,options)=>{calls.push({url,options});return {ok:true,json:async()=>({ok:true})};}
  };
  vm.createContext(ctx);
  vm.runInContext(extract('function localShiftFromRemote(', 'function cacheRemoteShiftOpening(')
    + extract('async function syncCurrentShiftWithDatabase(', 'function loadStaffSchedule(')
    + extract('function transferApiHeaders(', 'async function loadTransferContext('), ctx);
  return {ctx,remote,calls,local:()=>local};
}
(async()=>{
  const ok = fixture();
  await ok.ctx.transferApiRequest('/transfer',{method:'POST',headers:{'Content-Type':'application/json','x-pos-shift':'SHIFT-OLD'},body:'{"staff_name":"Jinny"}'});
  assert.equal(ok.local().currentStaffName,'Jinny','Local operator must remain Jinny for session resume');
  assert.equal(ok.remote.current_staff_name,'Bowen','The shared shift can retain another terminal operator');
  assert.equal(ok.ctx.state.selectedStaffName,'Jinny');
  assert.equal(ok.calls.length,1);
  assert.equal(ok.calls[0].options.headers.get('x-pos-shift'),'SHIFT-SHARED');
  assert.equal(ok.calls[0].options.headers.get('Content-Type'),'application/json');
  assert.equal(ok.calls[0].options.body,'{"staff_name":"Jinny"}');

  const offline = fixture(); offline.ctx.getSharedState = async()=>{throw Error('Offline');};
  await assert.rejects(()=>offline.ctx.transferApiRequest('/transfer'),/Offline/);
  assert.equal(offline.calls.length,0,'Never use cached shift when verification fails');
  const closed = fixture(); closed.ctx.getSharedState = async()=>({shift:null});
  await assert.rejects(()=>closed.ctx.transferApiRequest('/transfer'),/Start today/);
  assert.equal(closed.calls.length,0,'Do not recreate a closed shift from cached opening cash');
  const stale = fixture(); stale.remote.business_date='2026-10-08';
  await assert.rejects(()=>stale.ctx.transferApiRequest('/transfer'),/invalid business-date/);
  assert.equal(stale.calls.length,0);
  const changed = fixture(); changed.ctx.getSharedState=async()=>{changed.ctx.state.storeId='toowong';return {shift:changed.remote};};
  await assert.rejects(()=>changed.ctx.transferApiRequest('/transfer'),/changed/);
  assert.equal(changed.local().id,'SHIFT-OLD','Do not cache a response against a newly selected store');
  assert.equal(changed.calls.length,0);
  const failed = fixture(); failed.ctx.fetch=async()=>{failed.calls.push(1);return {ok:false,status:403,json:async()=>({message:'Shift closed during request'})};};
  await assert.rejects(()=>failed.ctx.transferApiRequest('/transfer',{method:'POST'}),/Shift closed/);
  assert.equal(failed.calls.length,1,'Never replay a stock mutation automatically');
  console.log('PASS: shared shift, fresh headers, offline, closed, stale, changed store, no mutation replay');
})().catch(error=>{console.error(error);process.exitCode=1;});
