// Carries queued website intentions from the staff/POS project across to the
// website catalogue.
//
// Two projects, no shared transaction: the queue is the record of what should
// happen, and this worker is the only thing that makes it happen. Every step is
// safe to repeat, because a queue item is only marked complete after the
// website has confirmed it, and the website rejects a version older than the
// one it already holds.
//
// Called three ways:
//   POST {}                       - drain the queue (cron, or by hand)
//   POST {store_code, device_code, action} with a staff session - one device
//   GET  ?store_code&device_code   - what the POS shows on the device

type RecordValue = Record<string, unknown>;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-staff-session, x-publish-worker',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const sourceBucket = 'used-device-photos';

function reply(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {status, headers: {...cors, 'Content-Type': 'application/json'}});
}

function config() {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const websiteUrl = Deno.env.get('WEBSITE_FUNCTIONS_URL');
  const secret = Deno.env.get('USED_DEVICE_PUBLISH_SECRET');
  if (!url || !key || !websiteUrl || !secret) throw new Error('Used device publishing is not configured.');
  return {url, websiteUrl, secret, headers: {apikey: key, Authorization: `Bearer ${key}`}};
}

async function rpc(name: string, body: RecordValue) {
  const {url, headers} = config();
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: {...headers, 'Content-Type': 'application/json'}, body: JSON.stringify(body),
  });
  const data = await response.json();
  if (!response.ok || data.ok === false) throw new Error(data.message || 'The publish request failed.');
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
  if (!response.ok || data.ok === false) throw new Error(data.message || 'The website rejected the listing.');
  return data;
}

async function readPrivateImage(path: string) {
  const {url, headers} = config();
  const response = await fetch(`${url}/storage/v1/object/${sourceBucket}/${path}`, {headers});
  if (!response.ok) throw new Error('A listing photo could not be read.');
  const bytes = new Uint8Array(await response.arrayBuffer());
  let binary = '';
  for (let index = 0; index < bytes.length; index += 1) binary += String.fromCharCode(bytes[index]);
  return `data:image/jpeg;base64,${btoa(binary)}`;
}

// One queue item, end to end. Throwing here is expected: the caller records the
// message against the item and it is retried.
async function runItem(item: RecordValue) {
  const listing = (item.listing || {}) as RecordValue;
  const deviceCode = String(listing.device_code || '');
  const action = String(item.action || '');
  const sourceVersion = item.source_version;

  if (action === 'withdraw' || action === 'sold') {
    await website({action, device_code: deviceCode, source_version: sourceVersion});
    return '';
  }

  const sourceImages = Array.isArray(listing.images) ? listing.images as RecordValue[] : [];
  if (!sourceImages.length) throw new Error('This device has no listing photos.');

  const images: RecordValue[] = [];
  for (const image of sourceImages) {
    const position = Number(image.position) || images.length + 1;
    const uploaded = await website({
      action: 'upload-image',
      device_code: deviceCode,
      position,
      data_url: await readPrivateImage(String(image.storage_path)),
    });
    images.push({url: uploaded.url, position});
  }

  const result = await website({
    action: 'publish',
    device_code: deviceCode,
    source_version: sourceVersion,
    listing: {
      device_category: listing.device_category,
      store_code: listing.store_code,
      title: listing.title,
      brand: listing.brand,
      model: listing.model,
      storage: listing.storage,
      color: listing.color,
      condition_grade: listing.condition_grade,
      condition_summary: listing.condition_summary,
      battery_health: listing.battery_health,
      price: listing.price,
      description: listing.description,
      highlights: listing.highlights,
      images,
    },
  });
  return String(result.slug || '');
}

async function drain(limit: number) {
  const batch = await rpc('claim_pos_used_device_publish_batch', {batch_limit: limit});
  const items = Array.isArray(batch.items) ? batch.items as RecordValue[] : [];
  const results: RecordValue[] = [];
  for (const item of items) {
    try {
      const slug = await runItem(item);
      await rpc('complete_pos_used_device_publish', {payload: {queue_id: item.queue_id, ok: 'true', slug}});
      results.push({queue_id: item.queue_id, ok: true, slug});
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Publishing failed.';
      await rpc('complete_pos_used_device_publish', {payload: {queue_id: item.queue_id, ok: 'false', error: message}});
      results.push({queue_id: item.queue_id, ok: false, message});
    }
  }
  return results;
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, {status: 204, headers: cors});
  if (!['GET', 'POST'].includes(request.method)) return reply({ok: false, message: 'Method not allowed'}, 405);
  try {
    const url = new URL(request.url);
    const token = request.headers.get('x-staff-session') || '';

    if (request.method === 'GET') {
      if (!token) return reply({ok: false, message: 'Sign in to view website status.'}, 401);
      const data = await rpc('get_pos_used_device_website_status', {
        session_token: token,
        store_code: url.searchParams.get('store_code') || '',
        device_code: url.searchParams.get('device_code') || '',
      });
      return reply(data);
    }

    const input = await request.json().catch(() => ({}));
    const deviceCode = String((input as RecordValue).device_code || '');

    // No device named: this is the queue worker, drained on a schedule.
    if (!deviceCode) {
      const results = await drain(Math.min(Math.max(Number((input as RecordValue).limit) || 10, 1), 50));
      return reply({ok: true, processed: results.length, results});
    }

    if (!token) return reply({ok: false, message: 'Sign in to publish a device.'}, 401);
    await rpc('request_pos_used_device_publish', {
      session_token: token,
      payload: {
        store_code: String((input as RecordValue).store_code || ''),
        device_code: deviceCode,
        action: String((input as RecordValue).action || 'publish'),
      },
    });
    // Carry it over straight away so the staff member sees the result, rather
    // than waiting for the next scheduled drain.
    const results = await drain(5);
    return reply({ok: true, device_code: deviceCode, results});
  } catch (error) {
    const message = error instanceof Error ? error.message : 'The publish request failed.';
    return reply({ok: false, message}, /session|access|another store|sign in/i.test(message) ? 403 : 400);
  }
});
