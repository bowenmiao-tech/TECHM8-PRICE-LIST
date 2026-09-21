import { PDFDocument, PDFFont, PDFPage, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

type JsonRecord = Record<string, unknown>;

const DOCUMENT_BUCKET = "used-device-documents";
const ID_PHOTO_BUCKET = "used-device-id-photos";
const SIGNATURE_MAX_BYTES = 2 * 1024 * 1024;
const SIGNED_URL_SECONDS = 300;

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

function supabaseConfig(): { url: string; serviceKey: string } {
  const url = Deno.env.get("STAFF_AUTH_SUPABASE_URL") || Deno.env.get("SUPABASE_URL") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!url || !serviceKey) throw new Error("Supabase environment is not configured.");
  return { url, serviceKey };
}

async function rpcJson(rpcName: string, payload: JsonRecord): Promise<{ status: number; body: JsonRecord }> {
  const config = supabaseConfig();
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
  return {
    status: response.status,
    body: Array.isArray(result) ? ((result[0] as JsonRecord | undefined) || {}) : ((result as JsonRecord | null) || {}),
  };
}

async function rpcResponse(_request: Request, rpcName: string, payload: JsonRecord): Promise<Response> {
  const result = await rpcJson(rpcName, payload);
  return new Response(JSON.stringify(result.body), {
    status: result.status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function safeSegment(value: unknown): string {
  return String(value || "").replace(/[^A-Za-z0-9._-]/g, "-").replace(/-+/g, "-").slice(0, 80);
}

function decodeSignature(dataUrl: string): { bytes: Uint8Array; contentType: string; extension: string } {
  const match = /^data:(image\/(?:png|jpeg));base64,([A-Za-z0-9+/=\s]+)$/.exec(dataUrl || "");
  if (!match) throw new Error("The seller signature must be a PNG or JPEG image.");
  const binary = atob(match[2].replace(/\s+/g, ""));
  if (!binary.length || binary.length > SIGNATURE_MAX_BYTES) throw new Error("The seller signature image is too large.");
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  const isPng = bytes.length > 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  const isJpeg = bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if ((!isPng && match[1] === "image/png") || (!isJpeg && match[1] === "image/jpeg")) {
    throw new Error("The seller signature image is invalid.");
  }
  return {
    bytes,
    contentType: match[1],
    extension: match[1] === "image/png" ? "png" : "jpg",
  };
}

async function uploadPrivateObject(path: string, bytes: Uint8Array, contentType: string): Promise<void> {
  const config = supabaseConfig();
  const response = await fetch(`${config.url}/storage/v1/object/${DOCUMENT_BUCKET}/${path}`, {
    method: "POST",
    headers: {
      apikey: config.serviceKey,
      Authorization: `Bearer ${config.serviceKey}`,
      "Content-Type": contentType,
      "x-upsert": "false",
    },
    body: bytes,
  });
  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(`The signed buyback file could not be stored. ${detail}`.trim());
  }
}

async function deletePrivateObject(path: string): Promise<void> {
  if (!path) return;
  try {
    const config = supabaseConfig();
    await fetch(`${config.url}/storage/v1/object/${DOCUMENT_BUCKET}/${path}`, {
      method: "DELETE",
      headers: { apikey: config.serviceKey, Authorization: `Bearer ${config.serviceKey}` },
    });
  } catch (error) {
    console.error("buyback document cleanup failed", path, error);
  }
}

async function storageSignedUrl(bucket: string, path: string): Promise<string | null> {
  if (!path) return null;
  const config = supabaseConfig();
  const response = await fetch(`${config.url}/storage/v1/object/sign/${bucket}/${path}`, {
    method: "POST",
    headers: {
      apikey: config.serviceKey,
      Authorization: `Bearer ${config.serviceKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ expiresIn: SIGNED_URL_SECONDS }),
  });
  if (!response.ok) return null;
  const result = await response.json().catch(() => ({})) as JsonRecord;
  const signed = String(result.signedURL || result.signedUrl || "");
  return signed ? `${config.url}/storage/v1${signed.startsWith("/") ? "" : "/"}${signed}` : null;
}

function textValue(value: unknown): string {
  return String(value ?? "").trim();
}

function moneyValue(value: unknown): string {
  const amount = Number(value);
  return `$${(Number.isFinite(amount) ? amount : 0).toFixed(2)}`;
}

function titleValue(value: unknown): string {
  return textValue(value).replace(/_/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function buybackSnapshot(data: JsonRecord, actor: JsonRecord, signedSellerName: string, signedAt: string): JsonRecord {
  const inspection = data.inspection && typeof data.inspection === "object" && !Array.isArray(data.inspection)
    ? data.inspection as JsonRecord : {};
  return {
    captured_at: signedAt,
    store_code: textValue(actor.store_code || data.store_code),
    store_name: textValue(actor.store_name || data.store_name || actor.store_code || data.store_code),
    staff_name: textValue(actor.staff_name || data.staff_name),
    signed_seller_name: signedSellerName,
    seller: {
      name: textValue(data.seller_name),
      phone: textValue(data.seller_phone),
      email: textValue(data.seller_email),
      address: textValue(data.seller_address),
      id_type: textValue(data.seller_id_type),
      id_reference: textValue(data.seller_id_reference),
      is_owner: data.seller_is_owner === true || textValue(data.seller_is_owner).toLowerCase() === "true",
      owner_name: textValue(data.owner_name),
      owner_address: textValue(data.owner_address),
      acquisition_statement: textValue(data.acquisition_statement),
    },
    device: {
      category: textValue(data.category),
      brand: textValue(data.brand),
      model: textValue(data.model),
      variant: textValue(data.variant),
      storage: textValue(data.storage),
      color: textValue(data.color),
      imei: textValue(data.imei),
      serial_number: textValue(data.serial_number),
      battery_health: textValue(data.battery_health),
      condition_grade: textValue(data.condition_grade),
      notes: textValue(data.notes),
      inspection,
      clean_check_status: textValue(data.clean_check_status),
      activation_lock_removed: data.activation_lock_removed === true || textValue(data.activation_lock_removed).toLowerCase() === "true",
      data_erased_confirmed: data.data_erased_confirmed === true || textValue(data.data_erased_confirmed).toLowerCase() === "true",
    },
    payment: {
      purchase_cost: Number(data.purchase_cost || 0),
      payout_method: textValue(data.payout_method),
      payout_reference_type: textValue(data.payout_reference_type),
      payout_payid: textValue(data.payout_payid),
      payout_bsb: textValue(data.payout_bsb),
      payout_account_number: textValue(data.payout_account_number),
      payout_account_name: textValue(data.payout_account_name),
    },
  };
}

function wrapText(text: string, font: PDFFont, size: number, maxWidth: number): string[] {
  const safeText = Array.from(String(text || "")).map((character) => {
    try {
      font.encodeText(character);
      return character;
    } catch {
      return "?";
    }
  }).join("");
  const paragraphs = safeText.replace(/\r/g, "").split("\n");
  const lines: string[] = [];
  for (const paragraph of paragraphs) {
    if (!paragraph.trim()) {
      lines.push("");
      continue;
    }
    const words = paragraph.trim().split(/\s+/);
    let line = "";
    for (const word of words) {
      const candidate = line ? `${line} ${word}` : word;
      if (line && font.widthOfTextAtSize(candidate, size) > maxWidth) {
        lines.push(line);
        line = word;
      } else {
        line = candidate;
      }
    }
    if (line) lines.push(line);
  }
  return lines;
}

async function createBuybackPdf(
  documentCode: string,
  snapshot: JsonRecord,
  termsText: string,
  signature: { bytes: Uint8Array; contentType: string },
): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const pageSize: [number, number] = [595.28, 841.89];
  const margin = 44;
  const maxWidth = pageSize[0] - margin * 2;
  let page: PDFPage = pdf.addPage(pageSize);
  let y = pageSize[1] - margin;

  const newPage = () => {
    page = pdf.addPage(pageSize);
    y = pageSize[1] - margin;
  };
  const ensure = (height: number) => { if (y - height < margin) newPage(); };
  const line = (text: string, options: { font?: PDFFont; size?: number; color?: ReturnType<typeof rgb>; gap?: number } = {}) => {
    const font = options.font || regular;
    const size = options.size || 9.5;
    const gap = options.gap || 3;
    const rows = wrapText(text, font, size, maxWidth);
    ensure(rows.length * (size + gap) + 3);
    for (const row of rows) {
      if (row) page.drawText(row, { x: margin, y, size, font, color: options.color || rgb(0.12, 0.17, 0.19) });
      y -= size + gap;
    }
  };
  const section = (title: string) => {
    ensure(28);
    y -= 5;
    page.drawLine({ start: { x: margin, y }, end: { x: pageSize[0] - margin, y }, thickness: 0.7, color: rgb(0.78, 0.82, 0.83) });
    y -= 17;
    line(title, { font: bold, size: 11, color: rgb(0, 0.45, 0.39), gap: 3 });
  };
  const field = (label: string, value: unknown) => line(`${label}: ${textValue(value) || "-"}`);

  pdf.setTitle(`TechM8 Buyback Agreement ${documentCode}`);
  pdf.setSubject("Signed used-device buyback agreement");
  pdf.setAuthor("TechM8 Australia");
  pdf.setCreator("TechM8 POS");
  pdf.setCreationDate(new Date(textValue(snapshot.captured_at) || Date.now()));
  await pdf.attach(new TextEncoder().encode(JSON.stringify({
    document_code: documentCode,
    signed_snapshot: snapshot,
    terms: termsText,
  }, null, 2)), "signed-buyback-record.json", {
    mimeType: "application/json",
    description: "Exact UTF-8 record embedded in this signed buyback agreement",
    creationDate: new Date(textValue(snapshot.captured_at) || Date.now()),
  });

  line("TECHM8", { font: bold, size: 20, color: rgb(0, 0, 0), gap: 4 });
  line("DEVICE BUYBACK AGREEMENT", { font: bold, size: 15, color: rgb(0, 0.45, 0.39), gap: 5 });
  field("Agreement reference", documentCode);
  field("Signed", new Date(textValue(snapshot.captured_at)).toLocaleString("en-AU", { timeZone: "Australia/Brisbane" }));
  field("Store", snapshot.store_name || snapshot.store_code);
  field("Witnessed by", snapshot.staff_name);

  const seller = (snapshot.seller || {}) as JsonRecord;
  section("Seller and identification");
  field("Seller", seller.name);
  field("Phone", seller.phone || "Not provided");
  field("Email", seller.email || "Not provided");
  field("Residential address", seller.address);
  field("Government ID", [seller.id_type, seller.id_reference].filter(Boolean).join(" - "));
  field("Seller is the owner", seller.is_owner ? "Yes" : "No");
  if (!seller.is_owner) {
    field("Legal owner", seller.owner_name);
    field("Owner address", seller.owner_address);
  }
  if (seller.acquisition_statement) field("How the device was obtained", seller.acquisition_statement);

  const device = (snapshot.device || {}) as JsonRecord;
  section("Device");
  field("Device", [device.brand, device.model, device.variant, device.storage, device.color].filter(Boolean).join(" "));
  field("Category", device.category);
  field("IMEI", device.imei || "Not recorded");
  field("Serial number", device.serial_number || "Not recorded");
  field("Battery health", device.battery_health ? `${device.battery_health}%` : "Not recorded");
  field("Lost / stolen check", device.clean_check_status);
  field("Activation locks removed", device.activation_lock_removed ? "Yes" : "No");
  field("Data erased / removable media returned", device.data_erased_confirmed ? "Yes" : "No");
  if (device.notes) field("Device notes", device.notes);

  const payment = (snapshot.payment || {}) as JsonRecord;
  section("Purchase and payout");
  field("Purchase amount", moneyValue(payment.purchase_cost));
  field("Payout method", payment.payout_method);
  if (payment.payout_reference_type === "PayID") field("PayID", payment.payout_payid);
  if (payment.payout_reference_type === "Bank Account") {
    field("Bank account", `${payment.payout_account_name || ""} · BSB ${payment.payout_bsb || ""} · Account ${payment.payout_account_number || ""}`);
  }

  const inspection = device.inspection && typeof device.inspection === "object" && !Array.isArray(device.inspection)
    ? device.inspection as JsonRecord : {};
  section("Recorded inspection");
  const checks = Object.entries(inspection);
  if (!checks.length) line("No individual inspection results were recorded.");
  else checks.forEach(([key, value]) => field(titleValue(key), titleValue(value)));

  section("Seller declaration");
  line(termsText, { size: 8.5, gap: 3 });

  ensure(150);
  section("Signed confirmation");
  field("Signed by", snapshot.signed_seller_name || seller.name);
  let signatureImage;
  if (signature.contentType === "image/png") signatureImage = await pdf.embedPng(signature.bytes);
  else signatureImage = await pdf.embedJpg(signature.bytes);
  const scaled = signatureImage.scaleToFit(250, 80);
  ensure(scaled.height + 30);
  page.drawImage(signatureImage, { x: margin, y: y - scaled.height, width: scaled.width, height: scaled.height });
  y -= scaled.height + 12;
  line("The signature, agreement details and evidence references above were captured together by TechM8 POS. This signed document is read-only.", { size: 8 });

  return await pdf.save({ useObjectStreams: false });
}

async function authorize(
  request: Request,
  sessionToken: string,
  storeCode: string,
  staffName = "",
): Promise<JsonRecord> {
  const response = await rpcResponse(request, "pos_authorized_actor", {
    session_token: sessionToken,
    target_store_code: storeCode,
    requested_staff_name: staffName || null,
  });
  const result = await response.json().catch(() => ({})) as JsonRecord;
  if (!response.ok || !result.ok) throw new Error(String(result.message || "Store access denied."));
  return result;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });

  const sessionToken = request.headers.get("x-staff-session") || "";
  if (!sessionToken) return jsonResponse({ ok: false, message: "Staff session is required." }, 401);

  try {
    const url = new URL(request.url);
    if (request.method === "GET") {
      const storeCode = url.searchParams.get("store_code") || "";
      if (!storeCode) return jsonResponse({ ok: false, message: "store_code is required." }, 400);
      await authorize(request, sessionToken, storeCode);
      const resource = url.searchParams.get("resource") || "devices";
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit") || 200), 1), 500);

      if (resource === "buyback-terms") {
        return await rpcResponse(request, "get_pos_used_device_buyback_terms", {
          session_token: sessionToken,
          target_store_code: storeCode,
        });
      }

      if (resource === "documents") {
        const deviceCode = url.searchParams.get("device_code") || "";
        if (!deviceCode) return jsonResponse({ ok: false, message: "device_code is required." }, 400);
        const result = await rpcJson("get_pos_used_device_buyback_documents", {
          session_token: sessionToken,
          target_store_code: storeCode,
          target_device_code: deviceCode,
        });
        if (result.status >= 400 || result.body.ok === false) return jsonResponse(result.body, result.status);
        const documents = Array.isArray(result.body.documents) ? result.body.documents as JsonRecord[] : [];
        const idPhotos = Array.isArray(result.body.id_photos) ? result.body.id_photos as JsonRecord[] : [];
        const withDocumentUrls = await Promise.all(documents.map(async (row) => {
          const { pdf_path: pdfPath, signature_path: signaturePath, ...publicRow } = row;
          return {
            ...publicRow,
            pdf_url: await storageSignedUrl(DOCUMENT_BUCKET, String(pdfPath || "")),
            signature_url: await storageSignedUrl(DOCUMENT_BUCKET, String(signaturePath || "")),
          };
        }));
        const withIdUrls = await Promise.all(idPhotos.map(async (row) => {
          const { storage_path: storagePath, ...publicRow } = row;
          return { ...publicRow, image_url: await storageSignedUrl(ID_PHOTO_BUCKET, String(storagePath || "")) };
        }));
        return jsonResponse({ ...result.body, documents: withDocumentUrls, id_photos: withIdUrls }, 200);
      }

      if (resource === "transactions") {
        return await rpcResponse(request, "get_pos_used_device_transactions", {
          session_token: sessionToken,
          target_store_code: storeCode,
          search_query: url.searchParams.get("q") || "",
          result_limit: limit,
        });
      }

      // The inspection checklist the POS renders is the same data the
      // ready-for-sale gate reads, so the two cannot drift apart.
      if (resource === "checklists") {
        return await rpcResponse(request, "get_pos_used_device_inspection_items", {
          session_token: sessionToken,
        });
      }

      // Every store's second-hand stock, not just this one. The RPC still
      // authorises the caller against their own store above; what it widens is
      // the read, and it drops seller identity and cost on the way out.
      if (resource === "network") {
        return await rpcResponse(request, "search_pos_used_device_network", {
          session_token: sessionToken,
          actor_store_code: storeCode,
          search_query: url.searchParams.get("q") || "",
          target_status: url.searchParams.get("status") || "",
          result_limit: limit,
        });
      }

      if (resource === "transfers") {
        return await rpcResponse(request, "get_pos_used_device_transfers", {
          session_token: sessionToken,
          target_store_code: storeCode,
          target_status: url.searchParams.get("status") || "",
          result_limit: limit,
        });
      }

      if (resource === "costs") {
        const deviceCode = url.searchParams.get("device_code") || "";
        if (!deviceCode) return jsonResponse({ ok: false, message: "device_code is required." }, 400);
        return await rpcResponse(request, "get_pos_used_device_costs", {
          session_token: sessionToken,
          store_code: storeCode,
          device_code: deviceCode,
        });
      }

      return await rpcResponse(request, "search_pos_used_devices", {
        session_token: sessionToken,
        target_store_code: storeCode,
        search_query: url.searchParams.get("q") || "",
        target_status: url.searchParams.get("status") || "",
        result_limit: limit,
      });
    }

    if (request.method === "POST") {
      const body = await request.json().catch(() => null);
      if (!body || typeof body !== "object" || Array.isArray(body)) {
        return jsonResponse({ ok: false, message: "Payload must be an object." }, 400);
      }
      const payload = body as JsonRecord;
      const action = String(payload.action || "acquire");
      const data = payload.payload && typeof payload.payload === "object" && !Array.isArray(payload.payload)
        ? payload.payload as JsonRecord
        : payload;
      const storeCode = String(data.store_code || data.store_db_code || "").trim().toLowerCase();
      if (!storeCode) return jsonResponse({ ok: false, message: "store_code is required." }, 400);
      const actor = await authorize(request, sessionToken, storeCode, String(data.staff_name || data.updated_by || ""));
      const safeData = {
        ...data,
        store_code: String(actor.store_code || storeCode),
        store_db_code: String(actor.store_code || storeCode),
        staff_name: String(actor.staff_name || ""),
        acquired_by: String(actor.staff_name || ""),
        updated_by: String(actor.staff_name || ""),
      };

      if (action === "acquire") {
        if (data.terms_acknowledged !== true) {
          return jsonResponse({ ok: false, message: "The seller must acknowledge the buyback agreement." }, 400);
        }
        const signedSellerName = String(data.signed_seller_name || "").trim();
        if (!signedSellerName) {
          return jsonResponse({ ok: false, message: "The seller must type their name and sign." }, 400);
        }
        if (signedSellerName.length > 120) {
          return jsonResponse({ ok: false, message: "The seller name cannot exceed 120 characters." }, 400);
        }
        let signature;
        try {
          signature = decodeSignature(String(data.signature_image || ""));
        } catch (error) {
          return jsonResponse({
            ok: false,
            message: error instanceof Error ? error.message : "The seller signature is invalid.",
          }, 400);
        }

        const terms = await rpcJson("get_pos_used_device_buyback_terms", {
          session_token: sessionToken,
          target_store_code: String(actor.store_code || storeCode),
        });
        if (terms.status >= 400 || terms.body.ok === false) return jsonResponse(terms.body, terms.status);
        const termsVersion = String(terms.body.version || "");
        const termsText = String(terms.body.body || "");
        if (!termsVersion || !termsText) {
          return jsonResponse({ ok: false, message: "The buyback agreement could not be loaded. Try again." }, 503);
        }
        if (String(data.terms_version || "") !== termsVersion) {
          return jsonResponse({ ok: false, message: "The buyback agreement terms changed. Close this window, review the current agreement and ask the seller to sign again." }, 409);
        }

        const signedAt = new Date().toISOString();
        const documentCode = `BBD-${new Date().toISOString().slice(0, 10).replace(/-/g, "")}-${crypto.randomUUID().replace(/-/g, "").slice(0, 16).toUpperCase()}`;
        const snapshot = buybackSnapshot(safeData, actor, signedSellerName, signedAt);
        let pdfBytes;
        try {
          pdfBytes = await createBuybackPdf(documentCode, snapshot, termsText, signature);
        } catch (error) {
          console.error("buyback PDF generation failed", error);
          return jsonResponse({ ok: false, message: "The signed buyback agreement could not be created. Check the entered details and try again." }, 400);
        }
        const pdfHashBytes = new Uint8Array(await crypto.subtle.digest("SHA-256", pdfBytes));
        const pdfSha256 = Array.from(pdfHashBytes, byte => byte.toString(16).padStart(2, "0")).join("");
        const folder = `${safeSegment(String(actor.store_code || storeCode))}/${safeSegment(documentCode)}`;
        const signaturePath = `${folder}/signature.${signature.extension}`;
        const pdfPath = `${folder}/agreement.pdf`;

        await uploadPrivateObject(signaturePath, signature.bytes, signature.contentType);
        try {
          await uploadPrivateObject(pdfPath, pdfBytes, "application/pdf");
        } catch (error) {
          await deletePrivateObject(signaturePath);
          throw error;
        }

        const { signature_image: _signatureImage, terms_acknowledged: _termsAcknowledged,
          signed_seller_name: _signedSellerName, terms_version: _termsVersion, ...acquisitionData } = safeData;
        let result;
        try {
          result = await rpcJson("create_pos_used_device_acquisition_with_document", {
            session_token: sessionToken,
            payload: {
              ...acquisitionData,
              signed_document: {
                document_code: documentCode,
                signed_seller_name: signedSellerName,
                terms_version: termsVersion,
                signature_path: signaturePath,
                pdf_path: pdfPath,
                pdf_sha256: pdfSha256,
                document_snapshot: snapshot,
              },
            },
          });
        } catch (error) {
          await Promise.all([deletePrivateObject(signaturePath), deletePrivateObject(pdfPath)]);
          throw error;
        }
        if (result.status >= 400 || result.body.ok === false) {
          await Promise.all([deletePrivateObject(signaturePath), deletePrivateObject(pdfPath)]);
          return jsonResponse(result.body, result.status);
        }
        return jsonResponse(result.body, 200);
      }
      if (action === "update") {
        return await rpcResponse(request, "update_pos_used_device", {
          session_token: sessionToken,
          payload: safeData,
        });
      }
      if (action === "add-cost") {
        const deviceCode = String(data.device_code || "").trim();
        if (!deviceCode) return jsonResponse({ ok: false, message: "device_code is required." }, 400);
        return await rpcResponse(request, "add_pos_used_device_cost", {
          session_token: sessionToken,
          store_code: String(actor.store_code || storeCode),
          device_code: deviceCode,
          payload: {
            id: data.id,
            kind: data.kind,
            description: data.description,
            amount: data.amount,
            repair_ticket_code: data.repair_ticket_code,
          },
        });
      }
      // Store-to-store device movement. store_code is rewritten to the store
      // the session actually proved access to, so a caller cannot claim to be
      // sending from, or receiving at, somewhere they do not work.
      if (action === "transfer-send") {
        return await rpcResponse(request, "send_pos_used_device_transfer", {
          session_token: sessionToken,
          payload: safeData,
        });
      }
      if (action === "transfer-receive") {
        return await rpcResponse(request, "receive_pos_used_device_transfer", {
          session_token: sessionToken,
          payload: safeData,
        });
      }
      if (action === "transfer-cancel") {
        return await rpcResponse(request, "cancel_pos_used_device_transfer", {
          session_token: sessionToken,
          payload: safeData,
        });
      }
      return jsonResponse({ ok: false, message: "Unknown used-device action." }, 400);
    }

    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  } catch (error) {
    console.error(error);
    return jsonResponse({
      ok: false,
      message: error instanceof Error ? error.message : "Used-device request failed.",
    }, 500);
  }
});
