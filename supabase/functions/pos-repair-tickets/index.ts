const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "GET, PUT, DELETE, OPTIONS",
};

type JsonRecord = Record<string, unknown>;

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function supabaseConfig(request: Request): { url: string; anonKey: string; authorization: string } {
  const url = Deno.env.get("STAFF_AUTH_SUPABASE_URL")
    || Deno.env.get("SUPABASE_URL")
    || "";
  const incomingApiKey = request.headers.get("apikey") || "";
  const incomingAuthorization = request.headers.get("authorization") || "";
  const anonKey = incomingApiKey
    || Deno.env.get("STAFF_AUTH_SUPABASE_ANON_KEY")
    || Deno.env.get("SUPABASE_ANON_KEY")
    || "";
  const authorization = incomingAuthorization || `Bearer ${anonKey}`;

  if (!url || !anonKey) {
    throw new Error("Supabase environment is not configured.");
  }

  return { url, anonKey, authorization };
}

async function callRpc(request: Request, rpcName: string, payload: JsonRecord): Promise<Response> {
  const config = supabaseConfig(request);
  return fetch(`${config.url}/rest/v1/rpc/${rpcName}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: config.anonKey,
      Authorization: config.authorization,
    },
    body: JSON.stringify(payload),
  });
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
      return await rpcJson(request, "upsert_pos_repair_ticket", {
        session_token: sessionToken,
        payload,
      });
    }

    if (request.method === "DELETE") {
      const ticketCode = url.searchParams.get("ticket_code") || "";
      const staffName = url.searchParams.get("staff_name") || "";
      if (!ticketCode) {
        return jsonResponse({ ok: false, message: "ticket_code is required." }, 400);
      }
      return await rpcJson(request, "delete_pos_repair_ticket", {
        session_token: sessionToken,
        target_ticket_code: ticketCode,
        staff_name: staffName,
      });
    }

    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  } catch (error) {
    console.error(error);
    return jsonResponse({ ok: false, message: "Repair ticket request failed." }, 500);
  }
});
