const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

type JsonRecord = Record<string, unknown>;

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

function supabaseConfig(): { url: string; serviceKey: string } {
  const url = Deno.env.get("STAFF_AUTH_SUPABASE_URL") || Deno.env.get("SUPABASE_URL") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!url || !serviceKey) throw new Error("Supabase environment is not configured.");
  return { url, serviceKey };
}

async function rpcResponse(_request: Request, rpcName: string, payload: JsonRecord): Promise<Response> {
  const config = supabaseConfig();
  const response = await fetch(`${config.url}/rest/v1/rpc/${rpcName}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: config.serviceKey,
      Authorization: `Bearer ${config.serviceKey}`,
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

async function authorize(
  request: Request,
  sessionToken: string,
  storeCode: string,
  staffName = "",
): Promise<JsonRecord> {
  const response = await rpcResponse(request, "pos_authorized_actor", {
    session_token: sessionToken,
    target_store_code: storeCode,
    requested_staff_name: staffName || null,
  });
  const result = await response.json().catch(() => ({})) as JsonRecord;
  if (!response.ok || !result.ok) throw new Error(String(result.message || "Store access denied."));
  return result;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });

  const sessionToken = request.headers.get("x-staff-session") || "";
  if (!sessionToken) return jsonResponse({ ok: false, message: "Staff session is required." }, 401);

  try {
    const url = new URL(request.url);
    if (request.method === "GET") {
      const storeCode = url.searchParams.get("store_code") || "";
      if (!storeCode) return jsonResponse({ ok: false, message: "store_code is required." }, 400);
      await authorize(request, sessionToken, storeCode);
      const resource = url.searchParams.get("resource") || "devices";
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit") || 200), 1), 500);

      if (resource === "transactions") {
        return await rpcResponse(request, "get_pos_used_device_transactions", {
          session_token: sessionToken,
          target_store_code: storeCode,
          search_query: url.searchParams.get("q") || "",
          result_limit: limit,
        });
      }

      // The inspection checklist the POS renders is the same data the
      // ready-for-sale gate reads, so the two cannot drift apart.
      if (resource === "checklists") {
        return await rpcResponse(request, "get_pos_used_device_inspection_items", {
          session_token: sessionToken,
        });
      }

      if (resource === "costs") {
        const deviceCode = url.searchParams.get("device_code") || "";
        if (!deviceCode) return jsonResponse({ ok: false, message: "device_code is required." }, 400);
        return await rpcResponse(request, "get_pos_used_device_costs", {
          session_token: sessionToken,
          store_code: storeCode,
          device_code: deviceCode,
        });
      }

      return await rpcResponse(request, "search_pos_used_devices", {
        session_token: sessionToken,
        target_store_code: storeCode,
        search_query: url.searchParams.get("q") || "",
        target_status: url.searchParams.get("status") || "",
        result_limit: limit,
      });
    }

    if (request.method === "POST") {
      const body = await request.json().catch(() => null);
      if (!body || typeof body !== "object" || Array.isArray(body)) {
        return jsonResponse({ ok: false, message: "Payload must be an object." }, 400);
      }
      const payload = body as JsonRecord;
      const action = String(payload.action || "acquire");
      const data = payload.payload && typeof payload.payload === "object" && !Array.isArray(payload.payload)
        ? payload.payload as JsonRecord
        : payload;
      const storeCode = String(data.store_code || data.store_db_code || "").trim().toLowerCase();
      if (!storeCode) return jsonResponse({ ok: false, message: "store_code is required." }, 400);
      const actor = await authorize(request, sessionToken, storeCode, String(data.staff_name || data.updated_by || ""));
      const safeData = {
        ...data,
        store_code: String(actor.store_code || storeCode),
        store_db_code: String(actor.store_code || storeCode),
        staff_name: String(actor.staff_name || ""),
        acquired_by: String(actor.staff_name || ""),
        updated_by: String(actor.staff_name || ""),
      };

      if (action === "acquire") {
        return await rpcResponse(request, "create_pos_used_device_acquisition", {
          session_token: sessionToken,
          payload: safeData,
        });
      }
      if (action === "update") {
        return await rpcResponse(request, "update_pos_used_device", {
          session_token: sessionToken,
          payload: safeData,
        });
      }
      if (action === "add-cost") {
        const deviceCode = String(data.device_code || "").trim();
        if (!deviceCode) return jsonResponse({ ok: false, message: "device_code is required." }, 400);
        return await rpcResponse(request, "add_pos_used_device_cost", {
          session_token: sessionToken,
          store_code: String(actor.store_code || storeCode),
          device_code: deviceCode,
          payload: {
            id: data.id,
            kind: data.kind,
            description: data.description,
            amount: data.amount,
            repair_ticket_code: data.repair_ticket_code,
          },
        });
      }
      return jsonResponse({ ok: false, message: "Unknown used-device action." }, 400);
    }

    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  } catch (error) {
    console.error(error);
    return jsonResponse({ ok: false, message: "Used-device request failed." }, 500);
  }
});
