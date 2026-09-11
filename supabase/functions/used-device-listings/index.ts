// Runs in the website/product project. The only way a second-hand device
// reaches the public catalogue.
//
// It is called by pos-used-device-publish in the staff/POS project and trusts
// nothing but a shared internal secret: the POS project never holds this
// project's service key, exactly as the password-reset relay is arranged.

type RecordValue = Record<string, unknown>;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-publish-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const bucket = 'used-device-listing-images';

function reply(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {status, headers: {...cors, 'Content-Type': 'application/json'}});
}

function config() {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const secret = Deno.env.get('USED_DEVICE_PUBLISH_SECRET');
  if (!url || !key || !secret) throw new Error('Used device publishing is not configured.');
  return {url, secret, headers: {apikey: key, Authorization: `Bearer ${key}`}};
}

async function rpc(name: string, body: RecordValue) {
  const {url, headers} = config();
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: {...headers, 'Content-Type': 'application/json'}, body: JSON.stringify(body),
  });
  const data = await response.json();
  if (!response.ok || data.ok === false) throw new Error(data.message || 'The listing could not be saved.');
  return data;
}

function jpegBytes(dataUrl: string) {
  if (dataUrl.length > 4200000 || !/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(dataUrl)) {
    throw new Error('Listing images must be JPEG.');
  }
  const binary = atob(dataUrl.split(',')[1]);
  const bytes = Uint8Array.from(binary, c => c.charCodeAt(0));
  if (bytes.length < 4 || bytes.length > 3145728 || bytes[0] !== 255 || bytes[1] !== 216 || bytes[2] !== 255) {
    throw new Error('Invalid listing image.');
  }
  return bytes;
}

// Re-publishing the same device overwrites its images rather than growing a
// pile of orphans, so the object name is derived from the device and position.
async function storeImage(objectName: string, bytes: Uint8Array) {
  const {url, headers} = config();
  const response = await fetch(`${url}/storage/v1/object/${bucket}/${objectName}`, {
    method: 'POST', headers: {...headers, 'Content-Type': 'image/jpeg', 'x-upsert': 'true'}, body: bytes,
  });
  if (!response.ok) {
    const error = await response.json().catch(() => ({}));
    throw new Error(error.message || 'The listing image could not be stored.');
  }
  return `${url}/storage/v1/object/public/${bucket}/${objectName}`;
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, {status: 204, headers: cors});
  if (request.method !== 'POST') return reply({ok: false, message: 'Method not allowed'}, 405);
  try {
    const {secret} = config();
    if (request.headers.get('x-publish-secret') !== secret) {
      return reply({ok: false, message: 'Publishing is not authorised.'}, 403);
    }
    const input = await request.json().catch(() => null);
    if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid request.');
    const action = String(input.action || '');
    const deviceCode = String(input.device_code || '').trim();
    if (!/^USED-[A-Z0-9]{6,32}$/.test(deviceCode)) throw new Error('Invalid device code.');

    if (action === 'upload-image') {
      const position = Number(input.position);
      if (!Number.isInteger(position) || position < 1 || position > 24) throw new Error('Invalid image position.');
      const objectName = `${deviceCode}/${position}.jpg`;
      const url = await storeImage(objectName, jpegBytes(String(input.data_url || '')));
      return reply({ok: true, url, position});
    }

    if (action === 'publish') {
      const listing = input.listing;
      if (!listing || typeof listing !== 'object') throw new Error('A listing is required.');
      return reply(await rpc('upsert_used_device_listing', {
        payload: {...listing as RecordValue, device_code: deviceCode, status: 'published',
          source_version: input.source_version},
      }));
    }

    if (action === 'withdraw' || action === 'sold') {
      return reply(await rpc('withdraw_used_device_listing', {
        payload: {device_code: deviceCode, status: action === 'sold' ? 'sold' : 'withdrawn',
          source_version: input.source_version},
      }));
    }

    throw new Error('Unknown listing action.');
  } catch (error) {
    const message = error instanceof Error ? error.message : 'The listing request failed.';
    return reply({ok: false, message}, /authoris|secret/i.test(message) ? 403 : 400);
  }
});
