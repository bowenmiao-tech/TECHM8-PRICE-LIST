// Runs in the staff/POS project. How the website's checkout and this project
// agree on who gets a second-hand device.
//
//   POST {action: 'hold', order_code, hold_kind, hold_until, device_codes, replaces, ...}
//        The website's checkout reserves devices against an order before the
//        customer pays. Needs the shared secret. Fails if a device is no longer
//        for sale or another order has it, and the website then refuses the order.
//   POST {action: 'release', order_code}
//        The website could not open payment for an order it just reserved for.
//        Needs the shared secret.
//   POST {action: 'sync'}
//        Asks the website how its orders went and applies the answer: paid is a
//        sale here, abandoned or cancelled frees the device. Called by cron. It
//        takes nothing from the caller but the request itself, because the
//        answer comes from the website, so it needs no secret.
//
// The website never holds this project's service key; the shared secret is
// the same one the publish worker uses in the other direction.

type RecordValue = Record<string, unknown>;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-publish-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function reply(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {status, headers: {...cors, 'Content-Type': 'application/json'}});
}

function config() {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const websiteUrl = Deno.env.get('WEBSITE_FUNCTIONS_URL');
  const secret = Deno.env.get('USED_DEVICE_PUBLISH_SECRET');
  if (!url || !key || !websiteUrl || !secret) throw new Error('Website orders for used devices are not configured.');
  return {url, websiteUrl, secret, headers: {apikey: key, Authorization: `Bearer ${key}`}};
}

async function rpc(name: string, body: RecordValue) {
  const {url, headers} = config();
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: {...headers, 'Content-Type': 'application/json'}, body: JSON.stringify(body),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || (data && data.ok === false)) throw new Error(data.message || 'The request could not be completed.');
  return data;
}

async function website(body: RecordValue) {
  const {websiteUrl, secret} = config();
  const response = await fetch(`${websiteUrl}/used-device-listings`, {
    method: 'POST',
    headers: {'Content-Type': 'application/json', 'x-publish-secret': secret},
    body: JSON.stringify(body),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.ok === false) throw new Error(data.message || 'The website did not answer.');
  return data;
}

function codes(value: unknown) {
  return Array.isArray(value)
    ? [...new Set(value.map(code => String(code || '').trim()).filter(code => /^USED-[A-Z0-9]{6,32}$/.test(code)))]
    : [];
}

async function sync(extra: string[]) {
  const known = await rpc('get_pos_used_device_online_sync_codes', {});
  const deviceCodes = [...new Set([...(Array.isArray(known) ? known : []), ...extra])];
  if (!deviceCodes.length) return {ok: true, checked: 0};
  const answer = await website({action: 'order-holds', device_codes: deviceCodes});
  const applied = await rpc('apply_pos_used_device_online_sync', {payload: {devices: answer.devices || []}});
  return {...applied, checked: deviceCodes.length};
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, {status: 204, headers: cors});
  if (request.method !== 'POST') return reply({ok: false, message: 'Method not allowed'}, 405);
  try {
    const input = (await request.json().catch(() => ({}))) as RecordValue;
    const action = String(input.action || '');

    if (action === 'sync') return reply(await sync(codes(input.device_codes)));

    const {secret} = config();
    if (request.headers.get('x-publish-secret') !== secret) {
      return reply({ok: false, message: 'Not authorised.'}, 403);
    }

    if (action === 'hold') {
      const deviceCodes = codes(input.device_codes);
      if (!deviceCodes.length) throw new Error('No devices to reserve.');
      return reply(await rpc('hold_pos_used_devices_online', {payload: {
        order_code: String(input.order_code || ''),
        hold_kind: String(input.hold_kind || 'checkout'),
        hold_until: input.hold_until || null,
        device_codes: deviceCodes,
        replaces: Array.isArray(input.replaces) ? input.replaces.map(String) : [],
        fulfillment_method: String(input.fulfillment_method || ''),
        store_slug: String(input.store_slug || ''),
        customer_name: String(input.customer_name || ''),
      }}));
    }

    if (action === 'release') {
      return reply(await rpc('release_pos_used_devices_online', {payload: {
        order_code: String(input.order_code || ''),
        reason: String(input.reason || ''),
      }}));
    }

    throw new Error('Unknown action.');
  } catch (error) {
    const message = error instanceof Error ? error.message : 'The request failed.';
    // A device that is gone or taken is an answer, not a fault.
    const status = /^USED_DEVICE_/.test(message) ? 409 : /configured/i.test(message) ? 500 : 400;
    return reply({ok: false, message}, status);
  }
});
