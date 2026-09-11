import assert from 'node:assert/strict';

let handler;
const calls = [];
let rejectAtomicCreate = false;

globalThis.Deno = {
  env: { get: name => name === 'SUPABASE_URL' ? 'https://backend.test' : 'server-only-key' },
  serve: fn => { handler = fn; }
};

globalThis.fetch = async (url, options = {}) => {
  calls.push({url, options});
  if (url.includes('/storage/v1/object/sign/repair-cards/')) {
    return Response.json({signedURL: '/object/sign/repair-cards/test?token=signed'});
  }
  if (url.includes('/storage/v1/object/repair-cards/')) {
    return Response.json({ok: true});
  }
  if (url.includes('/rpc/create_pos_repair_ticket_with_signature')) {
    const body = JSON.parse(options.body);
    if (rejectAtomicCreate) {
      return Response.json({message: 'Customer phone is required for repair tickets'}, {status: 400});
    }
    return Response.json({
      ok: true,
      ticket: {id: body.ticket_payload.ticket_code, customerName: 'Jane'},
      signature: {signed_customer_name: 'Jane', signature_path: 'toowong/test/signature.png'}
    });
  }
  if (url.includes('/rpc/save_pos_repair_card_signature')) {
    return Response.json({
      ok: true,
      signature: {signed_customer_name: 'Jane', signature_path: 'toowong/test/resign.png'}
    });
  }
  throw new Error(`Unexpected request ${url}`);
};

await import('../supabase/functions/pos-repair-cards/index.ts');

const signatureImage = 'data:image/png;base64,iVBORw0KGgo=';
const base = {
  store_code: 'toowong',
  ticket_code: 'RPR-ATOMIC-TEST',
  staff_name: 'Bowen',
  signed_customer_name: 'Jane',
  card_snapshot: {price: '$49.00'},
  terms_acknowledged: true,
  signature_image: signatureImage
};
const post = payload => handler(new Request('https://edge.test', {
  method: 'POST',
  headers: {'x-staff-session': 'test-token', 'Content-Type': 'application/json'},
  body: JSON.stringify({...base, ...payload})
}));

assert.equal((await handler(new Request('https://edge.test'))).status, 401);
assert.equal(calls.length, 0);
assert.equal((await post({ticket_payload: []})).status, 400);
assert.equal(calls.length, 0);

const created = await post({
  ticket_payload: {
    id: 'RPR-ATOMIC-TEST',
    ticket_code: 'RPR-ATOMIC-TEST',
    store_code: 'toowong',
    customerName: 'Jane',
    customerPhone: '0400000000',
    price: '$49.00'
  }
});
assert.equal(created.status, 200);
assert.equal((await created.json()).ticket.id, 'RPR-ATOMIC-TEST');
const atomicCall = calls.find(call => call.url.includes('/rpc/create_pos_repair_ticket_with_signature'));
const atomicBody = JSON.parse(atomicCall.options.body);
assert.equal(atomicBody.session_token, 'test-token');
assert.equal(atomicBody.ticket_payload.customerPhone, '0400000000');
assert.equal(atomicBody.signature_payload.signed_customer_name, 'Jane');

const resigned = await post({resign_reason: 'Customer corrected the signature'});
assert.equal(resigned.status, 200);
assert(calls.some(call => call.url.includes('/rpc/save_pos_repair_card_signature')));

rejectAtomicCreate = true;
const failed = await post({
  ticket_code: 'RPR-ROLLBACK-TEST',
  ticket_payload: {
    id: 'RPR-ROLLBACK-TEST',
    ticket_code: 'RPR-ROLLBACK-TEST',
    store_code: 'toowong',
    customerName: 'Jane',
    customerPhone: '',
    price: '$49.00'
  }
});
assert.equal(failed.status, 400);
assert.equal((await failed.json()).message, 'Customer phone is required for repair tickets');
assert(calls.some(call => call.url.includes('/storage/v1/object/repair-cards/') && call.options.method === 'DELETE'));

console.log('PASS: repair-card validation, atomic create routing, ordinary re-signing, exact backend errors, and rejected-signature cleanup.');
