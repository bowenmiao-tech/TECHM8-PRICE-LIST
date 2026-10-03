import Anthropic from "npm:@anthropic-ai/sdk@0.131.0";
import { betaJSONSchemaOutputFormat } from "npm:@anthropic-ai/sdk@0.131.0/helpers/beta/json-schema";

// Reads a pasted WeChat supplier-group chat (text and/or screenshots) and pulls
// out what was ordered, the prices and the domestic tracking numbers. Nothing is
// saved here: the admin checks the result on the page and saves it with
// import_chat.

const MODEL = "claude-opus-5-5";
const MAX_TEXT_CHARS = 20000;
const MAX_IMAGES = 4;
const MAX_IMAGE_BASE64_CHARS = 4_000_000;
const IMAGE_TYPES = ["image/jpeg", "image/png", "image/webp", "image/gif"] as const;
type ImageType = typeof IMAGE_TYPES[number];

export type ChatImage = { media_type: string; data: string };
export type ChatParseInput = {
  apiKey: string;
  text: string;
  images: ChatImage[];
  suppliers: string[];
  forwarders: { name: string; warehouse_address: string | null }[];
};

const text = (description: string) => ({ type: "string", description }) as const;
const orNull = <const T extends object>(schema: T) => ({ anyOf: [schema, { type: "null" }] }) as const;

const EXTRACTION_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: [
    "supplier_name", "forwarder_name", "order_date", "currency", "items",
    "goods_amount", "domestic_shipping_amount", "parcels", "notes", "warnings",
  ],
  properties: {
    supplier_name: orNull(text("The supplier this chat is with, preferably exactly as in the known supplier list.")),
    forwarder_name: orNull(text("Forwarder the goods are sent to, from the known forwarder list, if the chat says.")),
    order_date: orNull(text("Order date as YYYY-MM-DD, only if the chat shows it.")),
    currency: { type: "string", enum: ["CNY", "AUD", "USD"] },
    items: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["description", "quantity", "unit_cost"],
        properties: {
          description: text("Product, model, colour and grade, in the chat's wording."),
          quantity: { type: "integer", description: "Number of pieces." },
          unit_cost: orNull({ type: "number", description: "Price per piece in the order currency." }),
        },
      },
    },
    goods_amount: orNull({ type: "number", description: "Total for goods if stated, excluding shipping." }),
    domestic_shipping_amount: orNull({ type: "number", description: "Domestic courier fee if stated." }),
    parcels: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: [
          "tracking_no", "courier", "contents", "carton_count", "estimated_weight_kg", "has_battery", "has_magnet",
        ],
        properties: {
          tracking_no: text("Domestic courier tracking number with spaces removed."),
          courier: orNull(text("Chinese courier name, e.g. 顺丰, 中通, 圆通, 韵达, 申通, 极兔, 京东, 邮政, 德邦.")),
          contents: text("What is in this parcel."),
          carton_count: { type: "integer", description: "Boxes under this tracking number." },
          estimated_weight_kg: orNull({ type: "number", description: "Packed shipping weight in kg." }),
          has_battery: { type: "boolean" },
          has_magnet: { type: "boolean" },
        },
      },
    },
    notes: orNull(text("Short Chinese note worth keeping on the order.")),
    warnings: { type: "array", items: text("Short Chinese sentence about something uncertain.") },
  },
} as const;

const SYSTEM_PROMPT = `You read chats from WeChat groups between TECHM8 (a phone repair business in Brisbane, Australia, and the buyer — shown as "我", "Me" or the account owner) and its parts suppliers in China. The admin pastes part of a group chat, sometimes with screenshots of order lists, payment requests or courier labels. Extract the purchase so it can be recorded. The admin checks your result before it is saved.

items
- Only goods the buyer ordered and the supplier agreed to supply. One line per product, model, colour and grade.
- quantity is the number of pieces. unit_cost is the price per piece in the order currency. If only a line total is given, divide it by the quantity. If no price was given, use null — never guess a price.
- If the chat changes the order later (out of stock, cancelled, quantity changed), use the final agreed version and say what changed in warnings.

amounts
- goods_amount: the goods total if the chat states one (for example the amount the supplier asks to be paid, minus shipping). domestic_shipping_amount: the domestic courier fee if stated. Otherwise null.
- currency: CNY unless the chat clearly uses another currency.

parcels
- One parcel per domestic courier tracking number (快递单号, 运单号), including numbers read from label photos. Remove spaces inside the number. Do not list international forwarder numbers.
- courier: the courier named in the chat or on the label. From the number alone only when the prefix is unambiguous (SF = 顺丰, YT = 圆通, JT = 极兔, JD = 京东); otherwise null.
- contents: what is in that parcel if the chat says. With one parcel for the whole order, summarise the order lines, e.g. "iPhone 13 屏幕 ×20，iPhone 12 电池 ×10".
- carton_count: boxes under that number, 1 if not stated.
- estimated_weight_kg: packed shipping weight, used to decide when the forwarder has enough goods to ship. Use the weight the supplier states; otherwise estimate from the contents (packed phone screen about 0.15–0.25 kg each, tablet screen about 0.5 kg, battery about 0.06 kg, small flex or charging-port parts about 0.02 kg, plus packaging). null if the contents are unknown.
- has_battery: true for batteries (电池) or anything containing a battery. has_magnet: true for speakers, earpieces, magnets and MagSafe parts (喇叭, 听筒, 磁铁, 磁吸).

other fields
- supplier_name: the supplier this chat is with, written exactly as in the known supplier list when it matches one; otherwise the name used in the chat; null if unclear.
- forwarder_name: if the chat says where the goods go (a forwarder name or warehouse address), the matching name from the known forwarder list; otherwise null.
- order_date: YYYY-MM-DD only if the chat shows the date of the order.
- notes: a short Chinese note worth keeping, such as a promised dispatch date or quality grade (原装, 高仿, OLED, INCELL). null if nothing.
- warnings: short Chinese sentences about anything uncertain: unreadable or incomplete numbers, missing prices, totals that do not add up.

Never invent items, prices or tracking numbers that are not in the chat or the images.`;

export type ChatExtraction = {
  supplier_name: string | null;
  forwarder_name: string | null;
  order_date: string | null;
  currency: "CNY" | "AUD" | "USD";
  items: { description: string; quantity: number; unit_cost: number | null }[];
  goods_amount: number | null;
  domestic_shipping_amount: number | null;
  parcels: {
    tracking_no: string;
    courier: string | null;
    contents: string;
    carton_count: number;
    estimated_weight_kg: number | null;
    has_battery: boolean;
    has_magnet: boolean;
  }[];
  notes: string | null;
  warnings: string[];
};

export function validateChatInput(rawText: unknown, rawImages: unknown): { text: string; images: ChatImage[] } {
  const chat = String(rawText || "").trim();
  if (chat.length > MAX_TEXT_CHARS) throw new Error(`Chat text must be under ${MAX_TEXT_CHARS} characters.`);
  const images = Array.isArray(rawImages) ? rawImages : [];
  if (images.length > MAX_IMAGES) throw new Error(`Choose at most ${MAX_IMAGES} images.`);
  const checked = images.map((image) => {
    const mediaType = String((image as ChatImage)?.media_type || "");
    const data = String((image as ChatImage)?.data || "");
    if (!IMAGE_TYPES.includes(mediaType as ImageType)) throw new Error("Images must be JPEG, PNG, WebP or GIF.");
    if (!data || data.length > MAX_IMAGE_BASE64_CHARS) throw new Error("Each image must be under 3 MB.");
    return { media_type: mediaType, data };
  });
  if (!chat && !checked.length) throw new Error("Chat text or a screenshot is required.");
  return { text: chat, images: checked };
}

export async function parseChat(input: ChatParseInput): Promise<ChatExtraction> {
  const client = new Anthropic({ apiKey: input.apiKey, timeout: 120_000, maxRetries: 1 });
  const known = [
    `已知供货商：${input.suppliers.join("、") || "（无）"}`,
    `已知转运：${input.forwarders.map((forwarder) =>
      forwarder.warehouse_address ? `${forwarder.name}（仓库：${forwarder.warehouse_address}）` : forwarder.name
    ).join("、") || "（无）"}`,
  ].join("\n");
  const content: Anthropic.Beta.BetaContentBlockParam[] = input.images.map((image) => ({
    type: "image" as const,
    source: { type: "base64" as const, media_type: image.media_type as ImageType, data: image.data },
  }));
  content.push({
    type: "text",
    text: `${known}\n\n${input.text ? `<chat>\n${input.text}\n</chat>` : "（只有截图，没有文字）"}`,
  });

  try {
    const response = await client.beta.messages.parse({
      model: MODEL,
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: "medium", format: betaJSONSchemaOutputFormat(EXTRACTION_SCHEMA) },
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content }],
    });
    if (response.stop_reason === "refusal") throw new Error("AI could not read this chat. Please enter it by hand.");
    if (response.stop_reason === "max_tokens") throw new Error("Chat is too long for one read. Paste a shorter part.");
    if (!response.parsed_output) throw new Error("AI returned an unreadable result. Please try again.");
    return response.parsed_output as ChatExtraction;
  } catch (error) {
    if (error instanceof Anthropic.AuthenticationError) {
      throw new Error("AI key is invalid. Check ANTHROPIC_API_KEY in Supabase.");
    }
    if (error instanceof Anthropic.RateLimitError) throw new Error("AI is busy. Please try again in a minute.");
    if (error instanceof Anthropic.APIConnectionError) throw new Error("Could not reach the AI service. Please try again.");
    if (error instanceof Anthropic.APIError) throw new Error(`AI request failed (${error.status}): ${error.message}`);
    throw error;
  }
}
