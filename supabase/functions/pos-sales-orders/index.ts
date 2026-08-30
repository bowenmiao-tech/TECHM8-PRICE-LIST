const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "GET, POST, PUT, OPTIONS",
};

type JsonRecord = Record<string, unknown>;

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

function staffConfig(): { url: string; serviceKey: string } {
  const url = Deno.env.get("STAFF_AUTH_SUPABASE_URL") || Deno.env.get("SUPABASE_URL") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!url || !serviceKey) throw new Error("Staff database is not configured.");
  return { url, serviceKey };
}

async function callRpc(rpcName: string, payload: JsonRecord): Promise<{ status: number; body: JsonRecord }> {
  const config = staffConfig();
  const response = await fetch(`${config.url}/rest/v1/rpc/${rpcName}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: config.serviceKey,
      Authorization: `Bearer ${config.serviceKey}`,
    },
    body: JSON.stringify(payload),
  });
  const result = await response.json().catch(() => ({}));
  const body = Array.isArray(result)
    ? ((result[0] as JsonRecord | undefined) || {})
    : ((result as JsonRecord | null) || {});
  return { status: response.status, body };
}

async function requireStoreAccess(sessionToken: string, storeCode: string): Promise<JsonRecord> {
  if (!storeCode) throw new Error("store_code is required.");
  const result = await callRpc("verify_staff_store_access", {
    session_token: sessionToken,
    target_store_code: storeCode,
  });
  if (result.status >= 400 || !result.body.ok || !result.body.allowed) {
    throw new Error(String(result.body.message || "Store access denied."));
  }
  return result.body;
}

async function authorizedActor(
  sessionToken: string,
  storeCode: string,
  requestedStaffName: string,
): Promise<JsonRecord> {
  const result = await callRpc("pos_authorized_actor", {
    session_token: sessionToken,
    target_store_code: storeCode,
    requested_staff_name: requestedStaffName || null,
  });
  if (result.status >= 400 || !result.body.ok) {
    throw new Error(String(result.body.message || "Staff access denied."));
  }
  return result.body;
}

async function inventoryRequest(
  sessionToken: string,
  body: JsonRecord,
): Promise<{ status: number; body: JsonRecord }> {
  const endpoint = Deno.env.get("POS_PRODUCTS_ENDPOINT")
    || "https://fwlronvmgqzkleofriis.supabase.co/functions/v1/pos-products";
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-staff-session": sessionToken,
    },
    body: JSON.stringify(body),
  });
  const result = await response.json().catch(() => ({}));
  return { status: response.status, body: (result as JsonRecord | null) || {} };
}

async function syncSavedOrder(
  sessionToken: string,
  storeCode: string,
  order: JsonRecord,
): Promise<JsonRecord> {
  const orderCode = String(order.id || order.order_id || "").trim();
  if (!orderCode) return { ok: false, message: "Saved order id is missing." };
  const sync = await inventoryRequest(sessionToken, {
    action: "sync-order",
    store_slug: storeCode,
    order_id: orderCode,
  });
  if (sync.status >= 400 || !sync.body.ok) {
    console.error("POS inventory sync pending", sync.body);
    return { ok: false, message: String(sync.body.message || "Inventory synchronization is pending.") };
  }
  return sync.body;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });

  const sessionToken = request.headers.get("x-staff-session") || "";
  if (!sessionToken) return jsonResponse({ ok: false, message: "Staff session is required." }, 401);

  try {
    const url = new URL(request.url);

    if (request.method === "POST") {
      const payload = await request.json().catch(() => null);
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        return jsonResponse({ ok: false, message: "Order payload must be an object." }, 400);
      }
      const record = payload as JsonRecord;
      const storeCode = String(record.store_db_code || record.store_code || record.store_id || "").trim().toLowerCase();

      if ((url.searchParams.get("mode") || "") === "google-review") {
        const staffName = String(record.staff_name || "");
        const eventCode = String(record.event_code || "");
        if (!storeCode || !staffName || !eventCode) {
          return jsonResponse({ ok: false, message: "store_code, staff_name, and event_code are required." }, 400);
        }
        const actor = await authorizedActor(sessionToken, storeCode, staffName);
        const result = await callRpc("record_pos_google_review", {
          session_token: sessionToken,
          target_store_code: storeCode,
          target_staff_name: String(actor.staff_name || ""),
          event_code: eventCode,
        });
        return jsonResponse(result.body, result.status);
      }

      await requireStoreAccess(sessionToken, storeCode);
      if (String(record.order_note || "").length > 1000) {
        return jsonResponse({ ok: false, message: "Order note cannot exceed 1000 characters." }, 400);
      }
      const items = Array.isArray(record.items) ? record.items as JsonRecord[] : [];
      if (items.some((item) => String(item?.note || "").length > 500)) {
        return jsonResponse({ ok: false, message: "Item note cannot exceed 500 characters." }, 400);
      }

      const requestedOrderCode = String(record.id || record.order_id || "").trim();
      if (requestedOrderCode) {
        const existing = await callRpc("get_pos_sales_order_for_store", {
          session_token: sessionToken,
          target_store_code: storeCode,
          target_order_code: requestedOrderCode,
        });
        if (existing.status < 400 && existing.body.ok && existing.body.order) {
          const inventory = await syncSavedOrder(sessionToken, storeCode, existing.body.order as JsonRecord);
          return jsonResponse({
            ...existing.body,
            inventory,
            inventory_sync_pending: !inventory.ok,
          });
        }
      }

      const saved = await callRpc("save_pos_sales_order_for_store", {
        session_token: sessionToken,
        payload: record,
      });
      if (saved.status >= 400 || !saved.body.ok) return jsonResponse(saved.body, saved.status);
      const order = (saved.body.order && typeof saved.body.order === "object")
        ? saved.body.order as JsonRecord
        : {};
      const inventory = await syncSavedOrder(sessionToken, storeCode, order);
      return jsonResponse({
        ...saved.body,
        inventory,
        inventory_sync_pending: !inventory.ok,
      }, saved.status);
    }

    if (request.method === "PUT") {
      const payload = await request.json().catch(() => null);
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        return jsonResponse({ ok: false, message: "Refund payload must be an object." }, 400);
      }
      const record = payload as JsonRecord;
      const storeCode = String(record.store_code || "").trim().toLowerCase();
      if (!record.order_id || !storeCode || !record.staff_name || !record.shift_id) {
        return jsonResponse({ ok: false, message: "order_id, store_code, staff_name, and shift_id are required." }, 400);
      }
      await requireStoreAccess(sessionToken, storeCode);

      const isBalance = (url.searchParams.get("mode") || "") === "balance-payment";
      if (isBalance && (!Array.isArray(record.payments) || record.payments.length === 0)) {
        return jsonResponse({ ok: false, message: "At least one payment is required." }, 400);
      }
      const result = await callRpc(
        isBalance ? "add_pos_sales_order_payment_for_store" : "refund_pos_sales_order_for_store",
        { session_token: sessionToken, payload: record },
      );
      if (result.status >= 400 || !result.body.ok) return jsonResponse(result.body, result.status);
      const order = (result.body.order && typeof result.body.order === "object")
        ? result.body.order as JsonRecord
        : {};
      const inventory = await syncSavedOrder(sessionToken, storeCode, order);
      return jsonResponse({
        ...result.body,
        inventory,
        inventory_sync_pending: !inventory.ok,
      }, result.status);
    }

    if (request.method === "GET") {
      const mode = url.searchParams.get("mode") || "";
      const storeCode = (url.searchParams.get("store_code") || "").trim().toLowerCase();
      if (!storeCode) return jsonResponse({ ok: false, message: "store_code is required." }, 400);
      await requireStoreAccess(sessionToken, storeCode);

      if (mode === "report") {
        const result = await callRpc("get_pos_sales_report", {
          session_token: sessionToken,
          target_store_code: storeCode,
          date_from: url.searchParams.get("from_date") || null,
          date_to: url.searchParams.get("to_date") || null,
          target_staff_name: url.searchParams.get("staff_name") || null,
        });
        return jsonResponse(result.body, result.status);
      }

      if (mode === "today-progress") {
        const requestedStaff = url.searchParams.get("staff_name") || "";
        if (!requestedStaff) return jsonResponse({ ok: false, message: "staff_name is required." }, 400);
        const actor = await authorizedActor(sessionToken, storeCode, requestedStaff);
        const result = await callRpc("get_pos_today_progress", {
          session_token: sessionToken,
          target_store_code: storeCode,
          target_staff_name: String(actor.staff_name || ""),
          target_business_date: url.searchParams.get("business_date") || null,
        });
        return jsonResponse(result.body, result.status);
      }

      const orderCode = url.searchParams.get("order_id") || "";
      if (orderCode) {
        const result = await callRpc("get_pos_sales_order_for_store", {
          session_token: sessionToken,
          target_store_code: storeCode,
          target_order_code: orderCode,
        });
        if (result.status < 400 && result.body.ok && result.body.order) {
          const inventory = await syncSavedOrder(sessionToken, storeCode, result.body.order as JsonRecord);
          return jsonResponse({ ...result.body, inventory, inventory_sync_pending: !inventory.ok }, result.status);
        }
        return jsonResponse(result.body, result.status);
      }

      const limit = Math.min(Math.max(Number(url.searchParams.get("limit") || 100), 1), 200);
      const offset = Math.max(Number(url.searchParams.get("offset") || 0), 0);
      const result = await callRpc("search_pos_sales_orders", {
        session_token: sessionToken,
        target_store_code: storeCode,
        search_query: url.searchParams.get("q") || "",
        result_limit: limit,
        result_offset: offset,
        date_from: url.searchParams.get("from_date") || null,
        date_to: url.searchParams.get("to_date") || null,
      });
      return jsonResponse(result.body, result.status);
    }

    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  } catch (error) {
    console.error(error);
    const message = error instanceof Error ? error.message : "POS order request failed.";
    const status = /denied|assigned|session/i.test(message) ? 403 : 500;
    return jsonResponse({ ok: false, message }, status);
  }
});
