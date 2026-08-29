const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-admin-session",
  "Access-Control-Allow-Methods": "GET, PUT, OPTIONS",
};

type JsonRecord = Record<string, unknown>;

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

async function callRpc(name: string, payload: JsonRecord): Promise<{ status: number; body: JsonRecord }> {
  const url = Deno.env.get("SUPABASE_URL") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!url || !serviceKey) throw new Error("Staff management is not configured.");

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

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (request.method !== "GET" && request.method !== "PUT") {
    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  }

  const sessionToken = request.headers.get("x-admin-session") || "";
  if (!sessionToken) return jsonResponse({ ok: false, message: "Admin session is required." }, 401);

  try {
    if (request.method === "GET") {
      const result = await callRpc("get_staff_management", { session_token: sessionToken });
      return jsonResponse(result.body, result.status);
    }

    const payload = await request.json().catch(() => null);
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      return jsonResponse({ ok: false, message: "Staff update must be an object." }, 400);
    }
    const record = payload as JsonRecord;
    const staffId = Number(record.staff_id);
    const storeCodes = Array.isArray(record.store_codes)
      ? Array.from(new Set(record.store_codes
        .map((value) => String(value || "").trim().toLowerCase())
        .filter(Boolean)))
      : [];
    if (!Number.isInteger(staffId) || staffId < 0) {
      return jsonResponse({ ok: false, message: "Staff member is required." }, 400);
    }
    if (storeCodes.length > 50) {
      return jsonResponse({ ok: false, message: "Too many stores were selected." }, 400);
    }
    if (typeof record.active !== "boolean" || typeof record.stocktake_enabled !== "boolean") {
      return jsonResponse({ ok: false, message: "Account and inventory access values are required." }, 400);
    }

    const result = await callRpc("update_staff_management", {
      session_token: sessionToken,
      target_staff_id: staffId,
      target_store_codes: storeCodes,
      target_active: record.active,
      target_stocktake_enabled: record.stocktake_enabled,
    });
    return jsonResponse(result.body, result.status);
  } catch (error) {
    console.error(error);
    return jsonResponse({
      ok: false,
      message: error instanceof Error ? error.message : "Staff management request failed.",
    }, 500);
  }
});
