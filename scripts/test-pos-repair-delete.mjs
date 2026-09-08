import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const html = fs.readFileSync('pos.html','utf8');
for (const script of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) {
  if (script[1].trim()) new vm.Script(script[1]);
}
const start = html.indexOf('    const deletingRepairTickets =');
const end = html.indexOf('    function currentStaffName',start);
function setup({confirmed=true,saved=true,pending=false}={}) {
  const ctx=vm.createContext({
    state:{repairTickets:[{id:'T1',title:'Phone',syncPending:pending},{id:'T2'}],cart:[{ticket_id:'T1'},{ticket_id:'T2'}],repair:{ticketId:'T1'},selectedTicketId:'T1',ticketCardSignatures:{T1:{}}},
    confirm:()=>confirmed,showToast(){},saveRepairTickets(){},renderCart(){},renderRepairWorkspace(){},
    closeTicketDetailModal(){ctx.state.selectedTicketId='';},resetRepairState(){ctx.state.repair={ticketId:''};},
    async deleteRepairTicketFromDatabase(){ctx.calls=(ctx.calls||0)+1; return saved;}
  });
  vm.runInContext(html.slice(start,end),ctx);
  return ctx;
}
for (const options of [{confirmed:false},{saved:false},{pending:true}]) {
  const ctx=setup(options);
  assert.equal(await ctx.deleteRepairTicket('T1'),false);
  assert.equal(ctx.state.repairTickets.length,2);
  assert.equal(ctx.state.cart.length,2);
}
const ctx=setup();
const button={disabled:false,innerHTML:'Delete'};
const first=ctx.deleteRepairTicket('T1',button);
assert.equal(button.disabled,true);
assert.equal(await ctx.deleteRepairTicket('T1',button),false);
assert.equal(await first,true);
assert.equal(ctx.calls,1);
assert.equal(ctx.state.repairTickets.length,1);
assert.equal(ctx.state.repairTickets[0].id,'T2');
assert.equal(ctx.state.cart.length,1);
assert.equal(ctx.state.cart[0].ticket_id,'T2');
assert.equal(ctx.state.selectedTicketId,'');
assert.equal(button.disabled,false);
console.log('PASS: syntax, cancellation, failure preserves ticket/cart, pending save protected, double-click guarded, success removes only target and closes details. No real tickets deleted.');
