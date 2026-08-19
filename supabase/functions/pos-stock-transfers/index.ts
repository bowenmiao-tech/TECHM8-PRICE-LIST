import { createClient } from "npm:@supabase/supabase-js@2";

const BUCKET_NAME = "stock-transfer-receipts";
const MAX_PHOTO_BYTES = 5 * 1024 * 1024;
const ALLOWED_PHOTO_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session, x-pos-store, x-pos-shift",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
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

function errorMessage(error: unknown, fallback: string): string {
  if (error && typeof error === "object" && "message" in error) {
    const message = String((error as { message?: unknown }).message || "").trim();
    if (message) return message;
  }
  return fallback;
}

function errorStatus(message: string): number {
  if (/not found/i.test(message)) return 404;
  if (/only the|current store|current open shift|not allowed|does not have/i.test(message)) return 403;
  if (/already used|not available|no stock|insufficient|exceeds|different operation/i.test(message)) return 409;
  if (/required|invalid|must|between|contain|belong/i.test(message)) return 400;
  return 500;
}

async function callStaffRpc(
  rpcName: string,
  payload: JsonRecord,
  request: Request,
): Promise<JsonRecord> {
  const supabaseUrl = Deno.env.get("STAFF_AUTH_SUPABASE_URL") || "";
  const incomingApiKey = request.headers.get("apikey") || "";
  const incomingAuthorization = request.headers.get("authorization") || "";
  const anonKey = incomingApiKey || Deno.env.get("STAFF_AUTH_SUPABASE_ANON_KEY") || "";
  const authorization = incomingAuthorization || `Bearer ${anonKey}`;

  if (!supabaseUrl || !anonKey) {
    throw new Error("Staff authorization is not configured.");
  }

  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${rpcName}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: anonKey,
      Authorization: authorization,
    },
    body: JSON.stringify(payload),
  });

  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(String((result as JsonRecord)?.message || "Staff authorization request failed."));
  }
  if (Array.isArray(result)) return (result[0] as JsonRecord | undefined) || {};
  return (result as JsonRecord | null) || {};
}

async function getStaffContext(
  sessionToken: string,
  staffName: string,
  request: Request,
): Promise<JsonRecord> {
  if (!sessionToken) throw new Error("Staff session is required.");
  if (!staffName.trim()) throw new Error("Staff name is required.");
  const context = await callStaffRpc("get_staff_transfer_context", {
    session_token: sessionToken,
    target_staff_name: staffName.trim(),
    target_store_code: String(request.headers.get("x-pos-store") || "").trim(),
    target_shift_code: String(request.headers.get("x-pos-shift") || "").trim(),
  }, request);
  if (!context.ok) throw new Error(String(context.message || "Active staff member not found."));
  return context;
}

function productAdminClient() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!supabaseUrl || !serviceRoleKey) throw new Error("Product database is not configured.");
  return createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
}

async function addSignedPhotoUrls(admin: ReturnType<typeof productAdminClient>, payload: unknown) {
  if (!payload || typeof payload !== "object") return payload;
  const transfer = payload as JsonRecord;
  const photos = Array.isArray(transfer.photos) ? transfer.photos as JsonRecord[] : [];
  const paths = photos.map((photo) => String(photo.storage_path || "")).filter(Boolean);
  if (!paths.length) return transfer;

  const { data, error } = await admin.storage.from(BUCKET_NAME).createSignedUrls(paths, 60 * 10);
  if (error) throw error;
  const signedByPath = new Map((data || []).map((entry) => [entry.path, entry.signedUrl]));
  transfer.photos = photos.map((photo) => ({
    ...photo,
    signed_url: signedByPath.get(String(photo.storage_path || "")) || null,
  }));
  return transfer;
}

async function uploadPhoto(
  request: Request,
  form: FormData,
  actorName: string,
  actorStoreSlug: string,
): Promise<Response> {
  const transferId = Number(form.get("transfer_id"));
  const receiptKey = String(form.get("receipt_key") || "").trim();
  const category = String(form.get("category") || "receipt").trim();
  const photo = form.get("photo");

  if (!Number.isInteger(transferId) || transferId < 1 || !receiptKey || !(photo instanceof File)) {
    return jsonResponse({ ok: false, message: "Transfer, receipt key and photo are required." }, 400);
  }
  if (!ALLOWED_PHOTO_TYPES.has(photo.type) || photo.size < 1 || photo.size > MAX_PHOTO_BYTES) {
    return jsonResponse({ ok: false, message: "Photo must be JPEG, PNG or WebP and no larger than 5 MB." }, 400);
  }
  if (!["receipt", "issue", "return"].includes(category)) {
    return jsonResponse({ ok: false, message: "Photo category is invalid." }, 400);
  }

  const admin = productAdminClient();
  const scopedTransfer = await getScopedTransfer(admin, transferId, actorStoreSlug);
  requireStoreRole(
    scopedTransfer,
    category === "return" ? "source" : "destination",
    category === "return" ? "upload return photos" : "upload receipt photos",
  );

  const extension = photo.type === "image/png" ? "png" : photo.type === "image/webp" ? "webp" : "jpg";
  const storagePath = `${transferId}/${receiptKey}/${crypto.randomUUID()}.${extension}`;
  const bytes = new Uint8Array(await photo.arrayBuffer());
  const { error: uploadError } = await admin.storage.from(BUCKET_NAME).upload(storagePath, bytes, {
    cacheControl: "3600",
    contentType: photo.type,
    upsert: false,
  });
  if (uploadError) throw uploadError;

  const { data, error } = await admin.rpc("register_pos_stock_transfer_photo", {
    target_transfer_id: transferId,
    target_receipt_key: receiptKey,
    target_category: category,
    target_storage_path: storagePath,
    target_mime_type: photo.type,
    target_file_size: photo.size,
    target_actor_staff_name: actorName,
  });
  if (error) {
    await admin.storage.from(BUCKET_NAME).remove([storagePath]);
    throw error;
  }

  const { data: signed, error: signedError } = await admin.storage
    .from(BUCKET_NAME)
    .createSignedUrl(storagePath, 60 * 10);
  if (signedError) throw signedError;
  return jsonResponse({ ok: true, photo: { ...(data as JsonRecord), signed_url: signed.signedUrl } });
}

async function getScopedTransfer(
  admin: ReturnType<typeof productAdminClient>,
  transferId: number,
  actorStoreSlug: string,
): Promise<JsonRecord> {
  const { data, error } = await admin.rpc("pos_stock_transfer_payload_for_store", {
    target_transfer_id: transferId,
    target_store_slug: actorStoreSlug,
  });
  if (error) throw error;
  if (!data) throw new Error("Transfer not found for the current store.");
  return data as JsonRecord;
}

function requireStoreRole(transfer: JsonRecord, role: "source" | "destination", action: string) {
  if (String(transfer.current_store_role || "") !== role) {
    const storeLabel = role === "destination" ? "destination" : "source";
    throw new Error(`Only the ${storeLabel} store can ${action}.`);
  }
}

function addCurrentStoreRole(payload: unknown, actorStoreSlug: string) {
  if (!payload || typeof payload !== "object") return payload;
  const transfer = payload as JsonRecord;
  const source = transfer.source_store as JsonRecord | undefined;
  const destination = transfer.destination_store as JsonRecord | undefined;
  return {
    ...transfer,
    current_store_role: String(source?.slug || "") === actorStoreSlug
      ? "source"
      : String(destination?.slug || "") === actorStoreSlug
      ? "destination"
      : null,
  };
}

async function deletePendingPhoto(
  admin: ReturnType<typeof productAdminClient>,
  body: JsonRecord,
  actorStoreSlug: string,
) {
  const photoId = String(body.photo_id || "").trim();
  const receiptKey = String(body.receipt_key || "").trim();
  const transferId = Number(body.transfer_id);
  if (!photoId || !receiptKey || !Number.isInteger(transferId) || transferId < 1) {
    throw new Error("Photo, transfer and receipt key are required.");
  }

  const { data: photo, error: readError } = await admin
    .from("stock_transfer_photos")
    .select("id, storage_path, receipt_id, category")
    .eq("id", photoId)
    .eq("transfer_id", transferId)
    .eq("receipt_key", receiptKey)
    .maybeSingle();
  if (readError) throw readError;
  if (!photo) return { ok: true, deleted: false };
  if (photo.receipt_id) throw new Error("Submitted receipt photos cannot be deleted.");

  const scopedTransfer = await getScopedTransfer(admin, transferId, actorStoreSlug);
  requireStoreRole(
    scopedTransfer,
    photo.category === "return" ? "source" : "destination",
    photo.category === "return" ? "delete return photos" : "delete receipt photos",
  );

  const { error: storageError } = await admin.storage.from(BUCKET_NAME).remove([photo.storage_path]);
  if (storageError) throw storageError;
  const { error: deleteError } = await admin.from("stock_transfer_photos").delete().eq("id", photo.id);
  if (deleteError) throw deleteError;
  return { ok: true, deleted: true };
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (request.method !== "GET" && request.method !== "POST") {
    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  }

  const sessionToken = request.headers.get("x-staff-session") || "";
  const url = new URL(request.url);
  let body: JsonRecord = {};
  let form: FormData | null = null;
  let staffName = "";

  try {
    if (request.method === "POST" && request.headers.get("content-type")?.includes("multipart/form-data")) {
      form = await request.formData();
      staffName = String(form.get("staff_name") || "").trim();
    } else if (request.method === "POST") {
      body = await request.json().catch(() => ({})) as JsonRecord;
      staffName = String(body.staff_name || "").trim();
    } else {
      staffName = String(url.searchParams.get("staff_name") || "").trim();
    }

    const staff = await getStaffContext(sessionToken, staffName, request);
    const actorName = String(staff.display_name || staffName);
    const actorStoreSlug = String(staff.current_store_slug || "").trim();
    if (!actorStoreSlug) throw new Error("Current store is required.");

    if (form) return await uploadPhoto(request, form, actorName, actorStoreSlug);

    const admin = productAdminClient();
    if (request.method === "GET") {
      const mode = url.searchParams.get("mode") || "list";
      if (mode === "context") {
        const { data, error } = await admin.rpc("list_pos_transfer_stores");
        if (error) throw error;
        return jsonResponse({ ok: true, staff, stores: data || [] });
      }
      if (mode === "detail") {
        const transferId = Number(url.searchParams.get("id"));
        if (!Number.isInteger(transferId) || transferId < 1) {
          return jsonResponse({ ok: false, message: "A valid transfer ID is required." }, 400);
        }
        const data = await getScopedTransfer(admin, transferId, actorStoreSlug);
        return jsonResponse({ ok: true, transfer: await addSignedPhotoUrls(admin, data) });
      }
      if (mode !== "list") return jsonResponse({ ok: false, message: "Unknown request mode." }, 400);

      const { data, error } = await admin.rpc("list_pos_stock_transfers", {
        target_status: url.searchParams.get("status") || "all",
        target_store_slug: actorStoreSlug,
        target_search_query: url.searchParams.get("search") || "",
        target_limit: Number(url.searchParams.get("limit") || 100),
      });
      if (error) throw error;
      return jsonResponse({ ok: true, transfers: data || [] });
    }

    const action = String(body.action || "").trim();
    if (action === "dispatch") {
      const { data, error } = await admin.rpc("create_pos_stock_transfer", {
        target_source_store_slug: String(body.source_store_slug || ""),
        target_destination_store_slug: String(body.destination_store_slug || ""),
        target_items: Array.isArray(body.items) ? body.items : [],
        target_actor_staff_name: actorName,
        target_dispatch_note: String(body.note || ""),
        target_client_request_key: String(body.request_key || ""),
      });
      if (error) throw error;
      return jsonResponse({ ok: true, transfer: addCurrentStoreRole(data, actorStoreSlug) as JsonRecord });
    }
    if (action === "receive") {
      const transferId = Number(body.transfer_id);
      const scopedTransfer = await getScopedTransfer(admin, transferId, actorStoreSlug);
      requireStoreRole(scopedTransfer, "destination", "receive this transfer");
      const { data, error } = await admin.rpc("receive_pos_stock_transfer", {
        target_transfer_id: transferId,
        target_receipt_key: String(body.receipt_key || ""),
        target_lines: Array.isArray(body.lines) ? body.lines : [],
        target_finalize: Boolean(body.finalize),
        target_actor_staff_name: actorName,
        target_note: String(body.note || ""),
      });
      if (error) throw error;
      return jsonResponse({ ok: true, transfer: await addSignedPhotoUrls(admin, addCurrentStoreRole(data, actorStoreSlug)) });
    }
    if (action === "return") {
      const transferId = Number(body.transfer_id);
      const scopedTransfer = await getScopedTransfer(admin, transferId, actorStoreSlug);
      requireStoreRole(scopedTransfer, "source", "return the remaining stock");
      const { data, error } = await admin.rpc("return_pos_stock_transfer", {
        target_transfer_id: transferId,
        target_receipt_key: String(body.receipt_key || ""),
        target_actor_staff_name: actorName,
        target_reason: String(body.reason || ""),
      });
      if (error) throw error;
      return jsonResponse({ ok: true, transfer: await addSignedPhotoUrls(admin, addCurrentStoreRole(data, actorStoreSlug)) });
    }
    if (action === "delete-photo") {
      return jsonResponse(await deletePendingPhoto(admin, body, actorStoreSlug));
    }
    return jsonResponse({ ok: false, message: "Unknown transfer action." }, 400);
  } catch (error) {
    const message = errorMessage(error, "Stock transfer request failed.");
    console.error(message, error);
    const status = /session|staff member|authorization/i.test(message) ? 401 : errorStatus(message);
    return jsonResponse({ ok: false, message }, status);
  }
});
