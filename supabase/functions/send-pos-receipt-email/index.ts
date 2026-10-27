import {
  invoiceNumberText,
  type JsonRecord,
  receiptEmailHtml,
  storeProfileForOrder,
} from "./receipt-template.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
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
    const storeCode = String(input.store_code || "").trim();
    const recipient = String(input.to || "").trim().toLowerCase();
    const subject = String(input.subject || "").trim().slice(0, 180);
    const note = String(input.note || "").trim().slice(0, 1500);
    const sendCopy = input.send_copy === true;
    const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!orderCode) return jsonResponse({ ok: false, message: "Order id is required." }, 400);
    if (!storeCode) return jsonResponse({ ok: false, message: "Store code is required." }, 400);
    if (!emailPattern.test(recipient)) return jsonResponse({ ok: false, message: "A valid recipient email is required." }, 400);

    const orderResult = await callRpc(request, "get_pos_sales_order_for_store", {
      session_token: sessionToken,
      target_store_code: storeCode,
      target_order_code: orderCode,
    });
    if (!orderResult.ok || orderResult.data.ok === false || !orderResult.data.order) {
      const message = String(orderResult.data.message || "Order could not be loaded.");
      return jsonResponse({ ok: false, message }, message.toLowerCase().includes("session") ? 401 : 400);
    }

    const order = orderResult.data.order as JsonRecord;
    const profile = storeProfileForOrder(order);
    const resendApiKey = Deno.env.get("RESEND_API_KEY") || Deno.env.get("RESEND_API_KEY_BOOKING") || "";
    const fromAddress = Deno.env.get("POS_RECEIPT_FROM") || Deno.env.get("BOOKING_FROM_EMAIL") || "";
    if (!resendApiKey || !fromAddress) {
      return jsonResponse({ ok: false, message: "Receipt email service is not configured." }, 500);
    }

    const resendPayload: JsonRecord = {
      from: fromAddress,
      to: [recipient],
      reply_to: profile.email,
      subject: subject || `Tax Invoice #${invoiceNumberText(order)} from ${order.store_name || "TechM8"}`,
      html: receiptEmailHtml(order, note),
    };
    if (sendCopy) resendPayload.cc = [profile.email];

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
