type RecordValue = Record<string, unknown>;
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-staff-session',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const bucket = 'repair-ticket-photos';
function reply(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {status, headers: {...cors, 'Content-Type': 'application/json'}});
}
function config() {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Error('Repair updates are not configured.');
  return {url, headers: {apikey: key, Authorization: `Bearer ${key}`}};
}
async function rpc(name: string, body: RecordValue) {
  const {url, headers} = config();
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: {...headers, 'Content-Type': 'application/json'}, body: JSON.stringify(body),
  });
  const data = await response.json();
  if (!response.ok || data.ok === false) throw new Error(data.message || 'Repair update failed.');
  return data;
}
async function photoUrl(path: string) {
  const {url, headers} = config();
  const response = await fetch(`${url}/storage/v1/object/sign/${bucket}/${path}`, {
    method: 'POST', headers: {...headers, 'Content-Type': 'application/json'}, body: JSON.stringify({expiresIn: 3600}),
  });
  if (!response.ok) throw new Error('Could not load a repair image. Please refresh.');
  const data = await response.json();
  return `${url}/storage/v1${data.signedURL}`;
}
Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, {status: 204, headers: cors});
  if (!['GET', 'POST'].includes(request.method)) return reply({ok: false, message: 'Method not allowed'}, 405);
  const token = request.headers.get('x-staff-session');
  if (!token) return reply({ok: false, message: 'Sign in to view repair updates.'}, 401);
  try {
    const url = new URL(request.url);
    if (Number(request.headers.get('content-length')) > 4500000) return reply({ok: false, message: 'Image too large.'}, 413);
    const input = request.method === 'GET' ? Object.fromEntries(url.searchParams) : await request.json();
    if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid request.');
    const args = {session_token: token, store_code: String(input.store_code || ''), ticket_code: String(input.ticket_code || '')};
    if (!args.store_code || !args.ticket_code) throw new Error('Store and repair ticket are required.');
    if (request.method === 'GET') {
      const data = await rpc('get_repair_ticket_updates', args);
      data.updates = await Promise.all(data.updates.map(async (entry: RecordValue) => ({
        ...entry, image_url: entry.kind === 'photo' ? await photoUrl(String(entry.storage_path)) : undefined,
        storage_path: undefined,
      })));
      return reply(data);
    }
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(input.id))) throw new Error('Invalid update ID.');
    const context = await rpc('authorize_repair_ticket_update', args);
    if (!context.writable) throw new Error('Deleted repair tickets are read-only.');
    if (input.kind === 'comment') {
      const body = String(input.body || '').trim();
      if (!body || body.length > 5000) throw new Error('Enter a comment of up to 5,000 characters.');
      return reply(await rpc('add_repair_ticket_update', {...args, payload: {id: input.id, kind: 'comment', body}}));
    }
    if (input.kind !== 'photo') throw new Error('Invalid update type.');
    const dataUrl = String(input.data_url || '');
    if (dataUrl.length > 4200000 || !/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(dataUrl)) throw new Error('Choose a JPEG, PNG or WebP image.');
    const binary = atob(dataUrl.split(',')[1]);
    const bytes = Uint8Array.from(binary, c => c.charCodeAt(0));
    if (bytes.length < 4 || bytes.length > 3145728 || bytes[0] !== 255 || bytes[1] !== 216 || bytes[2] !== 255) throw new Error('Invalid image.');
    const path = `${context.store_id}/${context.ticket_id}/${input.id}.jpg`;
    const {url: api, headers} = config();
    const upload = await fetch(`${api}/storage/v1/object/${bucket}/${path}`, {
      method: 'POST', headers: {...headers, 'Content-Type': 'image/jpeg', 'x-upsert': 'false'}, body: bytes,
    });
    if (!upload.ok) {
      const error = await upload.json().catch(() => ({}));
      if (upload.status !== 409 && error.statusCode !== '409' && error.error !== 'Duplicate') throw new Error('The image could not be uploaded. Try again.');
    }
    // Keep an uploaded object after an uncertain DB response so retrying the
    // same ID cannot remove a photo that was actually saved.
    return reply(await rpc('add_repair_ticket_update', {...args, payload: {
      id: input.id, kind: 'photo', storage_path: path, file_name: String(input.file_name || 'Screenshot.jpg'),
    }}));
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Repair update failed.';
    return reply({ok: false, message}, /session|access|another store|sign in/i.test(message) ? 403 : 400);
  }
});
