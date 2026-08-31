const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

type JsonRecord = Record<string, unknown>;

const SIGNATURE_MAX_BYTES = 2 * 1024 * 1024;
const SIGNED_URL_SECONDS = 300;

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

function config(): { url: string; serviceKey: string } {
  const url = Deno.env.get("SUPABASE_URL") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!url || !serviceKey) throw new Error("Repair cards are not configured.");
  return { url, serviceKey };
}

async function callRpc(name: string, payload: JsonRecord): Promise<{ status: number; body: JsonRecord }> {
  const { url, serviceKey } = config();
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
    },
    body: JSON.stringify(payload),
  });
  const result = await response.json().catch(() => ({}));
  const body = Array.isArray(result)
    ? ((result[0] as JsonRecord | undefined) || {})
    : ((result as JsonRecord | null) || {});
  return { status: response.status, body };
}

/** Turn a data: URL into bytes, rejecting anything that is not a small PNG/JPEG. */
function decodeSignature(dataUrl: string): { bytes: Uint8Array; contentType: string } {
  const match = /^data:(image\/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=\s]+)$/.exec(dataUrl || "");
  if (!match) throw new Error("Signature must be a PNG, JPEG or WebP image.");
  const binary = atob(match[2].replace(/\s+/g, ""));
  if (binary.length > SIGNATURE_MAX_BYTES) throw new Error("Signature image is too large.");
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return { bytes, contentType: match[1] };
}

function safeSegment(value: string): string {
  return String(value || "").replace(/[^A-Za-z0-9._-]/g, "-").replace(/-+/g, "-").slice(0, 64);
}

async function uploadSignature(path: string, bytes: Uint8Array, contentType: string): Promise<void> {
  const { url, serviceKey } = config();
  const response = await fetch(`${url}/storage/v1/object/repair-cards/${path}`, {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      "Content-Type": contentType,
      "x-upsert": "false",
    },
    body: bytes,
  });
  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(`Signature could not be stored. ${detail}`.trim());
  }
}

/** Remove an uploaded image when the signature it belonged to was rejected. */
async function deleteSignature(path: string): Promise<void> {
  try {
    const { url, serviceKey } = config();
    await fetch(`${url}/storage/v1/object/repair-cards/${path}`, {
      method: "DELETE",
      headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` },
    });
  } catch (error) {
    console.error("orphan signature cleanup failed", path, error);
  }
}

/** The bucket is private, so images are only ever handed out as short-lived URLs. */
async function signedUrl(path: string): Promise<string | null> {
  const { url, serviceKey } = config();
  const response = await fetch(`${url}/storage/v1/object/sign/repair-cards/${path}`, {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ expiresIn: SIGNED_URL_SECONDS }),
  });
  if (!response.ok) return null;
  const result = await response.json().catch(() => ({})) as JsonRecord;
  const signed = String(result.signedURL || result.signedUrl || "");
  return signed ? `${url}/storage/v1${signed.startsWith("/") ? "" : "/"}${signed}` : null;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (request.method !== "GET" && request.method !== "POST") {
    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  }

  const sessionToken = request.headers.get("x-staff-session") || "";
  if (!sessionToken) return jsonResponse({ ok: false, message: "Staff session is required." }, 401);

  try {
    const url = new URL(request.url);

    if (request.method === "GET") {
      const storeCode = url.searchParams.get("store_code") || "";
      const ticketCode = url.searchParams.get("ticket_code") || "";
      if (!storeCode || !ticketCode) {
        return jsonResponse({ ok: false, message: "store_code and ticket_code are required." }, 400);
      }
      const result = await callRpc("get_pos_repair_card_signatures", {
        session_token: sessionToken,
        target_store_code: storeCode,
        target_ticket_code: ticketCode,
      });
      if (result.status >= 400 || result.body.ok === false) return jsonResponse(result.body, result.status);

      const signatures = Array.isArray(result.body.signatures) ? result.body.signatures as JsonRecord[] : [];
      const withUrls = await Promise.all(signatures.map(async (row) => ({
        ...row,
        signature_url: await signedUrl(String(row.signature_path || "")),
      })));
      return jsonResponse({ ...result.body, signatures: withUrls }, 200);
    }

    const payload = await request.json().catch(() => null);
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      return jsonResponse({ ok: false, message: "Signature payload must be an object." }, 400);
    }
    const record = payload as JsonRecord;
    const storeCode = String(record.store_code || "");
    const ticketCode = String(record.ticket_code || "");
    const customerName = String(record.signed_customer_name || "").trim();
    if (!storeCode || !ticketCode) {
      return jsonResponse({ ok: false, message: "store_code and ticket_code are required." }, 400);
    }
    if (!customerName) {
      return jsonResponse({ ok: false, message: "The customer must type their name to sign." }, 400);
    }
    if (customerName.length > 120) {
      return jsonResponse({ ok: false, message: "Customer name cannot exceed 120 characters." }, 400);
    }
    if (!record.card_snapshot || typeof record.card_snapshot !== "object") {
      return jsonResponse({ ok: false, message: "Card snapshot is required." }, 400);
    }
    if (record.terms_acknowledged !== true) {
      return jsonResponse({ ok: false, message: "The customer must acknowledge the terms and conditions." }, 400);
    }

    let signature;
    try {
      signature = decodeSignature(String(record.signature_image || ""));
    } catch (error) {
      return jsonResponse({ ok: false, message: error instanceof Error ? error.message : "Invalid signature." }, 400);
    }

    const extension = signature.contentType === "image/png" ? "png"
      : signature.contentType === "image/jpeg" ? "jpg" : "webp";
    const path = `${safeSegment(storeCode)}/${safeSegment(ticketCode)}/${crypto.randomUUID()}.${extension}`;
    await uploadSignature(path, signature.bytes, signature.contentType);

    const result = await callRpc("save_pos_repair_card_signature", {
      session_token: sessionToken,
      payload: {
        store_code: storeCode,
        ticket_code: ticketCode,
        staff_name: String(record.staff_name || ""),
        signed_customer_name: customerName,
        signature_path: path,
        card_snapshot: record.card_snapshot,
        resign_reason: record.resign_reason ? String(record.resign_reason) : null,
      },
    });
    if (result.status >= 400 || result.body.ok === false) {
      // The image was stored before the row was accepted, so a rejected
      // signature must not leave an orphan behind in the bucket.
      await deleteSignature(path);
      return jsonResponse(result.body, result.status);
    }

    const saved = (result.body.signature || {}) as JsonRecord;
    return jsonResponse({
      ...result.body,
      signature: { ...saved, signature_url: await signedUrl(path) },
    }, 200);
  } catch (error) {
    console.error(error);
    return jsonResponse({
      ok: false,
      message: error instanceof Error ? error.message : "Repair card request failed.",
    }, 500);
  }
});
