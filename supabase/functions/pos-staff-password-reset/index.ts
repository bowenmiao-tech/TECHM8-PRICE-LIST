const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type JsonRecord = Record<string, unknown>;

const TOKEN_PATTERN = /^[0-9a-f]{64}$/;

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

async function callRpc(name: string, payload: JsonRecord): Promise<{ status: number; body: JsonRecord }> {
  const url = Deno.env.get("SUPABASE_URL") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!url || !serviceKey) throw new Error("Password reset is not configured.");

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

function rpcErrorMessage(body: JsonRecord, fallback: string): string {
  const raw = String(body.message || body.error || body.hint || "").trim();
  if (!raw) return fallback;
  // PostgREST prefixes raised exceptions; keep the readable half only.
  return raw.replace(/^ERROR:\s*/i, "").split("\n")[0];
}

function resetLink(token: string): string {
  const base = (Deno.env.get("STAFF_PORTAL_URL") || "https://oztechm8.com.au").replace(/\/+$/, "");
  return `${base}/?reset=${encodeURIComponent(token)}`;
}

async function sendResetEmail(to: string, staffName: string, token: string, minutes: number): Promise<void> {
  const apiKey = Deno.env.get("RESEND_API_KEY") || Deno.env.get("RESEND_API_KEY_BOOKING") || "";
  const from = Deno.env.get("STAFF_RESET_FROM")
    || Deno.env.get("POS_RECEIPT_FROM")
    || Deno.env.get("BOOKING_FROM_EMAIL")
    || "";
  const link = resetLink(token);

  // The staff-auth project intentionally does not duplicate the mail provider
  // credential. When local mail secrets are absent, it uses the dedicated
  // relay in the website project, protected by a shared random secret.
  if (!apiKey || !from) {
    const relayUrl = Deno.env.get("STAFF_RESET_RELAY_URL") || "";
    const relaySecret = Deno.env.get("STAFF_RESET_RELAY_SECRET") || "";
    if (!relayUrl || !relaySecret) throw new Error("Password reset email is not configured.");

    const relayResponse = await fetch(relayUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Techm8-Relay-Secret": relaySecret,
      },
      body: JSON.stringify({ to, staffName, link, minutes }),
    });
    if (!relayResponse.ok) {
      const detail = await relayResponse.text().catch(() => "");
      throw new Error(`Reset email relay failed. ${detail.slice(0, 200)}`);
    }
    return;
  }

  const safeName = escapeHtml(staffName || "there");
  const safeLink = escapeHtml(link);
  const html = `<div style="font-family:Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;color:#12262b;line-height:1.6">
  <p>Hi ${safeName},</p>
  <p>We received a request to reset the password for your TECHM8 staff account.</p>
  <p style="margin:26px 0"><a href="${safeLink}" style="background:#0b4f58;color:#ffffff;text-decoration:none;padding:12px 22px;border-radius:8px;display:inline-block;font-weight:600">Set a new password</a></p>
  <p>This link works once and expires in ${minutes} minutes. Signing in again on your other devices will be required afterwards.</p>
  <p>If you did not request this, you can ignore this email — your current password stays active.</p>
  <p style="color:#5d7176;font-size:13px">If the button does not open, paste this address into your browser:<br>${safeLink}</p>
</div>`;
  const text = [
    `Hi ${staffName || "there"},`,
    "",
    "We received a request to reset the password for your TECHM8 staff account.",
    "",
    link,
    "",
    `This link works once and expires in ${minutes} minutes.`,
    "If you did not request this, you can ignore this email - your current password stays active.",
  ].join("\n");

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      from,
      to: [to],
      subject: "Reset your TECHM8 staff password",
      html,
      text,
    }),
  });
  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(`Reset email could not be sent. ${detail.slice(0, 200)}`);
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ ok: false, message: "Method not allowed." }, 405);

  const payload = await request.json().catch(() => null);
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return jsonResponse({ ok: false, message: "Request body must be an object." }, 400);
  }
  const record = payload as JsonRecord;
  const action = String(record.action || "").trim().toLowerCase();

  try {
    if (action === "request") {
      const email = String(record.email || "").trim().toLowerCase();
      // The response never depends on whether the address exists, so a stranger
      // cannot use this endpoint to discover staff email addresses.
      const generic = {
        ok: true,
        message: "If that email belongs to a staff account, a reset link is on its way.",
      };
      if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return jsonResponse(generic);

      const result = await callRpc("request_staff_password_reset", { login_email: email });
      if (result.status >= 400) {
        console.error("reset request rpc failed", result.status, result.body);
        return jsonResponse(generic);
      }
      if (result.body.issued === true) {
        const token = String(result.body.reset_token || "");
        const staffEmail = String(result.body.staff_email || email);
        const staffName = String(result.body.staff_name || "");
        const minutes = Number(result.body.expires_in_minutes || 30);
        try {
          await sendResetEmail(staffEmail, staffName, token, minutes);
        } catch (error) {
          console.error("reset email failed", error);
          return jsonResponse({
            ok: false,
            message: "The reset email could not be sent. Ask a manager to reset your password.",
          }, 502);
        }
      }
      return jsonResponse(generic);
    }

    if (action === "verify") {
      const token = String(record.token || "").trim();
      if (!TOKEN_PATTERN.test(token)) return jsonResponse({ ok: true, valid: false });
      const result = await callRpc("verify_staff_password_reset", { reset_token: token });
      if (result.status >= 400) return jsonResponse({ ok: true, valid: false });
      return jsonResponse(result.body, 200);
    }

    if (action === "complete") {
      const token = String(record.token || "").trim();
      const password = String(record.password || "");
      const pin = String(record.pin || "").trim();
      if (!TOKEN_PATTERN.test(token)) {
        return jsonResponse({ ok: false, message: "This reset link is no longer valid. Request a new one." }, 400);
      }
      const result = await callRpc("complete_staff_password_reset", {
        reset_token: token,
        new_password: password,
        new_pin: pin,
      });
      if (result.status >= 400) {
        return jsonResponse({
          ok: false,
          message: rpcErrorMessage(result.body, "The password could not be updated."),
        }, 400);
      }
      return jsonResponse(result.body, 200);
    }

    return jsonResponse({ ok: false, message: "Unknown action." }, 400);
  } catch (error) {
    console.error("password reset failed", error);
    return jsonResponse({ ok: false, message: "Password reset is unavailable right now." }, 500);
  }
});
