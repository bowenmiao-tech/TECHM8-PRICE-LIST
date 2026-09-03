type JsonRecord = Record<string, unknown>;

const TOKEN_PATTERN = /^[0-9a-f]{64}$/;

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
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

async function secretsMatch(provided: string, expected: string): Promise<boolean> {
  if (!provided || !expected) return false;
  const encoder = new TextEncoder();
  const [providedHash, expectedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const left = new Uint8Array(providedHash);
  const right = new Uint8Array(expectedHash);
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}

function isValidResetLink(value: string): boolean {
  try {
    const link = new URL(value);
    const portal = new URL(Deno.env.get("STAFF_PORTAL_URL") || "https://oztechm8.com.au");
    return link.protocol === "https:"
      && link.origin === portal.origin
      && TOKEN_PATTERN.test(link.searchParams.get("reset") || "");
  } catch {
    return false;
  }
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return jsonResponse({ ok: false, message: "Method not allowed." }, 405);

  const expectedSecret = Deno.env.get("STAFF_RESET_RELAY_SECRET") || "";
  const providedSecret = request.headers.get("X-Techm8-Relay-Secret") || "";
  if (!(await secretsMatch(providedSecret, expectedSecret))) {
    return jsonResponse({ ok: false, message: "Not authorized." }, 401);
  }

  const payload = await request.json().catch(() => null);
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return jsonResponse({ ok: false, message: "Invalid request." }, 400);
  }

  const record = payload as JsonRecord;
  const to = String(record.to || "").trim().toLowerCase();
  const staffName = String(record.staffName || "").trim().slice(0, 120);
  const link = String(record.link || "").trim();
  const requestedMinutes = Number(record.minutes || 30);
  const minutes = Number.isFinite(requestedMinutes)
    ? Math.min(60, Math.max(1, Math.round(requestedMinutes)))
    : 30;

  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to) || !isValidResetLink(link)) {
    return jsonResponse({ ok: false, message: "Invalid reset email request." }, 400);
  }

  const apiKey = Deno.env.get("RESEND_API_KEY") || Deno.env.get("RESEND_API_KEY_BOOKING") || "";
  const from = Deno.env.get("STAFF_RESET_FROM")
    || Deno.env.get("POS_RECEIPT_FROM")
    || Deno.env.get("BOOKING_FROM_EMAIL")
    || "";
  if (!apiKey || !from) {
    console.error("staff reset relay email provider is not configured");
    return jsonResponse({ ok: false, message: "Email delivery is unavailable." }, 503);
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
    console.error("staff reset relay provider failed", response.status, detail.slice(0, 200));
    return jsonResponse({ ok: false, message: "Email delivery failed." }, 502);
  }

  return jsonResponse({ ok: true });
});
