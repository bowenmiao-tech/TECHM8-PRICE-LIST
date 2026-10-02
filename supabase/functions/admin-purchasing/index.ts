import { createClient } from "npm:@supabase/supabase-js@2";

// Admin-only API for the China purchasing page. The admin session lives in the
// staff/price-list project; the purchase tables and stock live here in the
// product project, so every request is verified remotely before any RPC runs.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-admin-session",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type JsonRecord = Record<string, unknown>;

const PAYLOAD_ACTIONS: Record<string, string> = {
  save_supplier: "purchase_admin_save_supplier",
  save_forwarder: "purchase_admin_save_forwarder",
  save_order: "purchase_admin_save_order",
  save_parcel: "purchase_admin_save_parcel",
  save_shipment: "purchase_admin_save_shipment",
  create_product: "purchase_admin_create_product",
  post_receipt: "purchase_admin_post_receipt",
};

const DELETE_ACTIONS: Record<string, string> = {
  delete_order: "purchase_admin_delete_order",
  delete_parcel: "purchase_admin_delete_parcel",
  delete_shipment: "purchase_admin_delete_shipment",
};

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

function errorMessage(error: unknown, fallback: string): string {
  if (error && typeof error === "object" && "message" in error) {
    const message = String((error as { message?: unknown }).message || "").trim();
    if (message) return message;
  }
  return fallback;
}

function errorStatus(message: string): number {
  if (/admin session|sign in/i.test(message)) return 401;
  if (/not found/i.test(message)) return 404;
  if (/already|cannot|different operation/i.test(message)) return 409;
  if (/required|invalid|must|choose|needs|list|above zero/i.test(message)) return 400;
  return 500;
}

async function verifyAdminSession(sessionToken: string, request: Request): Promise<void> {
  if (!sessionToken) throw new Error("Admin session is required. Please sign in again.");
  const supabaseUrl = Deno.env.get("STAFF_AUTH_SUPABASE_URL") || "";
  const anonKey = request.headers.get("apikey") || Deno.env.get("STAFF_AUTH_SUPABASE_ANON_KEY") || "";
  if (!supabaseUrl || !anonKey) throw new Error("Staff authorization is not configured.");

  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/verify_admin_session`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: anonKey,
      Authorization: `Bearer ${anonKey}`,
    },
    body: JSON.stringify({ session_token: sessionToken }),
  });
  const result = await response.json().catch(() => ({})) as JsonRecord;
  if (!response.ok || result.ok !== true) {
    throw new Error("Admin session expired. Please sign in again.");
  }
}

function productAdminClient() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!supabaseUrl || !serviceRoleKey) throw new Error("Product database is not configured.");
  return createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
}

function actorName(body: JsonRecord): string {
  const name = String(body.actor_name || "").trim().slice(0, 80);
  return name ? `${name} (admin)` : "Admin";
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ ok: false, message: "Method not allowed." }, 405);

  try {
    await verifyAdminSession(request.headers.get("x-admin-session") || "", request);

    const body = await request.json().catch(() => ({})) as JsonRecord;
    const action = String(body.action || "");
    const payload = (body.payload && typeof body.payload === "object") ? body.payload : {};
    const admin = productAdminClient();

    const snapshot = async () => {
      const { data, error } = await admin.rpc("purchase_admin_snapshot");
      if (error) throw error;
      return data;
    };

    if (action === "snapshot") {
      return jsonResponse({ ok: true, snapshot: await snapshot() });
    }

    if (action === "search_products") {
      const { data, error } = await admin.rpc("purchase_admin_search_products", {
        search_text: String((payload as JsonRecord).q || ""),
        max_rows: 30,
      });
      if (error) throw error;
      return jsonResponse({ ok: true, products: data || [] });
    }

    if (PAYLOAD_ACTIONS[action]) {
      const { data, error } = await admin.rpc(PAYLOAD_ACTIONS[action], {
        payload,
        actor: actorName(body),
      });
      if (error) throw error;
      return jsonResponse({ ok: true, result: data, snapshot: await snapshot() });
    }

    if (DELETE_ACTIONS[action]) {
      const targetId = Number((payload as JsonRecord).id);
      if (!Number.isInteger(targetId) || targetId < 1) throw new Error("A valid id is required.");
      const { data, error } = await admin.rpc(DELETE_ACTIONS[action], {
        target_id: targetId,
        actor: actorName(body),
      });
      if (error) throw error;
      return jsonResponse({ ok: true, result: data, snapshot: await snapshot() });
    }

    return jsonResponse({ ok: false, message: "Unknown action." }, 400);
  } catch (error) {
    const message = errorMessage(error, "Purchasing request failed.");
    const status = errorStatus(message);
    if (status === 500) console.error(error);
    return jsonResponse({ ok: false, message }, status);
  }
});
