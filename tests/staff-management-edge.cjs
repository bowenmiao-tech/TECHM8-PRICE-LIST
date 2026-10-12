const assert = require('node:assert/strict');

(async () => {
  let handler;
  const calls = [];
  const secret = 'test-internal-secret';
  global.Deno = {
    env: { get: name => ({
      SUPABASE_URL: 'https://staff.example', SUPABASE_SERVICE_ROLE_KEY: 'service-only',
      STAFF_RESET_RELAY_URL: 'https://mail.example/relay', STAFF_RESET_RELAY_SECRET: secret,
      STAFF_PORTAL_URL: 'https://portal.example'
    })[name] || '' },
    serve: callback => { handler = callback; }
  };
  global.fetch = async (url, options) => {
    calls.push({ url: String(url), options });
    if (String(url).includes('/rpc/create_staff_management')) {
      return Response.json({ ok: true, staff: { staff_id: 9 }, staff_name: 'Ada',
        staff_email: 'ada@example.com', invite_token: 'a'.repeat(64), expires_in_minutes: 30 });
    }
    if (String(url).includes('/rpc/archive_staff_management')) {
      return Response.json({ ok: true, staff_id: 9 });
    }
    return Response.json({ ok: true });
  };
  await import('../supabase/functions/pos-staff-management/index.ts');
  assert.equal(typeof handler, 'function');
  const unauthenticated = await handler(new Request('https://staff.example/manage', { method: 'GET' }));
  assert.equal(unauthenticated.status, 401);
  const created = await handler(new Request('https://staff.example/manage', {
    method: 'POST', headers: { 'x-admin-session': 'test-admin' },
    body: JSON.stringify({ display_name: 'Ada', email: 'ada@example.com', store_codes: ['toowong'] })
  }));
  assert.equal(created.status, 200);
  assert.deepEqual(await created.json(), { ok: true, staff: { staff_id: 9 }, staff_id: null,
    message: 'Invitation email sent.' });
  const relay = calls.find(call => call.url === 'https://mail.example/relay');
  assert.equal(relay.options.headers['X-Techm8-Relay-Secret'], secret);
  assert.deepEqual(JSON.parse(relay.options.body), {
    to: 'ada@example.com', staffName: 'Ada',
    link: `https://portal.example/?reset=${'a'.repeat(64)}`,
    minutes: 30, purpose: 'invite'
  });
  const deleted = await handler(new Request('https://staff.example/manage', {
    method: 'DELETE', headers: { 'x-admin-session': 'test-admin' },
    body: JSON.stringify({ staff_id: 9 })
  }));
  assert.equal(deleted.status, 200);
  assert.ok(calls.some(call => call.url.includes('/rpc/archive_staff_management')));
  console.log('Staff management edge: admin session, invite email and delete route passed');
})().catch(error => { console.error(error); process.exit(1); });
