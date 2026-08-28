const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "GET, PUT, DELETE, OPTIONS",
};

type JsonRecord = Record<string, unknown>;

function normalizedRepairPrice(value: unknown): string | null {
  const raw = String(value ?? "").trim();
  const match = raw.match(/^\$?([0-9]+(?:\.[0-9]{1,2})?)$/);
  if (!match) return null;
  const amount = Number(match[1]);
  if (!Number.isFinite(amount) || amount <= 0 || amount > 1000000) return null;
  return `$${amount.toFixed(2)}`;
}

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function supabaseConfig(): { url: string; serviceKey: string } {
  const url = Deno.env.get("STAFF_AUTH_SUPABASE_URL")
    || Deno.env.get("SUPABASE_URL")
    || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

  if (!url || !serviceKey) {
    throw new Error("Supabase environment is not configured.");
  }

  return { url, serviceKey };
}

async function callRpc(_request: Request, rpcName: string, payload: JsonRecord): Promise<Response> {
  const config = supabaseConfig();
  return fetch(`${config.url}/rest/v1/rpc/${rpcName}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: config.serviceKey,
      Authorization: `Bearer ${config.serviceKey}`,
    },
    body: JSON.stringify(payload),
  });
}

async function authorize(
  request: Request,
  sessionToken: string,
  storeCode: string,
  staffName = "",
): Promise<JsonRecord> {
  const response = await callRpc(request, "pos_authorized_actor", {
    session_token: sessionToken,
    target_store_code: storeCode,
    requested_staff_name: staffName || null,
  });
  const result = await response.json().catch(() => ({})) as JsonRecord;
  if (!response.ok || !result.ok) throw new Error(String(result.message || "Store access denied."));
  return result;
}

async function rpcJson(request: Request, rpcName: string, payload: JsonRecord): Promise<Response> {
  const response = await callRpc(request, rpcName, payload);
  const bodyText = await response.text();
  return new Response(bodyText, {
    status: response.status,
    headers: {
      ...corsHeaders,
      "Content-Type": response.headers.get("Content-Type") || "application/json; charset=utf-8",
    },
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  const sessionToken = request.headers.get("x-staff-session") || "";
  if (!sessionToken) {
    return jsonResponse({ ok: false, message: "Staff session is required." }, 401);
  }

  try {
    const url = new URL(request.url);

    if (request.method === "GET") {
      const storeCode = url.searchParams.get("store_code") || "";
      if (!storeCode) {
        return jsonResponse({ ok: false, message: "store_code is required." }, 400);
      }
      await authorize(request, sessionToken, storeCode);
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit") || 200), 1), 500);
      return await rpcJson(request, "search_pos_repair_tickets", {
        session_token: sessionToken,
        target_store_code: storeCode,
        search_query: url.searchParams.get("q") || "",
        result_limit: limit,
      });
    }

    if (request.method === "PUT") {
      const payload = await request.json().catch(() => null);
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        return jsonResponse({ ok: false, message: "Ticket payload must be an object." }, 400);
      }
      const ticketPayload = payload as JsonRecord;
      const storeCode = String(ticketPayload.store_code || ticketPayload.store_db_code || "").trim().toLowerCase();
      if (!storeCode) return jsonResponse({ ok: false, message: "store_code is required." }, 400);
      const actor = await authorize(request, sessionToken, storeCode, String(ticketPayload.staff_name || ticketPayload.updated_by || ""));
      const repairPrice = normalizedRepairPrice(ticketPayload.price);
      if (!repairPrice) {
        return jsonResponse({
          ok: false,
          message: "Repair price must be one numeric amount, not a range.",
        }, 400);
      }
      return await rpcJson(request, "upsert_pos_repair_ticket", {
        session_token: sessionToken,
        payload: {
          ...ticketPayload,
          store_code: String(actor.store_code || storeCode),
          store_db_code: String(actor.store_code || storeCode),
          staff_name: String(actor.staff_name || ""),
          created_by: String(actor.staff_name || ""),
          updated_by: String(actor.staff_name || ""),
          price: repairPrice,
        },
      });
    }

    if (request.method === "DELETE") {
      const ticketCode = url.searchParams.get("ticket_code") || "";
      const staffName = url.searchParams.get("staff_name") || "";
      const storeCode = (url.searchParams.get("store_code") || "").trim().toLowerCase();
      if (!ticketCode) {
        return jsonResponse({ ok: false, message: "ticket_code is required." }, 400);
      }
      if (!storeCode) return jsonResponse({ ok: false, message: "store_code is required." }, 400);
      const actor = await authorize(request, sessionToken, storeCode, staffName);
      return await rpcJson(request, "delete_pos_repair_ticket_for_store", {
        session_token: sessionToken,
        target_store_code: storeCode,
        target_ticket_code: ticketCode,
        requested_staff_name: String(actor.staff_name || ""),
      });
    }

    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  } catch (error) {
    console.error(error);
    return jsonResponse({ ok: false, message: "Repair ticket request failed." }, 500);
  }
});
