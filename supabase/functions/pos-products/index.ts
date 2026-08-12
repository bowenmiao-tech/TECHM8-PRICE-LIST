import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session, x-admin-session",
  "Access-Control-Allow-Methods": "GET, PUT, OPTIONS",
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

async function callStaffRpc(
  rpcName: string,
  payload: JsonRecord,
  request: Request,
): Promise<JsonRecord> {
  const supabaseUrl = Deno.env.get("STAFF_AUTH_SUPABASE_URL")
    || Deno.env.get("SUPABASE_URL")
    || "";
  const incomingApiKey = request.headers.get("apikey") || "";
  const incomingAuthorization = request.headers.get("authorization") || "";
  const supabaseAnonKey = incomingApiKey
    || Deno.env.get("STAFF_AUTH_SUPABASE_ANON_KEY")
    || Deno.env.get("SUPABASE_ANON_KEY")
    || "";
  const authorization = incomingAuthorization || `Bearer ${supabaseAnonKey}`;

  if (!supabaseUrl || !supabaseAnonKey) {
    throw new Error("Supabase environment is not configured.");
  }

  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${rpcName}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: supabaseAnonKey,
      Authorization: authorization,
    },
    body: JSON.stringify(payload),
  });

  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(String((result as JsonRecord)?.message || "Staff authorization request failed."));
  }

  if (Array.isArray(result)) {
    return (result[0] as JsonRecord | undefined) || {};
  }
  return (result as JsonRecord | null) || {};
}

async function verifyStaffSession(sessionToken: string, request: Request): Promise<boolean> {
  const result = await callStaffRpc("verify_staff_session", { session_token: sessionToken }, request);
  return Boolean(result.ok);
}

async function verifyAdminSession(sessionToken: string, request: Request): Promise<boolean> {
  if (!sessionToken) return false;
  const result = await callStaffRpc("verify_admin_session", { session_token: sessionToken }, request);
  return Boolean(result.ok);
}

async function getStocktakeAccess(
  sessionToken: string,
  staffName: string,
  request: Request,
): Promise<JsonRecord> {
  return await callStaffRpc("get_staff_stocktake_access", {
    session_token: sessionToken,
    target_staff_name: staffName,
  }, request);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (request.method !== "GET" && request.method !== "PUT") {
    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  }

  const sessionToken = request.headers.get("x-staff-session") || "";
  if (!sessionToken) {
    return jsonResponse({ ok: false, message: "Staff session is required." }, 401);
  }

  let isStaff = false;
  try {
    isStaff = await verifyStaffSession(sessionToken, request);
  } catch (error) {
    console.error(error);
    return jsonResponse({ ok: false, message: "Unable to verify staff session." }, 500);
  }

  if (!isStaff) {
    return jsonResponse({ ok: false, message: "Invalid or expired staff session." }, 401);
  }

  const inputUrl = new URL(request.url);
  const mode = inputUrl.searchParams.get("mode") || "products";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const requestBody = request.method === "PUT"
    ? await request.json().catch(() => ({})) as JsonRecord
    : {};

  if (mode === "arrangement-context" && request.method === "GET") {
    const staffName = (inputUrl.searchParams.get("staff_name") || "").trim();
    const adminSessionToken = request.headers.get("x-admin-session") || "";
    if (staffName.toLowerCase() !== "bowen") {
      return jsonResponse({ ok: false, enabled: false, code: "ARRANGEMENT_FORBIDDEN", message: "POS arrangement is available to Bowen only." }, 403);
    }

    try {
      const isAdmin = await verifyAdminSession(adminSessionToken, request);
      if (!isAdmin) {
        return jsonResponse({ ok: false, enabled: false, code: "ADMIN_SESSION_REQUIRED", message: "Administrator sign-in is required." }, 401);
      }
      if (!supabaseUrl || !serviceRoleKey) {
        return jsonResponse({ ok: false, enabled: false, message: "Product database is not configured." }, 500);
      }

      const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
      const { data, error } = await supabaseAdmin
        .from("pos_category_taxonomy")
        .select("id, category_name, subcategory_name, category_sort, subcategory_sort")
        .eq("active", true)
        .order("category_sort", { ascending: true })
        .order("subcategory_sort", { ascending: true });

      if (error) throw error;
      return jsonResponse({
        ok: true,
        enabled: true,
        staff_name: "Bowen",
        categories: data || [],
      });
    } catch (error) {
      console.error(error);
      return jsonResponse({ ok: false, enabled: false, message: "POS arrangement access could not be verified." }, 500);
    }
  }

  if (request.method === "PUT" && String(requestBody.mode || "") === "arrangement") {
    const staffName = String(requestBody.staff_name || "").trim();
    const adminSessionToken = request.headers.get("x-admin-session") || "";
    if (staffName.toLowerCase() !== "bowen") {
      return jsonResponse({ ok: false, code: "ARRANGEMENT_FORBIDDEN", message: "POS arrangement is available to Bowen only." }, 403);
    }

    try {
      const isAdmin = await verifyAdminSession(adminSessionToken, request);
      if (!isAdmin) {
        return jsonResponse({ ok: false, code: "ADMIN_SESSION_REQUIRED", message: "Administrator sign-in is required." }, 401);
      }
      if (!supabaseUrl || !serviceRoleKey) {
        return jsonResponse({ ok: false, message: "Product database is not configured." }, 500);
      }

      const scope = String(requestBody.scope || "").trim().toLowerCase();
      const rows = Array.isArray(requestBody.rows) ? requestBody.rows : null;
      if (!["categories", "subcategories", "products"].includes(scope) || !rows || rows.length > 1000) {
        return jsonResponse({ ok: false, message: "A valid arrangement scope and rows are required." }, 400);
      }

      const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
      const { data, error } = await supabaseAdmin.rpc("apply_pos_catalog_arrangement", {
        target_scope: scope,
        target_rows: rows,
        target_staff_name: "Bowen",
      });
      if (error) throw error;
      return jsonResponse((data as JsonRecord) || { ok: true, scope, changed: rows.length });
    } catch (error) {
      console.error(error);
      return jsonResponse({ ok: false, message: "POS arrangement could not be saved." }, 500);
    }
  }

  if (mode === "stocktake-context" && request.method === "GET") {
    const staffName = (inputUrl.searchParams.get("staff_name") || "").trim();
    if (!staffName) {
      return jsonResponse({ ok: false, message: "Staff name is required." }, 400);
    }

    try {
      const access = await getStocktakeAccess(sessionToken, staffName, request);
      if (!access.ok) {
        return jsonResponse({ ok: false, enabled: false, message: String(access.message || "Staff not found.") }, 404);
      }
      if (!access.enabled) {
        return jsonResponse({ ok: true, enabled: false, staff_name: access.display_name || staffName, categories: [] });
      }
      if (!supabaseUrl || !serviceRoleKey) {
        return jsonResponse({ ok: false, message: "Product database is not configured." }, 500);
      }

      const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
      const { data, error } = await supabaseAdmin
        .from("pos_category_taxonomy")
        .select("id, category_name, subcategory_name, category_sort, subcategory_sort")
        .eq("active", true)
        .order("category_sort", { ascending: true })
        .order("subcategory_sort", { ascending: true });

      if (error) throw error;
      return jsonResponse({
        ok: true,
        enabled: true,
        staff_id: access.staff_id,
        staff_name: access.display_name || staffName,
        categories: data || [],
      });
    } catch (error) {
      console.error(error);
      return jsonResponse({ ok: false, enabled: false, message: "Stocktake access could not be loaded." }, 500);
    }
  }

  if (request.method === "PUT") {
    const body = requestBody;
    const staffName = String(body.staff_name || "").trim();
    const productId = Number(body.product_id);
    const posCategoryId = Number(body.pos_category_id);
    const quantity = Number(body.quantity);
    const storeSlug = String(body.store_slug || "").trim();

    if (!staffName || !storeSlug || !Number.isInteger(productId) || productId < 1
      || !Number.isInteger(posCategoryId) || posCategoryId < 1
      || !Number.isInteger(quantity) || quantity < 0 || quantity > 1000000) {
      return jsonResponse({ ok: false, message: "Valid staff, product, category, store, and quantity are required." }, 400);
    }

    try {
      const access = await getStocktakeAccess(sessionToken, staffName, request);
      if (!access.ok || !access.enabled) {
        return jsonResponse({ ok: false, code: "STOCKTAKE_ACCESS_DISABLED", message: "Stocktake access is not enabled for this staff member." }, 403);
      }
      if (!supabaseUrl || !serviceRoleKey) {
        return jsonResponse({ ok: false, message: "Product database is not configured." }, 500);
      }

      const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
      const { data, error } = await supabaseAdmin.rpc("apply_pos_stocktake_update", {
        target_product_id: productId,
        target_store_slug: storeSlug,
        target_pos_category_id: posCategoryId,
        target_quantity: quantity,
        target_staff_name: String(access.display_name || staffName),
      });

      if (error) throw error;
      return jsonResponse((data as JsonRecord) || { ok: true });
    } catch (error) {
      console.error(error);
      return jsonResponse({ ok: false, message: "Product stocktake changes could not be saved." }, 500);
    }
  }

  const upstreamEndpoint = Deno.env.get("INTERNAL_PRODUCTS_ENDPOINT")
    || "https://fwlronvmgqzkleofriis.supabase.co/functions/v1/internal-products";
  const upstreamApiKey = Deno.env.get("INTERNAL_PRODUCTS_API_KEY") || "";

  if (!upstreamApiKey) {
    return jsonResponse({ ok: false, message: "Internal products API key is not configured." }, 500);
  }

  const upstreamUrl = new URL(upstreamEndpoint);
  upstreamUrl.searchParams.set("page", inputUrl.searchParams.get("page") || "1");
  upstreamUrl.searchParams.set("limit", inputUrl.searchParams.get("limit") || "500");

  const search = inputUrl.searchParams.get("search");
  const category = inputUrl.searchParams.get("category");
  if (search) upstreamUrl.searchParams.set("search", search);
  if (category) upstreamUrl.searchParams.set("category", category);

  try {
    const response = await fetch(upstreamUrl.toString(), {
      method: "GET",
      headers: {
        Accept: "application/json",
        "x-api-key": upstreamApiKey,
      },
    });

    const body = await response.text();
    return new Response(body, {
      status: response.status,
      headers: {
        ...corsHeaders,
        "Content-Type": response.headers.get("Content-Type") || "application/json; charset=utf-8",
      },
    });
  } catch (error) {
    console.error(error);
    return jsonResponse({ ok: false, message: "Product API request failed." }, 502);
  }
});
