const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');

const sourcePath = path.join(__dirname, '..', 'supabase', 'functions', 'pos-used-devices', 'index.ts');
const source = stripTypeScriptTypes(fs.readFileSync(sourcePath, 'utf8'), { mode: 'strip' })
  .replace(/^import .*;\s*$/gm, '');

async function exercise({ deviceStore = 2, websiteOk = true } = {}) {
  const calls = [];
  let handler;
  const fetch = async (input, options = {}) => {
    const url = String(input);
    const body = options.body ? JSON.parse(options.body) : {};
    calls.push({ url, body });
    if (url.endsWith('/rpc/pos_authorized_actor')) {
      return Response.json({ ok: true, store_id: 2, store_code: 'parkridge', staff_name: 'Joanna Chen' });
    }
    if (url.includes('/rest/v1/pos_used_devices?')) {
      return Response.json([{ device_code: 'USED-902AB9454260', store_id: deviceStore,
        status: 'ready_for_sale', online_order_code: 'TM8-20261004-468AFF', online_hold_kind: 'reserved' }]);
    }
    if (url.endsWith('/used-device-listings')) {
      return websiteOk
        ? Response.json({ ok: true, order_code: 'TM8-20261004-468AFF' })
        : Response.json({ ok: false, message: 'This order may have a payment.' }, { status: 400 });
    }
    if (url.endsWith('/rpc/release_pos_used_devices_online')) {
      return Response.json({ ok: true, devices: ['USED-902AB9454260'] });
    }
    throw new Error(`Unexpected request: ${url}`);
  };
  vm.runInNewContext(source, {
    Deno: { env: { get: name => ({ SUPABASE_URL: 'https://staff.test', SUPABASE_SERVICE_ROLE_KEY: 'server-key',
      WEBSITE_FUNCTIONS_URL: 'https://website.test', USED_DEVICE_PUBLISH_SECRET: 'shared-secret' })[name] },
    serve: fn => { handler = fn; } },
    fetch, Request, Response, URL, URLSearchParams, crypto, console, TextEncoder, TextDecoder, Uint8Array, atob,
  }, { filename: sourcePath });
  const request = new Request('https://staff.test/functions/v1/pos-used-devices', {
    method: 'POST', headers: { 'x-staff-session': 'staff-session', 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'restore-online-reservation', payload: {
      store_code: 'parkridge', staff_name: 'Joanna Chen',
      device_code: 'USED-902AB9454260', order_code: 'TM8-20261004-468AFF'
    } })
  });
  const response = await handler(request);
  return { status: response.status, body: await response.json(), calls };
}

async function exerciseWebsite(secret) {
  const sourcePath = path.join(__dirname, '..', 'supabase', 'functions', 'used-device-listings', 'index.ts');
  const websiteSource = stripTypeScriptTypes(fs.readFileSync(sourcePath, 'utf8'), { mode: 'strip' });
  const calls = [];
  let handler;
  vm.runInNewContext(websiteSource, {
    Deno: { env: { get: name => ({ SUPABASE_URL: 'https://website.test', SUPABASE_SERVICE_ROLE_KEY: 'server-key',
      USED_DEVICE_PUBLISH_SECRET: 'shared-secret' })[name] }, serve: fn => { handler = fn; } },
    fetch: async (url, options) => {
      calls.push({ url, body: JSON.parse(options.body) });
      return Response.json({ ok: true, cancelled: true });
    },
    Request, Response, URL, Uint8Array, console, atob,
  }, { filename: sourcePath });
  const response = await handler(new Request('https://website.test/functions/v1/used-device-listings', {
    method: 'POST', headers: { 'x-publish-secret': secret, 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'cancel-unpaid-reservation', device_code: 'USED-902AB9454260',
      order_code: 'TM8-20261004-468AFF', store_code: 'parkridge', actor: 'Joanna Chen' })
  }));
  return { status: response.status, calls };
}

(async () => {
  const restored = await exercise();
  assert.equal(restored.body.ok, true);
  assert.deepEqual(restored.calls.map(call => new URL(call.url).pathname.split('/').pop()),
    ['pos_authorized_actor', 'pos_used_devices', 'used-device-listings', 'release_pos_used_devices_online']);
  assert.equal(restored.calls[2].body.order_code, 'TM8-20261004-468AFF');
  assert.equal(restored.calls[2].body.actor, 'Joanna Chen');

  const wrongStore = await exercise({ deviceStore: 5 });
  assert.equal(wrongStore.status, 403);
  assert.equal(wrongStore.calls.length, 2, 'A different store reached the website cancellation step');

  const paid = await exercise({ websiteOk: false });
  assert.equal(paid.status, 409);
  assert.equal(paid.calls.length, 3, 'POS released a reservation after the website refused cancellation');

  const website = await exerciseWebsite('shared-secret');
  assert.equal(website.status, 200);
  assert.equal(website.calls.length, 1);
  assert.equal(website.calls[0].body.target_device_code, 'USED-902AB9454260');
  assert.equal(website.calls[0].body.target_actor, 'Joanna Chen');
  const unauthorised = await exerciseWebsite('wrong-secret');
  assert.equal(unauthorised.status, 403);
  assert.equal(unauthorised.calls.length, 0, 'Unauthorised cancellation reached the database');
  console.log('PASS: restore order, store access and paid-order refusal');
})().catch(error => { console.error(error); process.exitCode = 1; });
