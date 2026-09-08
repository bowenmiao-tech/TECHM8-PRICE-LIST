import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const html = fs.readFileSync('pos.html', 'utf8');
for (const script of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) {
  if (script[1].trim()) new vm.Script(script[1]);
}
const functions = ['numberValue', 'roundedMoneyValue', 'paymentPaidTotal', 'paymentSessionTotal', 'paymentRemaining', 'renderPaymentChangePreview', 'confirmPaymentAmount'];
const ctx = vm.createContext({
  state: {paymentSession: {method:'Cash',payments:[]}},
  els: {paymentAmountInput:{value:''},paymentChangePreview:{},paymentError:{}},
  cartTotal: () => 179,
  money: value => '$' + Number(value).toFixed(2),
  closePaymentModal(){}, showToast(){}, setPaymentAmountToRemaining(){}, renderPaymentModal(){},
  checkout(payments){ctx.saved = payments;},
  submitBalancePayment(id,payments){ctx.saved = payments;}
});
for (const name of functions) {
  const start = html.indexOf('    function ' + name + '(');
  const next = /\n    (?:async )?function /.exec(html.slice(start + 5));
  vm.runInContext(html.slice(start, start + 5 + next.index), ctx);
}
for (const [amount,expected,hidden] of [['200','Change $21.00',false],['179','Change $0.00',false],['100','Change $0.00',false],['200.10','Change $21.10',false],['','',true],['-1','',true]]) {
  ctx.els.paymentAmountInput.value = amount;
  ctx.renderPaymentChangePreview();
  assert.equal(ctx.els.paymentChangePreview.textContent,expected);
  assert.equal(ctx.els.paymentChangePreview.hidden,hidden);
}
ctx.state.paymentSession.payments = [{method:'Card',amount:100}];
ctx.els.paymentAmountInput.value = '100';
ctx.renderPaymentChangePreview();
assert.equal(ctx.els.paymentChangePreview.textContent,'Change $21.00');
ctx.confirmPaymentAmount(false);
assert.equal(ctx.saved[1].amount,79);
assert.equal(ctx.saved.reduce((sum,p)=>sum+p.amount,0),179);
ctx.state.paymentSession = {method:'Cash',payments:[],balanceOrderId:'TEST',balanceTotal:29};
ctx.els.paymentAmountInput.value = '50';
ctx.renderPaymentChangePreview();
assert.equal(ctx.els.paymentChangePreview.textContent,'Change $21.00');
ctx.confirmPaymentAmount(false);
assert.equal(ctx.saved[0].amount,29);
ctx.state.paymentSession = {method:'Card',payments:[]};
ctx.els.paymentAmountInput.value = '200';
ctx.renderPaymentChangePreview();
assert.equal(ctx.els.paymentChangePreview.hidden,true);
ctx.confirmPaymentAmount(false);
assert.equal(ctx.state.paymentSession.payments.length,0);
assert.equal(ctx.els.paymentError.textContent,'Amount cannot exceed $179.00.');
console.log('PASS: syntax, live cash change, exact/partial/empty/invalid input, decimal cents, split payment, balance payment, cash amount capped, card overpayment rejected.');
