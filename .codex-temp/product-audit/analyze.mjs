import fs from "node:fs/promises";
import path from "node:path";
import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const files = process.argv.slice(2);
const allRows = [];
const fileStats = [];
let headers = [];

const clean = (value) => {
  if (value === null || value === undefined) return "";
  const text = String(value).trim();
  return text === "77" ? "" : text;
};

for (const file of files) {
  const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(file));
  const sheet = workbook.worksheets.getItemAt(0);
  const values = sheet.getUsedRange(true).values;
  if (!headers.length) headers = values[0].map((value) => String(value ?? "").trim());

  let count = 0;
  for (let rowIndex = 2; rowIndex < values.length; rowIndex += 1) {
    const valuesRow = values[rowIndex];
    if (!valuesRow || valuesRow.every((value) => value === null || value === "")) continue;
    const row = Object.fromEntries(headers.map((header, index) => [header, clean(valuesRow[index])]));
    row.__file = path.basename(file);
    row.__row = rowIndex + 1;
    allRows.push(row);
    count += 1;
  }
  fileStats.push({ file: path.basename(file), count });
}

const groupBy = (rows, keyFn) => {
  const grouped = new Map();
  for (const row of rows) {
    const key = keyFn(row);
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(row);
  }
  return grouped;
};

const summarizeGroups = (grouped, includeExamples = false) =>
  [...grouped.entries()]
    .map(([key, rows]) => ({
      key,
      count: rows.length,
      ...(includeExamples
        ? { examples: rows.slice(0, 8).map((row) => ({ id: row["Item ID"], name: row["Item Name"], sku: row.SKU })) }
        : {}),
    }))
    .sort((a, b) => b.count - a.count || a.key.localeCompare(b.key));

const byId = groupBy(allRows.filter((row) => row["Item ID"]), (row) => row["Item ID"]);
const bySku = groupBy(allRows.filter((row) => row.SKU), (row) => row.SKU.toLowerCase());
const byUpc = groupBy(allRows.filter((row) => row.UPC), (row) => row.UPC.toLowerCase());
const categories = groupBy(allRows, (row) => row.Category || "(blank)");
const roots = groupBy(allRows, (row) => (row.Category || "(blank)").split(">")[0].trim());

const duplicateGroups = (grouped) =>
  [...grouped.entries()]
    .filter(([, rows]) => rows.length > 1)
    .map(([key, rows]) => ({
      key,
      rows: rows.map((row) => ({ file: row.__file, row: row.__row, id: row["Item ID"], name: row["Item Name"], category: row.Category })),
    }));

const blankCounts = {};
for (const field of [
  "Item ID",
  "Category",
  "Item Name",
  "Manufacturer",
  "Device",
  "SKU",
  "UPC",
  "Cost Price",
  "Retail Price",
  "Size",
  "Color",
  "Condition",
  "Online Price",
  "Display On Point of Sale",
]) {
  blankCounts[field] = allRows.filter((row) => !row[field]).length;
}

const keywordRules = {
  cables: /\b(cable|hdmi|displayport|\bdp\b|ethernet|lightning|type[- ]?c|usb[- ]?[ac]|otg)\b/i,
  hubsAdapters: /\b(hub|dock|adapter|adaptor|converter|dongle)\b/i,
  chargersPower: /\b(charger|charging|power bank|magsafe)\b/i,
  cases: /\b(case|cover|sleeve|bag)\b/i,
  screenProtection: /\b(screen protector|tempered glass|glass screen|camera lens protector)\b/i,
  audio: /\b(headphone|headset|earphone|earbud|speaker|microphone|tws)\b/i,
  mountsHolders: /\b(holder|stand|mount|pop socket|popsocket)\b/i,
  watch: /\b(watch band|watch strap|apple watch band)\b/i,
  computerParts: /\b(cpu|ram|power suppl|graphics card|gpu|hard drive|ssd|cooling|pc case|motherboard)\b/i,
  gaming: /\b(gaming|controller|console|playstation|ps5|xbox|simulator|cockpit)\b/i,
  car: /\b(car |carplay|fm transmitter|vehicle)\b/i,
  repairParts: /\b(repair part|replacement part|lcd|battery|charging port|screen assembly)\b/i,
};

const keywordStats = {};
for (const [name, regex] of Object.entries(keywordRules)) {
  const rows = allRows.filter((row) => regex.test(`${row["Item Name"]} ${row.Category}`));
  keywordStats[name] = {
    count: rows.length,
    categoryRoots: summarizeGroups(groupBy(rows, (row) => (row.Category || "(blank)").split(">")[0].trim())).slice(0, 12),
    examples: rows.slice(0, 20).map((row) => ({ id: row["Item ID"], name: row["Item Name"], category: row.Category })),
  };
}

const result = {
  files: fileStats,
  headers,
  totalRows: allRows.length,
  uniqueIds: byId.size,
  uniqueSkus: bySku.size,
  uniqueUpcs: byUpc.size,
  duplicateIds: duplicateGroups(byId),
  duplicateSkus: duplicateGroups(bySku),
  duplicateUpcs: duplicateGroups(byUpc),
  blankCounts,
  rootCategories: summarizeGroups(roots, true),
  categoryPaths: summarizeGroups(categories, true),
  keywordStats,
  products: allRows.map((row) => ({
    id: row["Item ID"],
    category: row.Category,
    name: row["Item Name"],
    manufacturer: row.Manufacturer,
    device: row.Device,
    sku: row.SKU,
    upc: row.UPC,
    cost: row["Cost Price"],
    retail: row["Retail Price"],
    stock: row["On Hand Qty"],
    pos: row["Display On Point of Sale"],
    source: row.__file,
    sourceRow: row.__row,
  })),
};

await fs.writeFile("audit.json", JSON.stringify(result, null, 2), "utf8");
console.log(JSON.stringify({
  files: result.files,
  headers: result.headers,
  totalRows: result.totalRows,
  uniqueIds: result.uniqueIds,
  uniqueSkus: result.uniqueSkus,
  uniqueUpcs: result.uniqueUpcs,
  duplicateIdGroups: result.duplicateIds.length,
  duplicateSkuGroups: result.duplicateSkus.length,
  duplicateUpcGroups: result.duplicateUpcs.length,
  blankCounts: result.blankCounts,
  rootCategories: result.rootCategories,
  categoryPathCount: result.categoryPaths.length,
}, null, 2));
