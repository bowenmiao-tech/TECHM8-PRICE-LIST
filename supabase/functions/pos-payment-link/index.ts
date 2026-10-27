// Runs in the website project (fwlronvmgqzkleofriis), which holds the Stripe
// keys, the Stripe webhook and the mailer. The POS project owns the invoice.
//
//   POST {action: 'create', link}
//        From pos-sales-orders in the POS project. Closes any Checkout session
//        the link replaces, opens a new one for the link amount and emails the
//        customer a "Pay now" button. Answers {session_id, url, expires_at, email_sent}.
//   POST {action: 'stripe-event', type, session_id}
//        From this project's stripe-webhook, for sessions it recognises as a
//        POS link. Re-reads the session from Stripe, records the payment in the
//        POS, then emails the customer their tax invoice. Safe to repeat.
//
// Both need the shared secret the two projects already use for used devices.
import Stripe from "npm:stripe@16.12.0";
import {
  escapeHtml,
  invoiceNumberText,
  type JsonRecord,
  money,
  receiptEmailHtml,
  storeProfileForOrder,
} from "../send-pos-receipt-email/receipt-template.ts";

const POS_LINK_SOURCE = "techm8_pos_payment_link";

// Stripe allows 24 hours at most; stay inside it.
const LINK_LIFETIME_SECONDS = 23 * 60 * 60;

function reply(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

function sameSecret(given: string, expected: string): boolean {
  if (!given || given.length !== expected.length) return false;
  let difference = 0;
  for (let index = 0; index < given.length; index += 1) difference |= given.charCodeAt(index) ^ expected.charCodeAt(index);
  return difference === 0;
}

function stripeClient(): Stripe {
  const key = Deno.env.get("STRIPE_SECRET_KEY") || "";
  if (!key) throw new Error("Stripe is not configured.");
  return new Stripe(key, { apiVersion: "2024-06-20" });
}

async function sendEmail(to: string, replyTo: string, subject: string, html: string): Promise<void> {
  const resendApiKey = Deno.env.get("RESEND_API_KEY") || Deno.env.get("RESEND_API_KEY_BOOKING") || "";
  const fromAddress = Deno.env.get("POS_RECEIPT_FROM") || Deno.env.get("BOOKING_FROM_EMAIL") || "";
  if (!resendApiKey || !fromAddress) throw new Error("Email service is not configured.");
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${resendApiKey}` },
    body: JSON.stringify({ from: fromAddress, to: [to], reply_to: replyTo, subject, html }),
  });
  if (!response.ok) {
    const data = await response.json().catch(() => ({})) as JsonRecord;
    throw new Error(String(data.message || "The email provider rejected the message."));
  }
}

function expiryText(unixSeconds: number): string {
  return new Intl.DateTimeFormat("en-AU", {
    timeZone: "Australia/Brisbane",
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(unixSeconds * 1000));
}

// The website's own Afterpay fee profile, so the shop and the till charge the
// same fee. Null when Afterpay is switched off there.
async function afterpayFeeFor(amount: number): Promise<number | null> {
  const url = Deno.env.get("SUPABASE_URL") || "";
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const response = await fetch(
    `${url}/rest/v1/payment_fee_profiles?code=eq.afterpay_clearpay&provider=eq.stripe&is_enabled=eq.true&select=fee_type,percentage,fixed_amount`,
    { headers: { apikey: key, Authorization: `Bearer ${key}` } },
  );
  const rows = await response.json().catch(() => []) as JsonRecord[];
  const profile = Array.isArray(rows) ? rows[0] : null;
  if (!response.ok || !profile) return null;
  const percentage = Number(profile.percentage) || 0;
  const fixed = Number(profile.fixed_amount) || 0;
  const fee = profile.fee_type === "fixed"
    ? fixed
    : profile.fee_type === "percentage"
    ? amount * (percentage / 100)
    : profile.fee_type === "combined"
    ? amount * (percentage / 100) + fixed
    : 0;
  return Number(fee.toFixed(2));
}

function paymentButtonHtml(url: string, label: string, primary: boolean): string {
  const colours = primary ? "background:#07896f;color:#ffffff;" : "background:#b2fce4;color:#000000;";
  return `<a href="${escapeHtml(url)}" style="display:block;margin:0 0 12px;padding:14px 20px;border-radius:8px;${colours}font-weight:800;font-size:16px;text-align:center;text-decoration:none;">${label}</a>`;
}

function paymentRequestHtml(
  link: JsonRecord,
  url: string,
  expiresAt: number,
  afterpay: { url: string; fee: number } | null,
): string {
  const profile = storeProfileForOrder({ store_db_code: link.store_code, store_name: link.store_name });
  const invoiceNumber = invoiceNumberText(link);
  const name = String(link.customer_name || "").trim();
  const greeting = name && name.toLowerCase() !== "walk-in customer" ? `Hi ${escapeHtml(name)},` : "Hi,";
  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:#edf3f1;font-family:Arial,Helvetica,sans-serif;color:#14231e;">
  <div style="padding:32px 12px;">
    <div style="max-width:560px;margin:0 auto;overflow:hidden;border-radius:10px;background:#ffffff;box-shadow:0 8px 26px rgba(20,35,30,.08);">
      <div style="padding:28px 30px;background:#07896f;color:#ffffff;">
        <div style="font-size:28px;font-weight:900;">TECHM8</div>
        <div style="margin-top:6px;font-size:15px;font-weight:700;">${escapeHtml(profile.name)}</div>
      </div>
      <div style="padding:30px;">
        <p style="margin:0 0 14px;line-height:1.6;">${greeting}</p>
        <p style="margin:0 0 22px;color:#43564e;line-height:1.6;">Here is your secure payment link for invoice #${escapeHtml(invoiceNumber)}.</p>
        <div style="margin:0 0 24px;padding:18px;border-radius:8px;background:#f5f8f7;text-align:center;">
          <div style="color:#708078;font-size:13px;">Amount due</div>
          <div style="margin-top:4px;font-size:30px;font-weight:900;">${money(link.amount)}</div>
        </div>
        ${paymentButtonHtml(url, `Pay by card ${money(link.amount)}`, true)}
        ${afterpay ? `
        ${paymentButtonHtml(afterpay.url, `Pay with Afterpay ${money(Number(link.amount) + afterpay.fee)}`, false)}
        <p style="margin:0;color:#708078;font-size:12px;line-height:1.5;text-align:center;">Afterpay includes a ${money(afterpay.fee)} processing fee, which is added to your invoice.</p>` : ""}
        <p style="margin:22px 0 0;color:#708078;font-size:13px;line-height:1.6;text-align:center;">Payment is processed securely by Stripe. This link expires ${escapeHtml(expiryText(expiresAt))}.<br>Your tax invoice will be emailed to you once payment is received.</p>
      </div>
      <div style="padding:22px 30px;background:#f5f8f7;color:#687870;font-size:12px;line-height:1.6;text-align:center;">
        <div style="font-weight:800;color:#33473f;">${escapeHtml(profile.name)}</div>
        ${profile.address ? `<div>${escapeHtml(profile.address)}</div>` : ""}
        ${profile.phone ? `<div>${escapeHtml(profile.phone)}</div>` : ""}
        <div>Questions? Just reply to this email.</div>
      </div>
    </div>
  </div>
</body>
</html>`;
}

async function createLink(link: JsonRecord): Promise<JsonRecord> {
  const linkCode = String(link.link_code || "");
  const email = String(link.customer_email || "").trim().toLowerCase();
  const cents = Math.round(Number(link.amount) * 100);
  if (!/^PL-[A-Z0-9]{16}$/.test(linkCode)) throw new Error("Payment link code is invalid.");
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error("Customer email is invalid.");
  if (!Number.isSafeInteger(cents) || cents < 50) throw new Error("Payment link amount is invalid.");

  const stripe = stripeClient();
  // Only one link per invoice may stay payable.
  for (const sessionId of Array.isArray(link.replaced_session_ids) ? link.replaced_session_ids : []) {
    try {
      await stripe.checkout.sessions.expire(String(sessionId));
    } catch (error) {
      console.error("Replaced payment link could not be closed", sessionId, error);
    }
  }

  const siteUrl = String(Deno.env.get("SITE_URL") || "https://www.techm8australia.com").replace(/\/+$/, "");
  const metadata = {
    source: POS_LINK_SOURCE,
    link_code: linkCode,
    order_code: String(link.order_id || ""),
    store_code: String(link.store_code || ""),
    invoice_number: String(link.invoice_number || ""),
  };
  const expiresAt = Math.floor(Date.now() / 1000) + LINK_LIFETIME_SECONDS;
  const session = await stripe.checkout.sessions.create({
    mode: "payment",
    payment_method_types: ["card"],
    customer_email: email,
    line_items: [{
      quantity: 1,
      price_data: {
        currency: "aud",
        unit_amount: cents,
        product_data: { name: `Invoice #${invoiceNumberText(link)} - ${String(link.store_name || "TechM8")}` },
      },
    }],
    metadata,
    payment_intent_data: { metadata, description: `TechM8 POS invoice #${invoiceNumberText(link)}` },
    expires_at: expiresAt,
    success_url: `${siteUrl}/?payment=complete`,
  }, { idempotencyKey: `pos-payment-link-${linkCode}` });

  // A second button for Afterpay, at the invoice amount plus the fee. Stripe
  // refuses amounts outside Afterpay's limits; the customer then gets card only.
  let afterpay: { session: Stripe.Checkout.Session; fee: number } | null = null;
  try {
    const fee = await afterpayFeeFor(Number(link.amount));
    if (fee !== null) {
      const afterpaySession = await stripe.checkout.sessions.create({
        mode: "payment",
        payment_method_types: ["afterpay_clearpay"],
        customer_email: email,
        line_items: [
          {
            quantity: 1,
            price_data: {
              currency: "aud",
              unit_amount: cents,
              product_data: { name: `Invoice #${invoiceNumberText(link)} - ${String(link.store_name || "TechM8")}` },
            },
          },
          ...(fee > 0
            ? [{
              quantity: 1,
              price_data: {
                currency: "aud",
                unit_amount: Math.round(fee * 100),
                product_data: { name: "Afterpay processing fee" },
              },
            }]
            : []),
        ],
        metadata,
        payment_intent_data: { metadata, description: `TechM8 POS invoice #${invoiceNumberText(link)} (Afterpay)` },
        expires_at: expiresAt,
        success_url: `${siteUrl}/?payment=complete`,
      }, { idempotencyKey: `pos-payment-link-${linkCode}-afterpay` });
      afterpay = { session: afterpaySession, fee };
    }
  } catch (error) {
    console.error("Afterpay option could not be added to the payment link", error);
  }

  let emailSent = false;
  let emailError = "";
  try {
    const profile = storeProfileForOrder({ store_db_code: link.store_code, store_name: link.store_name });
    await sendEmail(
      email,
      profile.email,
      `Payment request for invoice #${invoiceNumberText(link)} from ${profile.name}`,
      paymentRequestHtml(
        link,
        String(session.url),
        session.expires_at || expiresAt,
        afterpay ? { url: String(afterpay.session.url), fee: afterpay.fee } : null,
      ),
    );
    emailSent = true;
  } catch (error) {
    console.error("Payment link email failed", error);
    emailError = error instanceof Error ? error.message : "The payment link email could not be sent.";
  }

  return {
    ok: true,
    session_id: session.id,
    url: session.url,
    afterpay_session_id: afterpay ? afterpay.session.id : null,
    afterpay_url: afterpay ? afterpay.session.url : null,
    afterpay_fee: afterpay ? afterpay.fee : null,
    expires_at: new Date((session.expires_at || expiresAt) * 1000).toISOString(),
    email_sent: emailSent,
    email_error: emailError || null,
  };
}

async function posEvent(body: JsonRecord): Promise<JsonRecord> {
  const baseUrl = (Deno.env.get("POS_FUNCTIONS_URL") || "https://abkjbhmifswfexpjkval.supabase.co/functions/v1")
    .replace(/\/+$/, "");
  const response = await fetch(`${baseUrl}/pos-payment-link-events`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-publish-secret": Deno.env.get("USED_DEVICE_PUBLISH_SECRET") || "" },
    body: JSON.stringify(body),
  });
  const data = await response.json().catch(() => ({})) as JsonRecord;
  if (!response.ok || data.ok === false) throw new Error(String(data.message || "The POS did not record the payment."));
  return data;
}

async function stripeEvent(type: string, sessionId: string): Promise<JsonRecord> {
  const stripe = stripeClient();
  const session = await stripe.checkout.sessions.retrieve(sessionId);
  if (session.metadata?.source !== POS_LINK_SOURCE) throw new Error("Not a POS payment link session.");

  if (type === "checkout.session.expired") {
    await posEvent({ action: "expired", stripe_checkout_session_id: session.id });
    return { ok: true, expired: true };
  }
  if (session.payment_status !== "paid") return { ok: true, waiting: session.payment_status };

  const result = await posEvent({
    action: "paid",
    link_code: session.metadata?.link_code,
    stripe_checkout_session_id: session.id,
    stripe_payment_intent_id: typeof session.payment_intent === "string"
      ? session.payment_intent
      : session.payment_intent?.id ?? null,
    amount: (session.amount_total ?? 0) / 100,
  });
  // The customer chose one button; the other must not take a second payment.
  if (result.other_session_id) {
    try {
      const other = await stripe.checkout.sessions.retrieve(String(result.other_session_id));
      if (other.status === "open") await stripe.checkout.sessions.expire(other.id);
    } catch (error) {
      console.error("Unused payment button could not be closed", result.other_session_id, error);
    }
  }
  if (result.already_recorded || !result.applied) return { ok: true, applied: Boolean(result.applied) };

  // The payment is safely recorded; a failed invoice email must not make
  // Stripe retry it. Staff can resend the invoice from the till.
  const link = result.payment_link as JsonRecord;
  const order = result.order as JsonRecord;
  try {
    const profile = storeProfileForOrder(order);
    await sendEmail(
      String(link.customer_email),
      profile.email,
      `Tax Invoice #${invoiceNumberText(order)} from ${order.store_name || "TechM8"}`,
      receiptEmailHtml(order, "Thank you - your online payment has been received."),
    );
  } catch (error) {
    console.error("Online payment invoice email failed", error);
  }
  return { ok: true, applied: true };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return reply({ ok: false, message: "Method not allowed." }, 405);
  try {
    const secret = Deno.env.get("USED_DEVICE_PUBLISH_SECRET") || "";
    if (!secret || !sameSecret(request.headers.get("x-publish-secret") || "", secret)) {
      return reply({ ok: false, message: "Not allowed." }, 401);
    }
    const body = await request.json().catch(() => ({})) as JsonRecord;
    if (body.action === "create" && body.link && typeof body.link === "object") {
      return reply(await createLink(body.link as JsonRecord));
    }
    if (body.action === "stripe-event") {
      return reply(await stripeEvent(String(body.type || ""), String(body.session_id || "")));
    }
    return reply({ ok: false, message: "Unknown action." }, 400);
  } catch (error) {
    console.error(error);
    return reply({ ok: false, message: error instanceof Error ? error.message : "Payment link request failed." }, 500);
  }
});
