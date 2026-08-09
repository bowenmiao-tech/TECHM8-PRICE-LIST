import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const auditPath = path.resolve("audit.json");
const outputDir = path.resolve("..", "..", "outputs", "product-category-classification-20260809");
const previewDir = path.join(outputDir, "previews");
const outputPath = path.join(outputDir, "TechM8_Product_Category_Review.xlsx");

const audit = JSON.parse(await fs.readFile(auditPath, "utf8"));
const products = audit.products;

const categoryOrder = [
  "Phone Cases",
  "Tablet Cases",
  "Screen Protection",
  "Cables & Adapters",
  "Charging & Power",
  "Audio",
  "Mounts & Holders",
  "Watch Accessories",
  "Computer & Gaming",
  "Other Electronics",
  "POS System Items",
  "Exclude",
];

const categoryDefinitions = [
  [1, "Phone Cases", "Apple iPhone / Samsung Galaxy / Other & Universal", "Phone Cases", "Phone model and case style", "Phone cases only; Earbud, tracker and tablet cases are separated."],
  [2, "Tablet Cases", "Apple iPad / Samsung Galaxy Tab / Other & Universal", "Tablet Cases", "Compatible tablet family and case style", "Compatibility group is more important than individual model wording."],
  [3, "Screen Protection", "Phone / Tablet / Watch & Lens", "Screen Protectors", "Device family and protector type", "Warranty replacement is a POS system item, not a retail product."],
  [4, "Cables & Adapters", "Charging & Data / Display / Network / Audio / OTG", "Cables, Computer Accessories, Audio Accessories", "Connector, length and capability", "Computer cables stay here; scene tags can also expose them under Computer."],
  [5, "Charging & Power", "Wall / Wireless / Car / Laptop / Power Banks", "Chargers, Car Accessories, Travel", "Power output, ports and charging standard", "Car chargers are charging products with a Car Accessories tag."],
  [6, "Audio", "Wired / Wireless / Headsets / Speakers / Microphones", "Audio, Gaming Accessories", "Wired or wireless format", "Gaming headsets stay in Audio and receive a Gaming tag."],
  [7, "Mounts & Holders", "Vehicle / Desk / Laptop / Monitor / Selfie / Wallets & Grips", "Mounts, Car Accessories, Desk Accessories", "Mounting location and device", "Includes phone straps, card holders and mount accessories."],
  [8, "Watch Accessories", "Bands / Cases", "Watch Accessories", "Watch size and material", "Watch screen protectors remain under Screen Protection with a Watch tag."],
  [9, "Computer & Gaming", "PC Parts / Storage / Input / Hubs / Networking / Console / Simulation", "Computer, Gaming", "Hardware function", "USB hubs are computer peripherals; cables remain in Cables & Adapters."],
  [10, "Other Electronics", "Drones / Fans / Lighting & Clocks / Small Device Cases", "Other Electronics", "Actual product type", "Small valid product groups that do not justify another POS top-level tile."],
  [90, "POS System Items", "Adjustments / Services / Packaging / Generic Sale Items", "Not shown as a retail category", "System function", "POS-only records; always hidden from the public website."],
  [99, "Exclude", "Repair or obsolete records", "None", "Reason for exclusion", "Do not migrate into the retail catalog."],
];

const duplicateSkuCounts = new Map(
  audit.duplicateSkus.map((group) => [String(group.key).toLowerCase(), group.rows.length]),
);

const systemItems = new Map([
  ["10291", ["Adjustments", "Surcharge"]],
  ["10054", ["Services", "Racing Simulator Service"]],
  ["8633", ["Packaging", "Retail Bag"]],
  ["8632", ["Packaging", "Retail Bag"]],
  ["8416", ["Generic Sale Items", "Special Order"]],
  ["6769", ["Adjustments", "Shop Credit"]],
  ["6021", ["Generic Sale Items", "Special Sale"]],
  ["5957", ["Generic Sale Items", "Miscellaneous Sale"]],
  ["5934", ["Services", "SIM Product/Service"]],
  ["7609", ["Warranty Operations", "Warranty Replacement"]],
]);

const manualIds = new Map([
  ["8483", "Confirm whether Drone Map is a physical product, accessory or service."],
  ["8840", "Confirm that this is a cable only. If it includes a power adapter, move it to Laptop Chargers."],
  ["7159", "Generic case sale item requires the device model at checkout; keep POS-only and hide online."],
]);

const genericPhoneCaseIds = new Set([
  "9668", "8372", "8031", "8030", "8029", "8028", "8027", "8026", "8025", "6000", "5915", "5914",
]);

const numberValue = (value) => {
  const parsed = Number(String(value ?? "").replace(/[$,]/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
};

const identifierValue = (value) => value ? String(value) : "";
const identifierFormula = (value) => {
  const raw = String(value || "");
  if (!raw) return '=""';
  if (/^\d+$/.test(raw)) return `=TEXT(${Number(raw)},"${"0".repeat(raw.length)}")`;
  return `="${raw.replace(/"/g, '""')}"`;
};

const leafCategory = (category) => {
  const parts = String(category || "").split(">").map((part) => part.trim());
  return parts.length > 1 ? parts.at(-1) : "";
};

const cleanWhitespace = (value) => String(value || "").replace(/\s+/g, " ").trim();

function detectBrand(product) {
  const text = `${product.name} ${product.category}`;
  const brands = [
    ["Apple", /\b(iphone|ipad|macbook|airpods?|airtag|apple watch|apple pencil)\b/i],
    ["Samsung", /\b(samsung|galaxy)\b/i],
    ["Google", /\bgoogle|pixel\b/i],
    ["REMAX", /\bremax\b/i],
    ["WEKOME", /\bwekome\b/i],
    ["OtterBox", /\botter\s?box\b/i],
    ["EFM", /\befm\b/i],
    ["LifeProof", /\blife\s?proof\b/i],
    ["Sony / PlayStation", /\bsony|playstation|dualsense|ps5\b/i],
    ["Microsoft / Xbox", /\bmicrosoft|xbox\b/i],
    ["MSI", /\bmsi\b/i],
    ["ZOTAC", /\bzotac\b/i],
    ["YESIDO", /\byesido\b/i],
    ["FIMI", /\bfimi\b/i],
    ["MOZA", /\bmoza\b/i],
    ["Acer", /\bacer\b/i],
  ];
  const match = brands.find(([, regex]) => regex.test(text));
  return match?.[0] || cleanWhitespace(product.manufacturer) || "Other / Generic";
}

function detectColour(product) {
  const colourEligible = /case|cover|band|strap|holder|mount|charger|power bank|speaker|headphone|earbud|chair|table/i.test(
    `${product.name} ${product.category}`,
  );
  if (!colourEligible) return "";
  const colourPatterns = [
    ["Rose Gold", /\brose gold\b/i],
    ["Dark Green", /\bdark green\b/i],
    ["Sky Blue", /\bsky blue\b/i],
    ["Navy Blue", /\bnavy(?: blue)?\b/i],
    ["Light Blue", /\blight blue\b/i],
    ["Light Green", /\blight green\b/i],
    ["Space Grey", /\bspace gr(?:e|a)y\b/i],
    ["Grey", /\bgr(?:e|a)y\b/i],
    ["Black", /\bblack\b/i],
    ["White", /\bwhite\b/i],
    ["Blue", /\bblue\b/i],
    ["Green", /\bgreen\b/i],
    ["Pink", /\bpink\b/i],
    ["Purple", /\bpurple\b/i],
    ["Red", /\bred\b/i],
    ["Yellow", /\byellow\b/i],
    ["Orange", /\borange\b/i],
    ["Brown", /\bbrown\b/i],
    ["Silver", /\bsilver\b/i],
    ["Gold", /\bgold\b/i],
    ["Clear", /\bclear\b/i],
    ["Transparent", /\btransparent\b/i],
    ["Rainbow", /\brainbow\b/i],
  ];
  return colourPatterns.find(([, regex]) => regex.test(product.name))?.[0] || "";
}

function detectPhoneModel(product) {
  const name = cleanWhitespace(product.name);
  const iphone = name.match(/iPhone\s*(6\+\/7\+\/8\+|6\/7\/8|6\+\/7\+\/8\+|X\/XS|XS\s*Max|XR|SE(?:\s*\d+)?|1[0-7](?:\s*(?:Pro\s*Max|Pro|Plus|Mini|Air|E|PM))?)/i);
  if (iphone) {
    let model = cleanWhitespace(iphone[1]).replace(/\bPM\b/i, "Pro Max");
    return `iPhone ${model}`;
  }
  const samsung = name.match(/(?:Samsung\s+)?(?:Galaxy\s+)?(Z\s*(?:Flip|Fold)\s*\d*|S\d{1,2}(?:\s*(?:Ultra|Plus|FE|U|P|\+))?|A\d{1,2}(?:\s*\+)?|Note\s*\d+(?:\s*(?:Ultra|Plus|\+))?)/i);
  if (samsung) {
    let model = cleanWhitespace(samsung[1]);
    model = model.replace(/^(S\d{1,2})U$/i, "$1 Ultra").replace(/^(S\d{1,2})P$/i, "$1 Plus");
    return `Samsung Galaxy ${model}`;
  }
  const pixel = name.match(/(?:Google\s+)?Pixel\s*([\dA-Za-z ]+)/i);
  if (pixel) return `Google Pixel ${cleanWhitespace(pixel[1]).split(/\b(case|cover|screen)\b/i)[0].trim()}`;
  const leaf = leafCategory(product.category);
  if (/iphone|samsung|universal/i.test(leaf) && !/otter|life proof|efm|air pod|air tag/i.test(leaf)) return leaf;
  return "Model not structured";
}

function detectTabletCompatibility(product) {
  const leaf = leafCategory(product.category);
  if (leaf) return leaf.replace(/^ipad/i, "iPad").replace(/Por\b/gi, "Pro");
  const name = cleanWhitespace(product.name);
  if (/iPad/i.test(name)) {
    const match = name.match(/iPad\s+(.+?)(?:\s+(?:Hard|Twist|Z-Fold|Z-Flip|Flip|Bubble|Survivor|Case|Cover)\b|$)/i);
    if (match) return `iPad ${cleanWhitespace(match[1])}`;
  }
  if (/Samsung|Galaxy Tab/i.test(name)) {
    const match = name.match(/(?:Samsung\s+)?Galaxy\s+Tab\s+([A-Za-z0-9+ ]+)/i);
    if (match) return `Samsung Galaxy Tab ${cleanWhitespace(match[1]).split(/\b(case|cover)\b/i)[0].trim()}`;
  }
  return "Model not structured";
}

function detectProductType(category, subcategory, name) {
  const text = `${name} ${category}`;
  if (/twist leather/i.test(text)) return "Twist Leather Case";
  if (/z[- ]?fold/i.test(text)) return "Z-Fold Case";
  if (/z[- ]?flip/i.test(text)) return "Z-Flip Case";
  if (/bubble hard/i.test(text)) return "Bubble Hard Case";
  if (/survivor/i.test(text)) return "Survivor Case";
  if (/hard case/i.test(text)) return "Hard Case";
  if (/wallet case/i.test(text)) return "Wallet Case";
  if (/flip case/i.test(text)) return "Flip Case";
  if (/waterproof.*case|case.*waterproof/i.test(text)) return "Waterproof Case";
  if (/screen protector|tempered glass|glass screen/i.test(text)) return "Screen Protector";
  if (/power bank/i.test(text)) return "Power Bank";
  if (/charger/i.test(text)) return subcategory.replace(/s$/, "");
  if (/headset/i.test(text)) return "Headset";
  if (/headphone/i.test(text)) return "Headphones";
  if (/earphone/i.test(text)) return "Earphones";
  if (/earbud|tws/i.test(text)) return "Earbuds";
  if (/speaker/i.test(text)) return "Speaker";
  if (/holder|mount/i.test(text)) return "Mount / Holder";
  if (/stand/i.test(text)) return "Stand";
  if (/band|watch strap/i.test(text)) return "Watch Band";
  if (/cable|hdmi|displayport|\bdp\b|ethernet/i.test(text)) return "Cable";
  if (/adapter|adaptor|dongle|converter|otg/i.test(text)) return "Adapter";
  if (/case|cover/i.test(text)) return "Case";
  return subcategory;
}

function classify(product) {
  const category = product.category || "";
  const name = product.name || "";
  const lowerName = name.toLowerCase();

  if (systemItems.has(product.id)) {
    const [subcategory, productType] = systemItems.get(product.id);
    return {
      category: "POS System Items",
      subcategory,
      productType,
      status: "System only",
      reviewReason: "System operation record; do not show as a normal retail product.",
      action: "Keep POS-only; hide from website category browsing.",
    };
  }

  if (product.id === "9663") {
    return {
      category: "Exclude",
      subcategory: "Repair / Obsolete Records",
      productType: "LCD Frame",
      status: "Exclude",
      reviewReason: "Acer N18H1 LCD frame was incorrectly placed in Drone and is not part of the retail catalog.",
      action: "Do not include in the new retail product catalog.",
    };
  }

  if (category === "Uncategorized") {
    if (["8974", "8412", "8411", "7763"].includes(product.id)) {
      return { category: "Mounts & Holders", subcategory: "Straps & Attachments", productType: "Phone Strap / Attachment", status: "Classified", reviewReason: "", action: "Move to the proposed retail category." };
    }
    if (product.id === "6806") return { category: "Watch Accessories", subcategory: "Watch Cases", productType: "Watch Case", status: "Classified", reviewReason: "", action: "Move to the proposed retail category." };
    if (product.id === "5995") return { category: "Computer & Gaming", subcategory: "Input & Office Accessories", productType: "Stylus", status: "Classified", reviewReason: "", action: "Move to the proposed retail category." };
    if (["6062", "6061"].includes(product.id)) return { category: "Other Electronics", subcategory: "Lighting & Clocks", productType: /clock/i.test(name) ? "Digital Clock" : "RGB Light", status: "Classified", reviewReason: "", action: "Move to the proposed retail category." };
  }

  if (category.startsWith("1. Phone Cables")) {
    if (/otg|card reader/i.test(name)) return { category: "Cables & Adapters", subcategory: "OTG & Card Readers", status: "Classified" };
    return { category: "Cables & Adapters", subcategory: "Charging & Data Cables", status: "Classified" };
  }

  if (category.startsWith("2. Charger")) {
    if (category.includes("Car Charger")) return { category: "Charging & Power", subcategory: "Car Chargers", status: "Classified" };
    if (category.includes("MacBook Charger")) return { category: "Charging & Power", subcategory: "Laptop Chargers", status: "Classified" };
    if (category.includes("Wall Charger")) return { category: "Charging & Power", subcategory: "Wall Chargers", status: "Classified" };
    if (category.includes("Wireless Charger")) return { category: "Charging & Power", subcategory: "Wireless Chargers", status: "Classified" };
    return { category: "Charging & Power", subcategory: "Other Chargers", status: "Manual check", reviewReason: "Charger subtype is not defined in the source category.", action: "Confirm charger subtype." };
  }

  if (category === "3. Screen Protector") {
    const subcategory = /ipad|tablet/i.test(name) ? "Tablet Screen Protection"
      : /watch|lens/i.test(name) ? "Watch & Lens Protection"
        : "Phone Screen Protection";
    return { category: "Screen Protection", subcategory, status: "Classified" };
  }

  if (category.startsWith("4. Car FM")) {
    if (/metal plate/i.test(name)) return { category: "Mounts & Holders", subcategory: "Vehicle Mount Accessories", status: "Classified" };
    if (category.includes("Car Holder") || /holder|mount/i.test(name)) return { category: "Mounts & Holders", subcategory: "Vehicle Mounts", status: "Classified" };
    return { category: "Cables & Adapters", subcategory: "Car Connectivity", status: "Classified" };
  }

  if (category.startsWith("5. Phone Cases")) {
    if (category.includes("Air Pods") || /earbud.*(?:case|pouch)|airpods?.*(?:case|cover)/i.test(name)) return { category: "Other Electronics", subcategory: "Earbud Cases", status: "Classified" };
    if (category.includes("Air Tag") || /air\s?tag.*(?:case|holder|cover)/i.test(name)) return { category: "Other Electronics", subcategory: "Tracker Cases", status: "Classified" };
    if (genericPhoneCaseIds.has(product.id) || product.id === "7159") {
      return {
        category: "Phone Cases",
        subcategory: /samsung/i.test(name) ? "Samsung Galaxy" : "Other & Universal",
        status: "Manual check",
        reviewReason: manualIds.get(product.id) || "The product name does not identify a compatible phone model.",
        action: "Keep POS-only until model compatibility is confirmed; hide from website.",
      };
    }
    return { category: "Phone Cases", subcategory: /samsung|galaxy/i.test(`${name} ${leafCategory(category)}`) ? "Samsung Galaxy" : /pixel|google/i.test(`${name} ${leafCategory(category)}`) ? "Google Pixel" : /iphone/i.test(`${name} ${leafCategory(category)}`) ? "Apple iPhone" : "Other & Universal", status: "Classified" };
  }

  if (category.startsWith("6. iPad & Tablet Cases")) {
    return { category: "Tablet Cases", subcategory: /samsung|galaxy|\btab\b/i.test(`${name} ${leafCategory(category)}`) ? "Samsung Galaxy Tab" : /ipad/i.test(`${name} ${leafCategory(category)}`) ? "Apple iPad" : "Other & Universal", status: "Classified" };
  }

  if (category === "7. Power Bank") return { category: "Charging & Power", subcategory: "Power Banks", status: "Classified" };

  if (category.startsWith("8. Headphones")) {
    if (category.includes("Headphones Adapter")) return { category: "Cables & Adapters", subcategory: "Audio Cables & Adapters", status: "Classified" };
    if (category.includes("Line Headphones")) return { category: "Audio", subcategory: "Wired Earphones & Headphones", status: "Classified" };
    return { category: "Audio", subcategory: "Wireless Earbuds & Headphones", status: "Classified" };
  }

  if (category === "9. Holder, Stand, Fans") {
    if (/\bfan\b|fans|neckband fan/i.test(name)) return { category: "Other Electronics", subcategory: "Personal Fans", status: "Classified" };
    if (/selfie|live stream/i.test(name)) return { category: "Mounts & Holders", subcategory: "Selfie Sticks & Live Stands", status: "Classified" };
    if (/laptop/i.test(name)) return { category: "Mounts & Holders", subcategory: "Laptop Stands", status: "Classified" };
    return { category: "Mounts & Holders", subcategory: "Phone & Tablet Stands", status: "Classified" };
  }

  if (category.startsWith("9.1 Watch Band")) return { category: "Watch Accessories", subcategory: "Watch Bands", status: "Classified" };
  if (category === "9.2 Speaker") return { category: "Audio", subcategory: "Speakers", status: "Classified" };

  if (category.startsWith("9.3 Computer & Console Products")) {
    if (category.includes("Computer Cables")) {
      if (product.id === "8840") return { category: "Cables & Adapters", subcategory: "Charging & Data Cables", status: "Manual check", reviewReason: manualIds.get(product.id), action: "Confirm whether it is cable-only or a complete charger." };
      if (/aux|3\.5mm|audio/i.test(name)) return { category: "Cables & Adapters", subcategory: "Audio Cables & Adapters", status: "Classified" };
      if (/ethernet|cat\s?[5-8]|network/i.test(name)) return { category: "Cables & Adapters", subcategory: "Network Cables", status: "Classified" };
      return { category: "Cables & Adapters", subcategory: "Display & Computer Cables", status: "Classified" };
    }
    if (category.includes("Computer Hub")) return { category: "Computer & Gaming", subcategory: "Hubs & Docks", status: "Classified" };
    if (category.includes("Headset")) return { category: "Audio", subcategory: /headphone/i.test(name) && !/headset/i.test(name) ? "Wireless Earbuds & Headphones" : "Headsets", status: "Classified" };
    if (category.includes("Microphones")) return { category: "Audio", subcategory: "Microphones", status: "Classified" };
    if (category.includes("Wire Speaker")) return { category: "Audio", subcategory: "Speakers", status: "Classified" };
    if (category.includes("Laptop Bag")) return { category: "Computer & Gaming", subcategory: "Laptop Bags & Sleeves", status: "Classified" };
    if (category.includes("Monitor mounts")) return { category: "Mounts & Holders", subcategory: "Monitor Mounts", status: "Classified" };
    if (category.includes("Consoles & Accessories")) return { category: "Computer & Gaming", subcategory: "Consoles & Controllers", status: "Classified" };
    if (category.includes("Racing Simulator")) return { category: "Computer & Gaming", subcategory: "Racing Simulation", status: "Classified" };
    if (category.includes("Hard Drive") || category.includes("SD Card") || category.endsWith("> USB")) return { category: "Computer & Gaming", subcategory: "Storage", status: "Classified" };
    if (category.includes("Keyboard Accessories")) return { category: "Computer & Gaming", subcategory: "Input & Office Accessories", status: "Classified" };
    if (category.includes("Keyboard") || category.includes("Mouse") || category.includes("Office combo")) return { category: "Computer & Gaming", subcategory: "Keyboards, Mice & Combos", status: "Classified" };
    if (category.includes("Webcams")) return { category: "Computer & Gaming", subcategory: "Webcams", status: "Classified" };
    if (category.includes("Wireless Adapter")) return { category: "Computer & Gaming", subcategory: "Networking", status: "Classified" };
    return { category: "Computer & Gaming", subcategory: "PC Components", status: "Classified" };
  }

  if (category.startsWith("9.4 Gaming Chair")) {
    if (/monitor mount|monitor stand/i.test(name)) return { category: "Mounts & Holders", subcategory: "Monitor Mounts", status: "Classified" };
    return { category: "Computer & Gaming", subcategory: "Gaming & Simulation Furniture", status: "Classified" };
  }

  if (category.startsWith("Card Holder & Pop Scoket")) {
    if (/earbud.*pouch/i.test(name)) return { category: "Other Electronics", subcategory: "Earbud Cases", status: "Classified" };
    return { category: "Mounts & Holders", subcategory: "Wallets, Card Holders & Grips", status: "Classified" };
  }

  if (category === "Drone") {
    if (product.id === "8483") return { category: "Other Electronics", subcategory: "Drones & Accessories", status: "Manual check", reviewReason: manualIds.get(product.id), action: "Confirm product type before website publication." };
    return { category: "Other Electronics", subcategory: "Drones & Accessories", status: "Classified" };
  }

  return { category: "Other Electronics", subcategory: "Unresolved", status: "Manual check", reviewReason: "No reliable category rule matched this item.", action: "Confirm the physical product type." };
}

function collectionTags(product, result, brand) {
  const tags = new Set();
  if (brand !== "Other / Generic") tags.add(brand.split(" /")[0]);
  if (/car|vehicle/i.test(`${product.name} ${result.subcategory}`)) tags.add("Car Accessories");
  if (/gaming|sim|playstation|ps5|xbox|controller/i.test(`${product.name} ${product.category} ${result.subcategory}`)) tags.add("Gaming");
  if (/computer|pc |keyboard|mouse|storage|hub|dock|network|hdmi|displayport|\bdp\b/i.test(`${product.name} ${product.category} ${result.subcategory}`)) tags.add("Computer");
  if (/watch/i.test(`${product.name} ${product.category} ${result.category}`)) tags.add("Watch");
  if (/ipad|tablet|galaxy tab/i.test(`${product.name} ${product.category}`)) tags.add("Tablet");
  if (/magsafe/i.test(product.name)) tags.add("MagSafe");
  if (/wireless|bluetooth|tws/i.test(product.name)) tags.add("Wireless");
  return [...tags].join(", ");
}

const classified = products.map((product) => {
  const result = classify(product);
  const brand = detectBrand(product);
  const colour = detectColour(product);
  const compatibility = result.category === "Phone Cases" ? detectPhoneModel(product)
    : result.category === "Tablet Cases" ? detectTabletCompatibility(product)
      : result.category === "Watch Accessories" ? (product.name.match(/\b(?:38\/40|40\/41|41\/45|42\/44|42\/44\/45|44\/45|49)\b/i)?.[0] || "")
        : cleanWhitespace(product.device);
  const productType = result.productType || detectProductType(product.category, result.subcategory, product.name);
  const skuCount = product.sku ? (duplicateSkuCounts.get(product.sku.toLowerCase()) || 1) : 0;
  const skuStatus = !product.sku ? "Missing" : skuCount > 1 ? `Duplicate (${skuCount})` : "Unique";
  const cost = numberValue(product.cost);
  const retail = numberValue(product.retail);
  const stock = numberValue(product.stock);
  const costStatus = cost > 0 ? "Entered" : "Zero";
  const priceStatus = retail > 0 ? "Entered" : "Zero";
  const stockStatus = stock < 0 ? "Negative" : stock === 0 ? "Zero" : "Positive";
  const dataNotes = [];
  if (skuStatus === "Missing") dataNotes.push("Missing SKU");
  if (skuStatus.startsWith("Duplicate")) dataNotes.push(`SKU shared by ${skuCount} products`);
  if (cost === 0) dataNotes.push("Cost is zero");
  if (retail === 0) dataNotes.push("Retail price is zero");
  if (stock < 0) dataNotes.push("Negative stock");
  if (product.pos === "NO") dataNotes.push("Currently hidden in source POS");
  if (result.reviewReason) dataNotes.unshift(result.reviewReason);

  let onlineTreatment = "Eligible after data review";
  if (result.category === "POS System Items") onlineTreatment = "Hide from website";
  if (result.category === "Exclude") onlineTreatment = "Do not publish";
  if (result.status === "Manual check") onlineTreatment = "Hold until confirmed";
  if (genericPhoneCaseIds.has(product.id) || product.id === "7159") onlineTreatment = "POS-only until model confirmed";

  let action = result.action || "Keep in the proposed category.";
  if (result.status === "Classified" && (skuStatus !== "Unique" || cost === 0)) {
    action = skuStatus !== "Unique" ? "Correct SKU before any future migration." : "Enter cost before profit reporting.";
  }

  return {
    ...product,
    newCategory: result.category,
    newSubcategory: result.subcategory,
    brand,
    compatibility,
    productType,
    colour,
    tags: collectionTags(product, result, brand),
    skuStatus,
    cost,
    costStatus,
    retail,
    priceStatus,
    stock,
    stockStatus,
    onlineTreatment,
    classificationStatus: result.status || "Classified",
    notes: dataNotes.join("; "),
    action,
  };
});

classified.sort((a, b) => {
  const categoryDelta = categoryOrder.indexOf(a.newCategory) - categoryOrder.indexOf(b.newCategory);
  if (categoryDelta) return categoryDelta;
  return a.newSubcategory.localeCompare(b.newSubcategory)
    || a.brand.localeCompare(b.brand)
    || a.compatibility.localeCompare(b.compatibility, undefined, { numeric: true })
    || a.name.localeCompare(b.name, undefined, { numeric: true });
});

const manualReview = classified.filter((row) => row.classificationStatus !== "Classified");
const qualityIssues = classified.filter((row) => row.skuStatus !== "Unique" || row.costStatus === "Zero" || row.priceStatus === "Zero" || row.stockStatus === "Negative");
const categoryCounts = new Map(categoryOrder.map((category) => [category, classified.filter((row) => row.newCategory === category).length]));
const sourceTotal = audit.files.reduce((sum, file) => sum + file.count, 0);

if (classified.length !== sourceTotal || classified.length !== audit.uniqueIds) {
  throw new Error(`Classification reconciliation failed: rows=${classified.length}, source=${sourceTotal}, uniqueIds=${audit.uniqueIds}`);
}
if ([...categoryCounts.values()].reduce((sum, count) => sum + count, 0) !== classified.length) {
  throw new Error("Category count reconciliation failed.");
}

const workbook = Workbook.create();
const overview = workbook.worksheets.add("Overview");
const productSheet = workbook.worksheets.add("Classified Products");
const manualSheet = workbook.worksheets.add("Manual Review");
const qualitySheet = workbook.worksheets.add("Data Quality Issues");
const rulesSheet = workbook.worksheets.add("Category Rules");

for (const sheet of [overview, productSheet, manualSheet, qualitySheet, rulesSheet]) sheet.showGridLines = false;

const dark = "#17343B";
const teal = "#008F7A";
const paleTeal = "#E7F5F1";
const paleBlue = "#EAF2F8";
const paleAmber = "#FFF4D6";
const paleRed = "#FDE9E7";
const line = "#D7E1E5";
const text = "#23343B";

overview.getRange("A1:H2").merge();
overview.getRange("A1").values = [["TechM8 Product Category Review"]];
overview.getRange("A1:H2").format = { fill: dark, font: { bold: true, color: "#FFFFFF", size: 20 }, verticalAlignment: "center" };
overview.getRange("A3:H3").merge();
overview.getRange("A3").values = [["Classification only. No product has been imported into POS, Supabase or the website."]];
overview.getRange("A3:H3").format = { fill: paleAmber, font: { bold: true, color: "#6F4B00" }, verticalAlignment: "center" };
overview.getRange("A5:B5").values = [["Control Check", "Result"]];
overview.getRange("A6:A14").values = [
  ["Source products"],
  ["Unique Item IDs"],
  ["Classified rows"],
  ["Manual/system review rows"],
  ["Missing SKU"],
  ["Products using duplicate SKU"],
  ["Zero cost"],
  ["Zero retail price"],
  ["Negative stock"],
];
const productEnd = classified.length + 1;
overview.getRange("B6:B14").formulas = [
  [`=COUNTA('Classified Products'!A2:A${productEnd})`],
  [`=COUNTA('Classified Products'!A2:A${productEnd})`],
  [`=COUNTA('Classified Products'!D2:D${productEnd})`],
  [`=COUNTIF('Classified Products'!U2:U${productEnd},"<>Classified")`],
  [`=COUNTIF('Classified Products'!L2:L${productEnd},"Missing")`],
  [`=COUNTA('Classified Products'!L2:L${productEnd})-COUNTIF('Classified Products'!L2:L${productEnd},"Unique")-COUNTIF('Classified Products'!L2:L${productEnd},"Missing")`],
  [`=COUNTIF('Classified Products'!N2:N${productEnd},"Zero")`],
  [`=COUNTIF('Classified Products'!P2:P${productEnd},"Zero")`],
  [`=COUNTIF('Classified Products'!R2:R${productEnd},"Negative")`],
];
overview.getRange("A5:B5").format = { fill: teal, font: { bold: true, color: "#FFFFFF" } };
overview.getRange("A6:A14").format.font = { bold: true, color: text };
overview.getRange("A5:B14").format.borders = { preset: "all", style: "thin", color: line };
overview.getRange("B6:B14").format.numberFormat = "#,##0";

overview.getRange("D5:H5").merge();
overview.getRange("D5").values = [["How to use this workbook"]];
overview.getRange("D5:H5").format = { fill: teal, font: { bold: true, color: "#FFFFFF" } };
overview.getRange("D6:H14").merge();
overview.getRange("D6").values = [[
  "Start with Manual Review for ambiguous and system-only records. Use Classified Products to filter by proposed category, subcategory, device compatibility, SKU status or cost status. Data Quality Issues contains products whose commercial data must be cleaned separately from classification. Category Rules defines the final POS and website logic.",
]];
overview.getRange("D6:H14").format = { fill: paleTeal, font: { color: "#164D43" }, wrapText: true, verticalAlignment: "top" };

overview.getRange("A16:F16").values = [["Sort", "Proposed Category", "Product Count", "POS Entry", "Website Collection", "Classification Rule"]];
overview.getRange("A17:F28").values = categoryDefinitions.map((row) => [row[0], row[1], categoryCounts.get(row[1]) || 0, row[2], row[3], row[5]]);
overview.tables.add("A16:F28", true, "CategorySummary");
overview.getRange("A16:F16").format = { fill: dark, font: { bold: true, color: "#FFFFFF" }, wrapText: true };
overview.getRange("A17:F28").format.verticalAlignment = "top";
overview.getRange("D17:F28").format.wrapText = true;
overview.getRange("A:A").format.columnWidth = 30;
overview.getRange("B:B").format.columnWidth = 28;
overview.getRange("C:C").format.columnWidth = 16;
overview.getRange("D:E").format.columnWidth = 32;
overview.getRange("F:F").format.columnWidth = 54;
overview.getRange("G:H").format.columnWidth = 12;
overview.freezePanes.freezeRows(3);

const productHeaders = [
  "Item ID", "Product Name", "Existing Category", "New Category", "New Subcategory", "Brand / Platform",
  "Device / Compatibility", "Product Type", "Colour", "Collections / Search Tags", "SKU", "SKU Status",
  "Cost Price", "Cost Status", "Retail Price", "Price Status", "On Hand Qty", "Stock Status",
  "Source POS Visibility", "Online Treatment", "Classification Status", "Review / Data Notes",
  "Recommended Action", "Source File", "Source Row",
];
productSheet.getRange("A1:Y1").values = [productHeaders];
productSheet.getRange(`A2:A${productEnd}`).format.numberFormat = "@";
productSheet.getRange(`K2:K${productEnd}`).format.numberFormat = "@";
productSheet.getRange(`A2:Y${productEnd}`).values = classified.map((row) => [
  row.id, row.name, row.category, row.newCategory, row.newSubcategory, row.brand, row.compatibility,
  row.productType, row.colour, row.tags, identifierValue(row.sku), row.skuStatus, row.cost, row.costStatus,
  row.retail, row.priceStatus, row.stock, row.stockStatus, row.pos, row.onlineTreatment,
  row.classificationStatus, row.notes, row.action, row.source, row.sourceRow,
]);
productSheet.getRange(`K2:K${productEnd}`).formulas = classified.map((row) => [identifierFormula(row.sku)]);
productSheet.tables.add(`A1:Y${productEnd}`, true, "ClassifiedProductReview");
productSheet.freezePanes.freezeRows(1);
productSheet.freezePanes.freezeColumns(2);
productSheet.getRange("A1:Y1").format = { fill: teal, font: { bold: true, color: "#FFFFFF" }, wrapText: true, verticalAlignment: "center" };
productSheet.getRange(`A2:Y${productEnd}`).format.verticalAlignment = "top";
productSheet.getRange(`B2:J${productEnd}`).format.wrapText = true;
productSheet.getRange(`T2:W${productEnd}`).format.wrapText = true;
productSheet.getRange(`A2:A${productEnd}`).format.numberFormat = "@";
productSheet.getRange(`K2:K${productEnd}`).format.numberFormat = "@";
productSheet.getRange(`M2:M${productEnd}`).format.numberFormat = "$#,##0.00";
productSheet.getRange(`O2:O${productEnd}`).format.numberFormat = "$#,##0.00";
productSheet.getRange(`Q2:Q${productEnd}`).format.numberFormat = "#,##0.00";
productSheet.getRange(`Y2:Y${productEnd}`).format.numberFormat = "#,##0";
productSheet.getRange(`L2:L${productEnd}`).conditionalFormats.add("containsText", { text: "Missing", format: { fill: paleRed, font: { bold: true, color: "#A52A21" } } });
productSheet.getRange(`L2:L${productEnd}`).conditionalFormats.add("beginsWith", { text: "Duplicate", format: { fill: paleAmber, font: { bold: true, color: "#805A00" } } });
productSheet.getRange(`U2:U${productEnd}`).conditionalFormats.add("containsText", { text: "Manual check", format: { fill: paleAmber, font: { bold: true, color: "#805A00" } } });
productSheet.getRange(`U2:U${productEnd}`).conditionalFormats.add("containsText", { text: "Exclude", format: { fill: paleRed, font: { bold: true, color: "#A52A21" } } });
productSheet.getRange(`U2:U${productEnd}`).conditionalFormats.add("containsText", { text: "System only", format: { fill: paleBlue, font: { bold: true, color: "#24506B" } } });
productSheet.getRange("A:A").format.columnWidth = 13;
productSheet.getRange("B:B").format.columnWidth = 44;
productSheet.getRange("C:C").format.columnWidth = 42;
productSheet.getRange("D:E").format.columnWidth = 27;
productSheet.getRange("F:F").format.columnWidth = 22;
productSheet.getRange("G:G").format.columnWidth = 34;
productSheet.getRange("H:J").format.columnWidth = 24;
productSheet.getRange("K:L").format.columnWidth = 18;
productSheet.getRange("M:R").format.columnWidth = 15;
productSheet.getRange("S:U").format.columnWidth = 22;
productSheet.getRange("V:W").format.columnWidth = 52;
productSheet.getRange("X:X").format.columnWidth = 24;
productSheet.getRange("Y:Y").format.columnWidth = 12;

const reviewHeaders = ["Item ID", "Product Name", "Existing Category", "New Category", "New Subcategory", "Status", "Reason", "Recommended Action", "SKU", "Cost", "Retail", "Stock", "Online Treatment", "Source File", "Source Row"];
const reviewEnd = manualReview.length + 1;
manualSheet.getRange("A1:O1").values = [reviewHeaders];
manualSheet.getRange(`A2:A${reviewEnd}`).format.numberFormat = "@";
manualSheet.getRange(`I2:I${reviewEnd}`).format.numberFormat = "@";
manualSheet.getRange(`A2:O${reviewEnd}`).values = manualReview.map((row) => [
  row.id, row.name, row.category, row.newCategory, row.newSubcategory, row.classificationStatus,
  row.notes, row.action, identifierValue(row.sku), row.cost, row.retail, row.stock, row.onlineTreatment, row.source, row.sourceRow,
]);
manualSheet.getRange(`I2:I${reviewEnd}`).formulas = manualReview.map((row) => [identifierFormula(row.sku)]);
manualSheet.tables.add(`A1:O${reviewEnd}`, true, "ManualCategoryReview");
manualSheet.freezePanes.freezeRows(1);
manualSheet.getRange("A1:O1").format = { fill: "#B57400", font: { bold: true, color: "#FFFFFF" }, wrapText: true };
manualSheet.getRange(`A2:O${reviewEnd}`).format.verticalAlignment = "top";
manualSheet.getRange(`B2:H${reviewEnd}`).format.wrapText = true;
manualSheet.getRange(`A2:A${reviewEnd}`).format.numberFormat = "@";
manualSheet.getRange(`I2:I${reviewEnd}`).format.numberFormat = "@";
manualSheet.getRange(`J2:K${reviewEnd}`).format.numberFormat = "$#,##0.00";
manualSheet.getRange(`L2:L${reviewEnd}`).format.numberFormat = "#,##0.00";
manualSheet.getRange("A:A").format.columnWidth = 13;
manualSheet.getRange("B:B").format.columnWidth = 42;
manualSheet.getRange("C:E").format.columnWidth = 30;
manualSheet.getRange("F:F").format.columnWidth = 18;
manualSheet.getRange("G:H").format.columnWidth = 54;
manualSheet.getRange("I:M").format.columnWidth = 18;
manualSheet.getRange("N:N").format.columnWidth = 24;
manualSheet.getRange("O:O").format.columnWidth = 12;

const qualityHeaders = ["Item ID", "Product Name", "New Category", "New Subcategory", "SKU", "SKU Status", "Cost", "Retail", "Stock", "Data Issues", "Recommended Action", "Source File", "Source Row"];
const qualityEnd = qualityIssues.length + 1;
qualitySheet.getRange("A1:M1").values = [qualityHeaders];
qualitySheet.getRange(`A2:A${qualityEnd}`).format.numberFormat = "@";
qualitySheet.getRange(`E2:E${qualityEnd}`).format.numberFormat = "@";
qualitySheet.getRange(`A2:M${qualityEnd}`).values = qualityIssues.map((row) => [
  row.id, row.name, row.newCategory, row.newSubcategory, identifierValue(row.sku), row.skuStatus,
  row.cost, row.retail, row.stock, row.notes, row.action, row.source, row.sourceRow,
]);
qualitySheet.getRange(`E2:E${qualityEnd}`).formulas = qualityIssues.map((row) => [identifierFormula(row.sku)]);
qualitySheet.tables.add(`A1:M${qualityEnd}`, true, "ProductDataQualityIssues");
qualitySheet.freezePanes.freezeRows(1);
qualitySheet.getRange("A1:M1").format = { fill: "#B57400", font: { bold: true, color: "#FFFFFF" }, wrapText: true };
qualitySheet.getRange(`A2:M${qualityEnd}`).format.verticalAlignment = "top";
qualitySheet.getRange(`B2:D${qualityEnd}`).format.wrapText = true;
qualitySheet.getRange(`J2:K${qualityEnd}`).format.wrapText = true;
qualitySheet.getRange(`A2:A${qualityEnd}`).format.numberFormat = "@";
qualitySheet.getRange(`E2:F${qualityEnd}`).format.numberFormat = "@";
qualitySheet.getRange(`G2:H${qualityEnd}`).format.numberFormat = "$#,##0.00";
qualitySheet.getRange(`I2:I${qualityEnd}`).format.numberFormat = "#,##0.00";
qualitySheet.getRange("A:A").format.columnWidth = 13;
qualitySheet.getRange("B:B").format.columnWidth = 44;
qualitySheet.getRange("C:D").format.columnWidth = 28;
qualitySheet.getRange("E:F").format.columnWidth = 19;
qualitySheet.getRange("G:I").format.columnWidth = 15;
qualitySheet.getRange("J:K").format.columnWidth = 52;
qualitySheet.getRange("L:L").format.columnWidth = 24;
qualitySheet.getRange("M:M").format.columnWidth = 12;

rulesSheet.getRange("A1:F1").values = [["Sort", "Main Category", "Recommended Subcategories", "POS Navigation", "Website Collections", "Rule / Boundary"]];
rulesSheet.getRange("A2:F13").values = categoryDefinitions.map((row) => row);
rulesSheet.tables.add("A1:F13", true, "CategoryRuleReference");
rulesSheet.freezePanes.freezeRows(1);
rulesSheet.getRange("A1:F1").format = { fill: dark, font: { bold: true, color: "#FFFFFF" }, wrapText: true };
rulesSheet.getRange("A2:F13").format = { verticalAlignment: "top", wrapText: true };
rulesSheet.getRange("A:A").format.columnWidth = 10;
rulesSheet.getRange("B:B").format.columnWidth = 28;
rulesSheet.getRange("C:E").format.columnWidth = 40;
rulesSheet.getRange("F:F").format.columnWidth = 64;

await fs.mkdir(previewDir, { recursive: true });

const summaryInspection = await workbook.inspect({
  kind: "table",
  sheetId: "Overview",
  range: "A1:H28",
  include: "values,formulas",
  tableMaxRows: 30,
  tableMaxCols: 8,
  maxChars: 10000,
});
const productInspection = await workbook.inspect({
  kind: "table",
  sheetId: "Classified Products",
  range: "A1:Y12",
  include: "values,formulas",
  tableMaxRows: 12,
  tableMaxCols: 25,
  maxChars: 10000,
});
const formulaErrors = await workbook.inspect({
  kind: "match",
  searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
  options: { useRegex: true, maxResults: 200 },
  summary: "final formula error scan",
});

for (const [sheetName, range, fileName] of [
  ["Overview", "A1:H28", "overview.png"],
  ["Classified Products", "A1:Y25", "classified-products.png"],
  ["Manual Review", `A1:O${Math.min(reviewEnd, 32)}`, "manual-review.png"],
  ["Data Quality Issues", `A1:M${Math.min(qualityEnd, 28)}`, "data-quality.png"],
  ["Category Rules", "A1:F13", "category-rules.png"],
]) {
  const preview = await workbook.render({ sheetName, range, scale: 1, format: "png" });
  await fs.writeFile(path.join(previewDir, fileName), new Uint8Array(await preview.arrayBuffer()));
}

const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(outputPath);

const validation = {
  sourceTotal,
  uniqueIds: audit.uniqueIds,
  classifiedTotal: classified.length,
  categoryTotal: [...categoryCounts.values()].reduce((sum, count) => sum + count, 0),
  manualReview: manualReview.length,
  dataQualityIssues: qualityIssues.length,
  categories: Object.fromEntries(categoryCounts),
  inspections: {
    summary: summaryInspection.ndjson,
    productSample: productInspection.ndjson,
    formulaErrors: formulaErrors.ndjson,
  },
};
await fs.writeFile(path.join(outputDir, "validation.json"), JSON.stringify(validation, null, 2), "utf8");

console.log(JSON.stringify({ outputPath, previewDir, ...validation, inspections: undefined }, null, 2));
