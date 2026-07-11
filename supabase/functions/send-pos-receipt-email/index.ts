const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type JsonRecord = Record<string, unknown>;

const storeProfiles: Record<string, { name: string; address: string; phone: string; abn: string }> = {
  "park-ridge": {
    name: "TechM8 Park Ridge",
    address: "Shop 11/3744 Mount Lindesay Hwy, Park Ridge South QLD 4125",
    phone: "+61 452 488 710",
    abn: "12 645 861 463",
  },
  parkridge: {
    name: "TechM8 Park Ridge",
    address: "Shop 11/3744 Mount Lindesay Hwy, Park Ridge South QLD 4125",
    phone: "+61 452 488 710",
    abn: "12 645 861 463",
  },
  "north-lakes": {
    name: "TechM8 North Lakes",
    address: "OZTECHM8 (Near BigW) Shop 1114A, N Lakes Dr, North Lakes QLD 4509",
    phone: "+61 482 390 009",
    abn: "12 645 861 463",
  },
  northlakes: {
    name: "TechM8 North Lakes",
    address: "OZTECHM8 (Near BigW) Shop 1114A, N Lakes Dr, North Lakes QLD 4509",
    phone: "+61 482 390 009",
    abn: "12 645 861 463",
  },
  fairfield: {
    name: "TechM8 Fairfield",
    address: "Shop 8 Fairfield Gardens Shopping Centre",
    phone: "+61 412 788 818",
    abn: "12 645 861 463",
  },
  toowong: {
    name: "TechM8 Toowong",
    address: "G53/9 Sherwood Rd, Toowong QLD 4066",
    phone: "+61 485 500 099",
    abn: "69 656 056 352",
  },
};

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function money(value: unknown): string {
  const amount = Number(value || 0);
  return new Intl.NumberFormat("en-AU", {
    style: "currency",
    currency: "AUD",
  }).format(Number.isFinite(amount) ? amount : 0);
}

function normalizedStoreKey(order: JsonRecord): string {
  return String(order.store_id || order.store_db_code || "")
    .trim()
    .toLowerCase()
    .replaceAll("_", "-");
}

function orderDate(value: unknown): string {
  const date = value ? new Date(String(value)) : new Date();
  return new Intl.DateTimeFormat("en-AU", {
    timeZone: "Australia/Brisbane",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function receiptEmailHtml(order: JsonRecord, note: string): string {
  const profile = storeProfiles[normalizedStoreKey(order)] || {
    name: String(order.store_name || "TechM8 Australia"),
    address: "",
    phone: "",
    abn: "",
  };
  const items = Array.isArray(order.items) ? order.items as JsonRecord[] : [];
  const payments = Array.isArray(order.payments) ? order.payments as JsonRecord[] : [];
  const total = Number(order.total || 0);
  const gst = Math.round((total / 11) * 100) / 100;
  const subtotal = Math.round((total - gst) * 100) / 100;
  const itemRows = items.map((item) => `
    <tr>
      <td style="padding:14px 0;border-bottom:1px solid #e2e8e6;">
        <div style="font-weight:800;color:#14231e;">${escapeHtml(item.name || "Product")}</div>
        ${item.sku ? `<div style="margin-top:4px;font-size:12px;color:#708078;">SKU: ${escapeHtml(item.sku)}</div>` : ""}
      </td>
      <td style="padding:14px 8px;border-bottom:1px solid #e2e8e6;text-align:center;color:#52625b;">${escapeHtml(item.qty || 1)}</td>
      <td style="padding:14px 0;border-bottom:1px solid #e2e8e6;text-align:right;font-weight:800;color:#14231e;">${money(item.line_total)}</td>
    </tr>
  `).join("");
  const paymentRows = payments.map((payment) => `
    <tr>
      <td style="padding:5px 0;color:#52625b;">${escapeHtml(payment.method || "Payment")}</td>
      <td style="padding:5px 0;text-align:right;font-weight:700;color:#14231e;">${money(payment.amount)}</td>
    </tr>
  `).join("");
  const customerName = String(order.customer_name || "Walk-in Customer");
  const noteHtml = note ? `<div style="margin:0 0 22px;padding:14px 16px;border-radius:8px;background:#eef8f5;color:#29473e;line-height:1.6;">${escapeHtml(note).replaceAll("\n", "<br>")}</div>` : "";

  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:#edf3f1;font-family:Arial,Helvetica,sans-serif;color:#14231e;">
  <div style="padding:32px 12px;">
    <div style="max-width:640px;margin:0 auto;overflow:hidden;border-radius:10px;background:#ffffff;box-shadow:0 8px 26px rgba(20,35,30,.08);">
      <div style="padding:28px 30px;background:#07896f;color:#ffffff;">
        <div style="font-size:28px;font-weight:900;">TECHM8</div>
        <div style="margin-top:6px;font-size:15px;font-weight:700;">${escapeHtml(profile.name)}</div>
      </div>
      <div style="padding:30px;">
        <h1 style="margin:0 0 8px;font-size:27px;line-height:1.2;">Here's your tax receipt</h1>
        <p style="margin:0 0 22px;color:#62736b;line-height:1.6;">Thanks for shopping with us. Your payment has been completed and recorded.</p>
        ${noteHtml}
        <table role="presentation" style="width:100%;margin-bottom:22px;border-collapse:collapse;font-size:14px;">
          <tr><td style="padding:4px 0;color:#708078;">Receipt</td><td style="padding:4px 0;text-align:right;font-weight:800;">${escapeHtml(order.id)}</td></tr>
          <tr><td style="padding:4px 0;color:#708078;">Date</td><td style="padding:4px 0;text-align:right;font-weight:800;">${escapeHtml(orderDate(order.created_at))}</td></tr>
          <tr><td style="padding:4px 0;color:#708078;">Customer</td><td style="padding:4px 0;text-align:right;font-weight:800;">${escapeHtml(customerName)}</td></tr>
          <tr><td style="padding:4px 0;color:#708078;">Served by</td><td style="padding:4px 0;text-align:right;font-weight:800;">${escapeHtml(order.staff_name)}</td></tr>
        </table>
        <h2 style="margin:0 0 8px;font-size:19px;">What's included</h2>
        <table role="presentation" style="width:100%;border-collapse:collapse;font-size:14px;">
          <thead><tr><th style="padding:8px 0;text-align:left;color:#708078;">Item</th><th style="padding:8px;text-align:center;color:#708078;">Qty</th><th style="padding:8px 0;text-align:right;color:#708078;">Amount</th></tr></thead>
          <tbody>${itemRows}</tbody>
        </table>
        <table role="presentation" style="width:100%;margin-top:20px;border-collapse:collapse;font-size:14px;">
          <tr><td style="padding:5px 0;color:#52625b;">Subtotal (ex GST)</td><td style="padding:5px 0;text-align:right;font-weight:700;">${money(subtotal)}</td></tr>
          <tr><td style="padding:5px 0;color:#52625b;">GST</td><td style="padding:5px 0;text-align:right;font-weight:700;">${money(gst)}</td></tr>
          <tr><td style="padding:12px 0 7px;border-top:2px solid #14231e;font-size:18px;font-weight:900;">Total</td><td style="padding:12px 0 7px;border-top:2px solid #14231e;text-align:right;font-size:18px;font-weight:900;">${money(total)}</td></tr>
          ${paymentRows}
          <tr><td style="padding:5px 0;color:#52625b;">Balance</td><td style="padding:5px 0;text-align:right;font-weight:700;">$0.00</td></tr>
        </table>
      </div>
      <div style="padding:22px 30px;background:#f5f8f7;color:#687870;font-size:12px;line-height:1.6;text-align:center;">
        <div style="font-weight:800;color:#33473f;">${escapeHtml(profile.name)}</div>
        ${profile.address ? `<div>${escapeHtml(profile.address)}</div>` : ""}
        ${profile.phone ? `<div>${escapeHtml(profile.phone)}</div>` : ""}
        ${profile.abn ? `<div>ABN ${escapeHtml(profile.abn)}</div>` : ""}
        <div><a href="https://www.techm8australia.com/" style="color:#07896f;">www.techm8australia.com</a></div>
      </div>
    </div>
  </div>
</body>
</html>`;
}

function supabaseConfig(request: Request): { url: string; anonKey: string; authorization: string } {
  const url = Deno.env.get("STAFF_AUTH_SUPABASE_URL") || Deno.env.get("SUPABASE_URL") || "";
  const incomingApiKey = request.headers.get("apikey") || "";
  const incomingAuthorization = request.headers.get("authorization") || "";
  const anonKey = incomingApiKey
    || Deno.env.get("STAFF_AUTH_SUPABASE_ANON_KEY")
    || Deno.env.get("SUPABASE_ANON_KEY")
    || "";
  if (!url || !anonKey) throw new Error("Supabase environment is not configured.");
  return {
    url,
    anonKey,
    authorization: incomingAuthorization || `Bearer ${anonKey}`,
  };
}

async function callRpc(
  request: Request,
  rpcName: string,
  payload: JsonRecord,
): Promise<{ ok: boolean; status: number; data: JsonRecord }> {
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
  return {
    ok: response.ok,
    status: response.status,
    data: await response.json().catch(() => ({})) as JsonRecord,
  };
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  }

  const sessionToken = request.headers.get("x-staff-session") || "";
  if (!sessionToken) {
    return jsonResponse({ ok: false, message: "Staff session is required." }, 401);
  }

  try {
    const input = await request.json().catch(() => null) as JsonRecord | null;
    if (!input) return jsonResponse({ ok: false, message: "Email payload is required." }, 400);

    const orderCode = String(input.order_id || "").trim();
    const recipient = String(input.to || "").trim().toLowerCase();
    const subject = String(input.subject || "").trim().slice(0, 180);
    const note = String(input.note || "").trim().slice(0, 1500);
    const sendCopy = input.send_copy === true;
    const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!orderCode) return jsonResponse({ ok: false, message: "Order id is required." }, 400);
    if (!emailPattern.test(recipient)) return jsonResponse({ ok: false, message: "A valid recipient email is required." }, 400);

    const orderResult = await callRpc(request, "get_pos_sales_order", {
      session_token: sessionToken,
      target_order_code: orderCode,
    });
    if (!orderResult.ok || orderResult.data.ok === false || !orderResult.data.order) {
      const message = String(orderResult.data.message || "Order could not be loaded.");
      return jsonResponse({ ok: false, message }, message.toLowerCase().includes("session") ? 401 : 400);
    }

    const order = orderResult.data.order as JsonRecord;
    const resendApiKey = Deno.env.get("RESEND_API_KEY") || Deno.env.get("RESEND_API_KEY_BOOKING") || "";
    const fromAddress = Deno.env.get("POS_RECEIPT_FROM") || Deno.env.get("BOOKING_FROM_EMAIL") || "";
    const copyAddress = Deno.env.get("POS_RECEIPT_COPY_TO") || "techm8contact@gmail.com";
    if (!resendApiKey || !fromAddress) {
      return jsonResponse({ ok: false, message: "Receipt email service is not configured." }, 500);
    }

    const resendPayload: JsonRecord = {
      from: fromAddress,
      to: [recipient],
      subject: subject || `Payment Receipt ${orderCode} from ${order.store_name || "TechM8"}`,
      html: receiptEmailHtml(order, note),
    };
    if (sendCopy) resendPayload.cc = [copyAddress];

    const resendResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${resendApiKey}`,
      },
      body: JSON.stringify(resendPayload),
    });
    const resendData = await resendResponse.json().catch(() => ({})) as JsonRecord;
    if (!resendResponse.ok) {
      console.error("Resend error", resendData);
      return jsonResponse({ ok: false, message: String(resendData.message || "Email provider rejected the receipt.") }, 502);
    }

    const markResult = await callRpc(request, "mark_pos_receipt_emailed", {
      session_token: sessionToken,
      target_order_code: orderCode,
      recipient_email: recipient,
    });
    if (!markResult.ok) console.error("Receipt email audit update failed", markResult.data);

    return jsonResponse({ ok: true, message: "Receipt email sent.", email_id: resendData.id || "" });
  } catch (error) {
    console.error(error);
    return jsonResponse({ ok: false, message: "Receipt email request failed." }, 500);
  }
});
