const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
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

async function rpcResponse(request: Request, rpcName: string, payload: JsonRecord): Promise<Response> {
  const config = supabaseConfig(request);
  const response = await fetch(`${config.url}/rest/v1/rpc/${rpcName}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: config.anonKey,
      Authorization: config.authorization,
    },
    body: JSON.stringify(payload),
  });
  const body = await response.text();
  return new Response(body, {
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
    const resource = url.searchParams.get("resource") || "";

    if (request.method === "GET") {
      const storeCode = url.searchParams.get("store_code") || "";
      if (!storeCode) return jsonResponse({ ok: false, message: "store_code is required." }, 400);

      if (resource === "customers") {
        return await rpcResponse(request, "search_pos_customers", {
          session_token: sessionToken,
          target_store_code: storeCode,
          search_query: url.searchParams.get("q") || "",
          result_limit: Math.min(Math.max(Number(url.searchParams.get("limit") || 500), 1), 500),
        });
      }
      if (resource === "holds") {
        return await rpcResponse(request, "get_pos_held_carts", {
          session_token: sessionToken,
          target_store_code: storeCode,
        });
      }
      if (resource === "shift") {
        return await rpcResponse(request, "get_pos_store_shift", {
          session_token: sessionToken,
          target_store_code: storeCode,
        });
      }
      if (resource === "shift-totals") {
        return await rpcResponse(request, "get_pos_shift_payment_totals", {
          session_token: sessionToken,
          target_shift_code: url.searchParams.get("shift_id") || "",
        });
      }
      return jsonResponse({ ok: false, message: "Unknown shared-state resource." }, 400);
    }

    if (request.method === "POST") {
      const payload = await request.json().catch(() => null);
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        return jsonResponse({ ok: false, message: "Payload must be an object." }, 400);
      }
      const body = payload as JsonRecord;
      const bodyResource = String(body.resource || resource || "");
      const action = String(body.action || "save");
      const data = body.payload && typeof body.payload === "object" && !Array.isArray(body.payload)
        ? body.payload as JsonRecord
        : body;

      if (bodyResource === "customer") {
        return await rpcResponse(request, "upsert_pos_customer", {
          session_token: sessionToken,
          payload: data,
        });
      }
      if (bodyResource === "hold" && action === "restore") {
        return await rpcResponse(request, "restore_pos_held_cart", {
          session_token: sessionToken,
          target_store_code: String(data.store_code || ""),
          target_hold_code: String(data.hold_id || data.id || ""),
          staff_name: String(data.staff_name || ""),
        });
      }
      if (bodyResource === "hold") {
        return await rpcResponse(request, "save_pos_held_cart", {
          session_token: sessionToken,
          payload: data,
        });
      }
      if (bodyResource === "shift" && action === "open") {
        return await rpcResponse(request, "open_pos_store_shift", {
          session_token: sessionToken,
          payload: data,
        });
      }
      if (bodyResource === "shift" && action === "opening") {
        return await rpcResponse(request, "save_pos_shift_opening", {
          session_token: sessionToken,
          payload: data,
        });
      }
      if (bodyResource === "shift" && action === "close") {
        return await rpcResponse(request, "close_pos_store_shift", {
          session_token: sessionToken,
          payload: data,
        });
      }
      return jsonResponse({ ok: false, message: "Unknown shared-state action." }, 400);
    }

    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  } catch (error) {
    console.error(error);
    return jsonResponse({ ok: false, message: "POS shared-state request failed." }, 500);
  }
});
