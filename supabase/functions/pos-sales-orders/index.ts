const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "GET, POST, PUT, OPTIONS",
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

async function rpcResponse(
  request: Request,
  rpcName: string,
  payload: JsonRecord,
): Promise<Response> {
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
    if (request.method === "POST") {
      const payload = await request.json().catch(() => null);
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        return jsonResponse({ ok: false, message: "Order payload must be an object." }, 400);
      }
      return await rpcResponse(request, "save_pos_sales_order", {
        session_token: sessionToken,
        payload,
      });
    }

    if (request.method === "PUT") {
      const payload = await request.json().catch(() => null);
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        return jsonResponse({ ok: false, message: "Refund payload must be an object." }, 400);
      }
      return await rpcResponse(request, "refund_pos_sales_order", {
        session_token: sessionToken,
        payload,
      });
    }

    if (request.method === "GET") {
      const url = new URL(request.url);
      const orderCode = url.searchParams.get("order_id") || "";
      if (orderCode) {
        return await rpcResponse(request, "get_pos_sales_order", {
          session_token: sessionToken,
          target_order_code: orderCode,
        });
      }

      const storeCode = url.searchParams.get("store_code") || "";
      if (!storeCode) {
        return jsonResponse({ ok: false, message: "store_code is required." }, 400);
      }
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit") || 100), 1), 200);
      const offset = Math.max(Number(url.searchParams.get("offset") || 0), 0);
      return await rpcResponse(request, "search_pos_sales_orders", {
        session_token: sessionToken,
        target_store_code: storeCode,
        search_query: url.searchParams.get("q") || "",
        result_limit: limit,
        result_offset: offset,
        date_from: url.searchParams.get("from_date") || null,
        date_to: url.searchParams.get("to_date") || null,
      });
    }

    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  } catch (error) {
    console.error(error);
    return jsonResponse({ ok: false, message: "POS order request failed." }, 500);
  }
});
