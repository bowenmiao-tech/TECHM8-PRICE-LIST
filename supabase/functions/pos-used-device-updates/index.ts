type RecordValue = Record<string, unknown>;
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-staff-session',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const photoBucket = 'used-device-photos';
const idBucket = 'used-device-id-photos';
const bucketFor = (stage: unknown) => (stage === 'seller_id' ? idBucket : photoBucket);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function reply(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {status, headers: {...cors, 'Content-Type': 'application/json'}});
}
function config() {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Error('Used device evidence is not configured.');
  return {url, headers: {apikey: key, Authorization: `Bearer ${key}`}};
}
async function rpc(name: string, body: RecordValue) {
  const {url, headers} = config();
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: {...headers, 'Content-Type': 'application/json'}, body: JSON.stringify(body),
  });
  const data = await response.json();
  if (!response.ok || data.ok === false) throw new Error(data.message || 'Used device evidence request failed.');
  return data;
}
async function photoUrl(bucket: string, path: string) {
  const {url, headers} = config();
  const response = await fetch(`${url}/storage/v1/object/sign/${bucket}/${path}`, {
    method: 'POST', headers: {...headers, 'Content-Type': 'application/json'}, body: JSON.stringify({expiresIn: 3600}),
  });
  if (!response.ok) throw new Error('Could not load a device image. Please refresh.');
  const data = await response.json();
  return `${url}/storage/v1${data.signedURL}`;
}
// A browser-supplied data URL only ever becomes a stored object after the
// magic bytes agree it is the JPEG the POS said it produced.
function jpegBytes(dataUrl: string) {
  if (dataUrl.length > 4200000 || !/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(dataUrl)) {
    throw new Error('Choose a JPEG, PNG or WebP image.');
  }
  const binary = atob(dataUrl.split(',')[1]);
  const bytes = Uint8Array.from(binary, c => c.charCodeAt(0));
  if (bytes.length < 4 || bytes.length > 3145728 || bytes[0] !== 255 || bytes[1] !== 216 || bytes[2] !== 255) {
    throw new Error('Invalid image.');
  }
  return bytes;
}
async function upload(bucket: string, path: string, bytes: Uint8Array) {
  const {url, headers} = config();
  const response = await fetch(`${url}/storage/v1/object/${bucket}/${path}`, {
    method: 'POST', headers: {...headers, 'Content-Type': 'image/jpeg', 'x-upsert': 'false'}, body: bytes,
  });
  if (response.ok) return;
  const error = await response.json().catch(() => ({}));
  // A duplicate means a retry of the same upload ID reached storage already.
  if (response.status !== 409 && error.statusCode !== '409' && error.error !== 'Duplicate') {
    throw new Error('The image could not be uploaded. Try again.');
  }
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, {status: 204, headers: cors});
  if (!['GET', 'POST'].includes(request.method)) return reply({ok: false, message: 'Method not allowed'}, 405);
  const token = request.headers.get('x-staff-session');
  if (!token) return reply({ok: false, message: 'Sign in to view device evidence.'}, 401);
  try {
    const url = new URL(request.url);
    if (Number(request.headers.get('content-length')) > 4500000) return reply({ok: false, message: 'Image too large.'}, 413);
    const input = request.method === 'GET' ? Object.fromEntries(url.searchParams) : await request.json();
    if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid request.');
    const storeCode = String(input.store_code || '');
    if (!storeCode) throw new Error('Store is required.');
    const intakeKey = String(input.intake_key || '');
    const deviceCode = String(input.device_code || '');

    if (request.method === 'GET') {
      // Evidence photographed during a purchase, before a device record exists.
      if (intakeKey) {
        if (!uuid.test(intakeKey)) throw new Error('Invalid intake ID.');
        const data = await rpc('get_pos_used_device_intake_uploads', {
          session_token: token, store_code: storeCode, intake_key: intakeKey,
        });
        data.uploads = await Promise.all(data.uploads.map(async (entry: RecordValue) => ({
          ...entry,
          image_url: await photoUrl(bucketFor(entry.stage), String(entry.storage_path)),
          storage_path: undefined,
        })));
        return reply(data);
      }
      if (!deviceCode) throw new Error('Device is required.');
      const data = await rpc('get_pos_used_device_updates', {
        session_token: token, store_code: storeCode, device_code: deviceCode,
      });
      data.updates = await Promise.all(data.updates.map(async (entry: RecordValue) => ({
        ...entry,
        image_url: entry.kind === 'photo' ? await photoUrl(bucketFor(entry.stage), String(entry.storage_path)) : undefined,
        storage_path: undefined,
      })));
      return reply(data);
    }

    if (!uuid.test(String(input.id))) throw new Error('Invalid update ID.');
    const stage = String(input.stage || 'refurb');
    if (!['intake', 'seller_id', 'refurb', 'listing'].includes(stage)) throw new Error('Invalid evidence stage.');

    // Staged intake evidence: authorised by store, not by device.
    if (intakeKey) {
      if (!uuid.test(intakeKey)) throw new Error('Invalid intake ID.');
      if (!['intake', 'seller_id'].includes(stage)) throw new Error('Only intake and ID photos can be taken before the purchase is saved.');
      const context = await rpc('pos_authorized_actor', {
        session_token: token, target_store_code: storeCode, requested_staff_name: null,
      });
      const path = `${context.store_id}/${intakeKey}/${input.id}.jpg`;
      await upload(bucketFor(stage), path, jpegBytes(String(input.data_url || '')));
      // The object is deliberately left in place if the row below fails, so a
      // retry of the same ID cannot delete evidence that was already saved.
      return reply(await rpc('stage_pos_used_device_intake_upload', {
        session_token: token,
        store_code: storeCode,
        payload: {
          id: input.id, intake_key: intakeKey, stage, storage_path: path,
          file_name: String(input.file_name || 'Device photo.jpg'),
        },
      }));
    }

    if (!deviceCode) throw new Error('Device is required.');
    const args = {session_token: token, store_code: storeCode, device_code: deviceCode};
    const context = await rpc('authorize_pos_used_device_evidence', args);
    if (!context.writable) throw new Error('Closed device records are read-only.');

    if (input.kind === 'comment') {
      const body = String(input.body || '').trim();
      if (!body || body.length > 5000) throw new Error('Enter a note of up to 5,000 characters.');
      return reply(await rpc('add_pos_used_device_update', {
        ...args, payload: {id: input.id, kind: 'comment', stage, body},
      }));
    }
    if (input.kind !== 'photo') throw new Error('Invalid update type.');
    const path = `${context.store_id}/${context.device_id}/${input.id}.jpg`;
    await upload(bucketFor(stage), path, jpegBytes(String(input.data_url || '')));
    return reply(await rpc('add_pos_used_device_update', {
      ...args,
      payload: {
        id: input.id, kind: 'photo', stage, storage_path: path,
        file_name: String(input.file_name || 'Device photo.jpg'),
      },
    }));
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Used device evidence request failed.';
    return reply({ok: false, message}, /session|access|another store|sign in/i.test(message) ? 403 : 400);
  }
});
