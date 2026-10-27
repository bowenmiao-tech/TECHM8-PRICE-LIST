// Runs in the staff/POS project. The website calls this after Stripe has told
// it (through the website's verified stripe-webhook) how a POS payment link went.
//
//   POST {action: 'paid', link_code, stripe_checkout_session_id, stripe_payment_intent_id, amount}
//        Records the payment on the invoice. Safe to repeat: Stripe retries.
//   POST {action: 'expired', stripe_checkout_session_id}
//        The customer never paid and Stripe closed the session.
//
// Both need the shared secret the two projects already use for used devices.

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
  const secret = Deno.env.get('USED_DEVICE_PUBLISH_SECRET');
  if (!url || !key || !secret) throw new Error('Online payment links are not configured.');
  return {url, secret, headers: {apikey: key, Authorization: `Bearer ${key}`}};
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

function sameSecret(given: string, expected: string) {
  if (!given || given.length !== expected.length) return false;
  let difference = 0;
  for (let index = 0; index < given.length; index += 1) difference |= given.charCodeAt(index) ^ expected.charCodeAt(index);
  return difference === 0;
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, {status: 204, headers: cors});
  if (request.method !== 'POST') return reply({ok: false, message: 'Method not allowed'}, 405);
  try {
    if (!sameSecret(request.headers.get('x-publish-secret') || '', config().secret)) {
      return reply({ok: false, message: 'Not allowed'}, 401);
    }
    const body = await request.json().catch(() => ({})) as RecordValue;
    if (body.action === 'paid') {
      return reply(await rpc('complete_pos_payment_link', {payload: {
        link_code: body.link_code,
        stripe_checkout_session_id: body.stripe_checkout_session_id,
        stripe_payment_intent_id: body.stripe_payment_intent_id,
        amount: body.amount,
      }}));
    }
    if (body.action === 'expired') {
      return reply(await rpc('expire_pos_payment_link', {payload: {
        stripe_checkout_session_id: body.stripe_checkout_session_id,
      }}));
    }
    return reply({ok: false, message: 'Unknown action'}, 400);
  } catch (error) {
    console.error(error);
    return reply({ok: false, message: error instanceof Error ? error.message : 'Payment link update failed'}, 500);
  }
});
