import assert from 'node:assert/strict';
let handler;const calls=[];
globalThis.Deno={env:{get:name=>name==='SUPABASE_URL'?'https://backend.test':'server-key'},serve:fn=>handler=fn};
globalThis.fetch=async(url,options)=>{const body=JSON.parse(options.body);calls.push({url,body});return Response.json(url.endsWith('pos_authorized_actor')?{ok:true,store_code:'toowong',staff_name:'Verified staff'}:{ok:true});};
await import('../supabase/functions/pos-repair-tickets/index.ts');
const request=(method,body,token='session')=>handler(new Request('https://edge.test',{method,headers:{'x-staff-session':token,'Content-Type':'application/json'},body:JSON.stringify(body)}));
const base={store_code:'toowong',ticket_code:'MEMO-test'};
assert.equal((await request('POST',{...base,action:'create-memo'},'')).status,401);
for(const action of ['create-memo','save-memo','move-memo','finish-memo']){
 assert.equal((await request('POST',{...base,action,staff_name:'Spoofed'})).status,200);
 assert(calls.at(-1).url.endsWith('/manage_pos_repair_memo'));
 assert.equal(calls.at(-1).body.payload.staff_name,'Verified staff');
}
assert.equal((await request('PUT',{...base,price:'0'})).status,400);
assert.equal((await request('PUT',{...base,price:'99'})).status,200);
assert(calls.at(-1).url.endsWith('/upsert_pos_repair_ticket'));
console.log('PASS: memo actions routed with verified actor; session required; standard repair price validation retained.');
