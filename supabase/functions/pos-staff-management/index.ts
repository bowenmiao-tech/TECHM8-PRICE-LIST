const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-admin-session",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
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

function rpcMessage(body: JsonRecord, fallback: string): string {
  return String(body.message || body.error || fallback).replace(/^ERROR:\s*/i, "").split("\n")[0];
}

function inviteLink(token: string): string {
  const base = (Deno.env.get("STAFF_PORTAL_URL") || "https://oztechm8.com.au").replace(/\/+$/, "");
  return `${base}/?reset=${encodeURIComponent(token)}`;
}

async function sendInviteEmail(name: string, email: string, token: string, minutes: number): Promise<void> {
  const link = inviteLink(token);
  const relayUrl = Deno.env.get("STAFF_RESET_RELAY_URL") || "";
  const relaySecret = Deno.env.get("STAFF_RESET_RELAY_SECRET") || "";
  if (!relayUrl || !relaySecret) throw new Error("Staff invite email is not configured.");
  const response = await fetch(relayUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Techm8-Relay-Secret": relaySecret },
    body: JSON.stringify({ to: email, staffName: name, link, minutes, purpose: "invite" }),
  });
  if (!response.ok) {
    console.error("staff invite relay failed", response.status);
    throw new Error("The invitation email could not be sent. Use Resend invite after checking email delivery.");
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (!["GET", "POST", "PUT", "DELETE"].includes(request.method)) {
    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  }

  const sessionToken = request.headers.get("x-admin-session") || "";
  if (!sessionToken) return jsonResponse({ ok: false, message: "Admin session is required." }, 401);

  try {
    if (request.method === "GET") {
      const mode = new URL(request.url).searchParams.get("mode") || "";
      if (mode === "reviews" || mode === "points") {
        const result = await callRpc(mode === "points" ? "get_staff_points_report" : "get_staff_google_review_report", {
          session_token: sessionToken,
          result_limit: 500,
        });
        return jsonResponse(result.body, result.status);
      }
      const result = await callRpc("get_staff_management", { session_token: sessionToken });
      return jsonResponse(result.body, result.status);
    }

    const payload = await request.json().catch(() => null);
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      return jsonResponse({ ok: false, message: "Staff update must be an object." }, 400);
    }
    const record = payload as JsonRecord;

    if (request.method === "POST") {
      const action = String(record.action || "create");
      if (action !== "create" && action !== "invite") {
        return jsonResponse({ ok: false, message: "Unknown staff action." }, 400);
      }
      let result: { status: number; body: JsonRecord };
      if (action === "create") {
        const storeCodes = Array.isArray(record.store_codes)
          ? Array.from(new Set(record.store_codes.map((value) => String(value || "").trim().toLowerCase()).filter(Boolean)))
          : [];
        if (!storeCodes.length || storeCodes.length > 50) {
          return jsonResponse({ ok: false, message: "Select at least one store." }, 400);
        }
        result = await callRpc("create_staff_management", {
          session_token: sessionToken,
          new_display_name: String(record.display_name || "").trim(),
          new_email: String(record.email || "").trim().toLowerCase(),
          new_store_codes: storeCodes,
          new_stocktake_enabled: record.stocktake_enabled === true,
        });
      } else {
        const staffId = Number(record.staff_id);
        if (!Number.isSafeInteger(staffId) || staffId <= 0) {
          return jsonResponse({ ok: false, message: "Staff member is required." }, 400);
        }
        result = await callRpc("issue_staff_invite", { session_token: sessionToken, target_staff_id: staffId });
      }
      if (result.status >= 400 || result.body.ok !== true) {
        return jsonResponse({ ok: false, message: rpcMessage(result.body, "Staff invitation failed.") }, 400);
      }
      try {
        await sendInviteEmail(
          String(result.body.staff_name || ""), String(result.body.staff_email || ""),
          String(result.body.invite_token || ""), Number(result.body.expires_in_minutes || 30),
        );
      } catch (error) {
        console.error("staff invitation delivery failed", error);
        return jsonResponse({ ok: false, created: action === "create", staff: result.body.staff || null,
          message: error instanceof Error ? error.message : "Invitation email could not be sent." }, 502);
      }
      return jsonResponse({ ok: true, staff: result.body.staff || null,
        staff_id: result.body.staff_id || null, message: "Invitation email sent." });
    }

    const staffId = Number(record.staff_id);
    if (request.method === "DELETE") {
      if (!Number.isSafeInteger(staffId) || staffId <= 0) {
        return jsonResponse({ ok: false, message: "Staff member is required." }, 400);
      }
      const result = await callRpc("archive_staff_management", {
        session_token: sessionToken, target_staff_id: staffId,
      });
      if (result.status >= 400 || result.body.ok !== true) {
        return jsonResponse({ ok: false, message: rpcMessage(result.body, "Staff member could not be deleted.") }, 400);
      }
      return jsonResponse(result.body);
    }
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
