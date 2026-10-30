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

// The website project holds the Stripe keys and the mailer, so it opens the
// Checkout session and emails the customer; this project only keeps the record.
// What the customer is paying for, so the email can say so.
function paymentLinkOrderSummary(order: JsonRecord | null): JsonRecord | null {
  if (!order) return null;
  const items = Array.isArray(order.items) ? order.items as JsonRecord[] : [];
  return {
    total: order.total,
    amount_paid: order.amount_paid,
    balance_due: order.balance_due,
    items: items.map((item) => ({
      name: item.name,
      qty: item.qty,
      line_total: item.line_total,
      line_type: item.line_type,
      repair_device: item.repair_device,
    })),
  };
}

async function sendPaymentLink(link: JsonRecord, order: JsonRecord | null): Promise<JsonRecord> {
  const websiteUrl = (Deno.env.get("WEBSITE_FUNCTIONS_URL") || "https://fwlronvmgqzkleofriis.supabase.co/functions/v1")
    .replace(/\/+$/, "");
  const secret = Deno.env.get("USED_DEVICE_PUBLISH_SECRET") || "";
  let answer: JsonRecord = {};
  try {
    if (!secret) throw new Error("Online payments are not configured.");
    const response = await fetch(`${websiteUrl}/pos-payment-link`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-publish-secret": secret },
      body: JSON.stringify({ action: "create", link, order: paymentLinkOrderSummary(order) }),
    });
    answer = await response.json().catch(() => ({})) as JsonRecord;
    if (!response.ok || answer.ok === false) {
      throw new Error(String(answer.message || "The payment link could not be created."));
    }
  } catch (error) {
    console.error("Payment link send failed", error);
    answer = { send_error: error instanceof Error ? error.message : "The payment link could not be created." };
  }
  const attached = await callRpc("attach_pos_payment_link", {
    payload: {
      link_code: link.link_code,
      stripe_checkout_session_id: answer.session_id || null,
      checkout_url: answer.url || null,
      afterpay_session_id: answer.afterpay_session_id || null,
      afterpay_checkout_url: answer.afterpay_url || null,
      afterpay_fee: answer.afterpay_fee ?? null,
      expires_at: answer.expires_at || null,
      email_sent: answer.email_sent === true,
      send_error: answer.send_error || answer.email_error || null,
    },
  });
  if (attached.status >= 400 || !attached.body.ok) {
    console.error("Payment link record update failed", attached.body);
    return { ...link, status: answer.session_id ? "sent" : "failed", send_error: answer.send_error || null };
  }
  return attached.body.payment_link as JsonRecord;
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

      if (url.searchParams.get("mode") === "warranty-claim") {
        const result = await callRpc("claim_pos_warranty_for_store", {
          session_token: sessionToken,
          target_store_code: storeCode,
          target_order_code: String(record.order_id || ""),
          target_line_id: record.line_id,
          request_id: record.request_id,
        });
        return jsonResponse(result.body, result.status);
      }

      if ((url.searchParams.get("mode") || "") === "google-review") {
        const staffName = String(record.staff_name || "");
        const eventCode = String(record.event_code || "");
        const customerName = String(record.customer_name || "").trim();
        if (!storeCode || !staffName || !eventCode) {
          return jsonResponse({ ok: false, message: "store_code, staff_name, and event_code are required." }, 400);
        }
        if (!customerName) {
          return jsonResponse({ ok: false, message: "Customer name is required for a Google review." }, 400);
        }
        if (customerName.length > 120) {
          return jsonResponse({ ok: false, message: "Customer name cannot exceed 120 characters." }, 400);
        }
        const actor = await authorizedActor(sessionToken, storeCode, staffName);
        const result = await callRpc("record_pos_google_review", {
          session_token: sessionToken,
          target_store_code: storeCode,
          target_staff_name: String(actor.staff_name || ""),
          event_code: eventCode,
          customer_name: customerName,
        });
        return jsonResponse(result.body, result.status);
      }

      await requireStoreAccess(sessionToken, storeCode);

      // A staff member at the store has seen the "customer paid online" notice.
      if ((url.searchParams.get("mode") || "") === "payment-link-acknowledge") {
        const result = await callRpc("acknowledge_pos_payment_link_for_store", {
          session_token: sessionToken,
          target_store_code: storeCode,
          target_link_code: String(record.link_code || ""),
          target_staff_name: String(record.staff_name || ""),
        });
        return jsonResponse(result.body, result.status);
      }

      // A new payment link for an invoice that already exists (balance owing,
      // or the first link expired or never arrived).
      if ((url.searchParams.get("mode") || "") === "payment-link") {
        const result = await callRpc("create_pos_payment_link_for_store", {
          session_token: sessionToken,
          payload: record,
        });
        if (result.status >= 400 || !result.body.ok) return jsonResponse(result.body, result.status);
        const link = await sendPaymentLink(
          result.body.payment_link as JsonRecord,
          (result.body.order as JsonRecord | undefined) || null,
        );
        return jsonResponse({ ...result.body, payment_link: link });
      }

      // Checkout finished by emailing the customer a payment link: the sale is
      // saved owing the link amount, then the link is sent.
      if (record.payment_link && typeof record.payment_link === "object" && !Array.isArray(record.payment_link)) {
        if (String(record.order_note || "").length > 1000) {
          return jsonResponse({ ok: false, message: "Order note cannot exceed 1000 characters." }, 400);
        }
        const linkItems = Array.isArray(record.items) ? record.items as JsonRecord[] : [];
        if (linkItems.some((item) => String(item?.note || "").length > 500)) {
          return jsonResponse({ ok: false, message: "Item note cannot exceed 500 characters." }, 400);
        }
        const saved = await callRpc("save_pos_sales_order_with_payment_link_for_store", {
          session_token: sessionToken,
          payload: record,
        });
        if (saved.status >= 400 || !saved.body.ok) return jsonResponse(saved.body, saved.status);
        const order = (saved.body.order && typeof saved.body.order === "object")
          ? saved.body.order as JsonRecord
          : {};
        const inventory = await syncSavedOrder(sessionToken, storeCode, order);
        const link = saved.body.payment_link && typeof saved.body.payment_link === "object"
          ? await sendPaymentLink(saved.body.payment_link as JsonRecord, order)
          : null;
        return jsonResponse({
          ...saved.body,
          payment_link: link,
          inventory,
          inventory_sync_pending: !inventory.ok,
        });
      }

      // An earlier invoice's balance checked out together with new cart items:
      // one payment, the balance on the old invoice, the items on a new one.
      if ((url.searchParams.get("mode") || "") === "balance-checkout") {
        if (!Array.isArray(record.balances) || record.balances.length === 0) {
          return jsonResponse({ ok: false, message: "At least one invoice balance is required." }, 400);
        }
        const sale = record.order && typeof record.order === "object" && !Array.isArray(record.order)
          ? record.order as JsonRecord
          : null;
        if (sale?.exchange_refund) {
          return jsonResponse({ ok: false, message: "An exchange cannot be checked out with an invoice balance." }, 400);
        }
        if (String(sale?.order_note || "").length > 1000) {
          return jsonResponse({ ok: false, message: "Order note cannot exceed 1000 characters." }, 400);
        }
        const saleItems = sale && Array.isArray(sale.items) ? sale.items as JsonRecord[] : [];
        if (saleItems.some((item) => String(item?.note || "").length > 500)) {
          return jsonResponse({ ok: false, message: "Item note cannot exceed 500 characters." }, 400);
        }
        const result = await callRpc("checkout_pos_cart_with_balances_for_store", {
          session_token: sessionToken,
          payload: record,
        });
        if (result.status >= 400 || !result.body.ok) return jsonResponse(result.body, result.status);
        const order = result.body.order && typeof result.body.order === "object"
          ? result.body.order as JsonRecord
          : null;
        const inventory = order ? await syncSavedOrder(sessionToken, storeCode, order) : { ok: true };
        const balanceInventory: JsonRecord[] = [];
        for (const paid of Array.isArray(result.body.balance_orders) ? result.body.balance_orders as JsonRecord[] : []) {
          balanceInventory.push(await syncSavedOrder(sessionToken, storeCode, paid));
        }
        return jsonResponse({
          ...result.body,
          inventory,
          balance_inventory: balanceInventory,
          inventory_sync_pending: !inventory.ok || balanceInventory.some((entry) => !entry.ok),
        });
      }

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
          const existingOrder = existing.body.order as JsonRecord;
          const inventory = await syncSavedOrder(sessionToken, storeCode, existingOrder);
          const exchangeSource = existingOrder.exchange_source as JsonRecord | undefined;
          let exchangeInventory: JsonRecord | null = null;
          if (exchangeSource?.order_id) {
            const original = await callRpc("get_pos_sales_order_for_store", {
              session_token: sessionToken,
              target_store_code: storeCode,
              target_order_code: String(exchangeSource.order_id),
            });
            if (original.status < 400 && original.body.ok && original.body.order) {
              exchangeInventory = await syncSavedOrder(
                sessionToken,
                storeCode,
                original.body.order as JsonRecord,
              );
            }
          }
          return jsonResponse({
            ...existing.body,
            inventory,
            exchange_inventory: exchangeInventory,
            inventory_sync_pending: !inventory.ok || Boolean(exchangeInventory && !exchangeInventory.ok),
          });
        }
      }

      const isExchange = record.exchange_refund && typeof record.exchange_refund === "object"
        && !Array.isArray(record.exchange_refund);
      const saved = await callRpc(isExchange
        ? "save_pos_exchange_order_for_store"
        : "save_pos_sales_order_for_store", {
        session_token: sessionToken,
        payload: record,
      });
      if (saved.status >= 400 || !saved.body.ok) return jsonResponse(saved.body, saved.status);
      const order = (saved.body.order && typeof saved.body.order === "object")
        ? saved.body.order as JsonRecord
        : {};
      const inventory = await syncSavedOrder(sessionToken, storeCode, order);
      const exchangeOrder = (saved.body.exchange_order && typeof saved.body.exchange_order === "object")
        ? saved.body.exchange_order as JsonRecord
        : null;
      const exchangeInventory = exchangeOrder
        ? await syncSavedOrder(sessionToken, storeCode, exchangeOrder)
        : null;
      return jsonResponse({
        ...saved.body,
        inventory,
        exchange_inventory: exchangeInventory,
        inventory_sync_pending: !inventory.ok || Boolean(exchangeInventory && !exchangeInventory.ok),
      }, saved.status);
    }

    if (request.method === "PUT") {
      const payload = await request.json().catch(() => null);
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        return jsonResponse({ ok: false, message: "Refund payload must be an object." }, 400);
      }
      const record = payload as JsonRecord;
      const storeCode = String(record.store_code || "").trim().toLowerCase();
      const isCorrection = (url.searchParams.get("mode") || "") === "correct-payment-method";
      if (!record.order_id || !storeCode || !record.staff_name || (!record.shift_id && !isCorrection)) {
        return jsonResponse({ ok: false, message: "order_id, store_code, staff_name, and shift_id are required." }, 400);
      }
      await requireStoreAccess(sessionToken, storeCode);

      // Relabelling how a sale was paid moves no money, so it needs neither a
      // shift nor a payment list - only the line and a reason.
      if ((url.searchParams.get("mode") || "") === "correct-payment-method") {
        const result = await callRpc("correct_pos_payment_method", {
          session_token: sessionToken,
          payload: record,
        });
        return jsonResponse(result.body, result.status);
      }

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

      if (mode === "store-credit-balance") {
        const result = await callRpc("get_pos_store_credit_balance", {
          session_token: sessionToken,
          target_store_code: storeCode,
          target_customer_code: url.searchParams.get("customer_code") || "",
        });
        return jsonResponse(result.body, result.status);
      }

      if (mode === "payment-links") {
        const result = await callRpc("list_pos_payment_links_for_store", {
          session_token: sessionToken,
          target_store_code: storeCode,
          target_order_code: url.searchParams.get("order_id") || null,
          changed_since: url.searchParams.get("since") || null,
          unacknowledged_only: url.searchParams.get("unacknowledged") === "1",
        });
        return jsonResponse(result.body, result.status);
      }

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

      if (mode === "performance") {
        const result = await callRpc("get_pos_performance_report", {
          session_token: sessionToken,
          target_store_code: storeCode,
          date_from: url.searchParams.get("from_date") || null,
          date_to: url.searchParams.get("to_date") || null,
          order_limit: Math.min(Math.max(Number(url.searchParams.get("order_limit") || 300), 1), 1000),
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
