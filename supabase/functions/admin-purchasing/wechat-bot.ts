import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { parseChat, validateChatInput } from "./chat-parse.ts";

// Requests from the WeChat helper on a shop PC. It signs in with its own token
// (never an admin session), reports which chats it can see, and sends the new
// messages of watched supplier groups; parcels found there are saved straight
// away and marked wechat_bot so the admin can check them on the page.

type JsonRecord = Record<string, unknown>;
type ChatMessage = { type: "text" | "image" | "other"; text: string };

const ACTOR = "WeChat helper";
const MAX_NEW = 60;
const MAX_CONTEXT = 40;
// Domestic tracking numbers are long digit runs, sometimes behind a courier prefix (SF, YT, JT, JD…).
const TRACKING_HINT = /[A-Za-z]{0,4}\d{9,}/;

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function botTokenValid(admin: SupabaseClient, token: string): Promise<boolean> {
  if (token.length < 24 || token.length > 200) return false;
  const { data, error } = await admin.rpc("purchase_bot_token_valid", { token_hash: await sha256Hex(token) });
  if (error) throw error;
  return data === true;
}

function messages(raw: unknown, limit: number): ChatMessage[] {
  if (!Array.isArray(raw)) return [];
  return raw.slice(-limit).map((entry) => {
    const record = (entry && typeof entry === "object" ? entry : {}) as JsonRecord;
    const type = record.type === "image" ? "image" : record.type === "text" ? "text" : "other";
    return { type, text: String(record.text || "").slice(0, 2000) } as ChatMessage;
  });
}

function asLines(list: ChatMessage[]): string {
  return list.map((message) => message.type === "image" ? "[图片]" : message.text).filter(Boolean).join("\n");
}

function matchForwarder(forwarders: { id: number; name: string }[], name: string | null): number | null {
  const wanted = String(name || "").trim().toLowerCase();
  if (!wanted) return null;
  const found = forwarders.find((forwarder) => forwarder.name.trim().toLowerCase() === wanted)
    || forwarders.find((forwarder) => {
      const known = forwarder.name.trim().toLowerCase();
      return known && (known.includes(wanted) || wanted.includes(known));
    });
  return found ? found.id : null;
}

async function logEvent(admin: SupabaseClient, event: JsonRecord) {
  const { error } = await admin.rpc("purchase_bot_log_event", { payload: event });
  if (error) console.error("bot event log failed", error);
}

async function heartbeat(admin: SupabaseClient, payload: JsonRecord) {
  const { data, error } = await admin.rpc("purchase_bot_heartbeat", { payload });
  if (error) throw error;
  return data;
}

async function ingest(admin: SupabaseClient, payload: JsonRecord) {
  const group = String(payload.group || "").trim().slice(0, 120);
  if (!group) throw new Error("A group name is required.");
  const fresh = messages(payload.new_messages, MAX_NEW);
  const context = messages(payload.context, MAX_CONTEXT);
  const images = Array.isArray(payload.images) && payload.images.length
    ? validateChatInput("images", payload.images).images
    : [];

  const { data: target, error: targetError } = await admin.rpc("purchase_bot_group_target", { group_name: group });
  if (targetError) throw targetError;
  const supplierId = target?.supplier_id ?? null;
  const base = { group_name: group, supplier_id: supplierId, messages: fresh };

  if (!target?.watch) {
    await logEvent(admin, { ...base, status: "not_watched" });
    return { status: "not_watched" };
  }
  const freshText = asLines(fresh);
  if (!TRACKING_HINT.test(freshText) && !images.length) {
    return { status: "nothing_new" };
  }

  try {
    const apiKey = Deno.env.get("ANTHROPIC_API_KEY") || "";
    if (!apiKey) throw new Error("AI chat reading is not set up yet: add ANTHROPIC_API_KEY to the Edge Function secrets.");
    const { data: forwarders, error: forwarderError } = await admin
      .from("purchase_forwarders").select("id, name, warehouse_address").eq("is_active", true);
    if (forwarderError) throw forwarderError;

    const text = [
      `（这是微信群「${group}」里的消息，看不到每条是谁发的。【之前的消息】只作参考；只把【新消息】里出现的快递单号登记为包裹，包裹内容和产品明细可以参考之前的消息。截图都属于新消息。）`,
      context.length ? `【之前的消息】\n${asLines(context)}` : "",
      `【新消息】\n${freshText || "（只有截图）"}`,
    ].filter(Boolean).join("\n\n");
    const extraction = await parseChat({
      apiKey,
      text,
      images,
      suppliers: target.supplier_name ? [String(target.supplier_name)] : [],
      forwarders: (forwarders || []).map((row) => ({
        name: String(row.name),
        warehouse_address: row.warehouse_address ? String(row.warehouse_address) : null,
      })),
    });

    if (!extraction.parcels.length) {
      await logEvent(admin, { ...base, status: "nothing_new", result: { warnings: extraction.warnings } });
      return { status: "nothing_new", warnings: extraction.warnings };
    }

    const orderId = target.order_id ?? null;
    const items = orderId ? [] : extraction.items.filter((item) => item.description && item.quantity > 0);
    const forwarderId = matchForwarder(
      (forwarders || []).map((row) => ({ id: Number(row.id), name: String(row.name) })),
      extraction.forwarder_name,
    );
    const { data: saved, error: saveError } = await admin.rpc("purchase_admin_import_chat", {
      actor: ACTOR,
      payload: {
        source: "wechat_bot",
        order_id: orderId,
        supplier_id: supplierId,
        forwarder_id: forwarderId,
        currency: extraction.currency,
        goods_amount: items.length ? extraction.goods_amount : null,
        domestic_shipping_amount: items.length ? extraction.domestic_shipping_amount : null,
        notes: items.length ? extraction.notes : null,
        items,
        parcels: extraction.parcels.map((parcel) => ({
          tracking_no: parcel.tracking_no,
          courier: parcel.courier,
          contents: parcel.contents,
          carton_count: parcel.carton_count,
          weight_kg: parcel.estimated_weight_kg,
          has_battery: parcel.has_battery,
          has_magnet: parcel.has_magnet,
        })),
      },
    });
    if (saveError) throw saveError;

    const result = {
      po_number: saved?.po_number ?? null,
      order_id: saved?.order_id ?? null,
      parcel_ids: saved?.parcel_ids ?? [],
      skipped: saved?.skipped ?? [],
      tracking_numbers: extraction.parcels.map((parcel) => parcel.tracking_no),
      warnings: extraction.warnings,
    };
    await logEvent(admin, { ...base, status: "saved", result });
    return { status: "saved", ...result };
  } catch (error) {
    const message = error instanceof Error ? error.message : String((error as JsonRecord)?.message || error);
    await logEvent(admin, { ...base, status: "error", error: message });
    throw error;
  }
}

export async function handleBotAction(admin: SupabaseClient, action: string, payload: JsonRecord) {
  if (action === "bot_heartbeat") return await heartbeat(admin, payload);
  if (action === "bot_ingest") return await ingest(admin, payload);
  throw new Error("Unknown helper action.");
}
