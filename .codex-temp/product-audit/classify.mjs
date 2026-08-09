import fs from "node:fs/promises";

const audit = JSON.parse(await fs.readFile("audit.json", "utf8"));
const products = audit.products;

const includes = (value, pattern) => pattern.test(value || "");

function classify(product) {
  const category = product.category || "";
  const name = product.name || "";

  if (category === "Uncategorized") {
    if (["10291", "8416", "6769", "6021", "5957"].includes(product.id)) return ["POS Services & Adjustments", "Special POS Items"];
    if (product.id === "10054") return ["POS Services & Adjustments", "Gaming Services"];
    if (["8633", "8632"].includes(product.id)) return ["POS Services & Adjustments", "Packaging"];
    if (product.id === "5934") return ["POS Services & Adjustments", "SIM & Mobile Services"];
    if (["8974", "8412", "8411", "7763"].includes(product.id)) return ["Mounts, Holders & Grips", "Straps & Grips"];
    if (product.id === "6806") return ["Cases", "Watch Cases"];
    if (product.id === "5995") return ["Computer Hardware & Peripherals", "Input Devices"];
    if (["6062", "6061"].includes(product.id)) return ["Lifestyle Electronics", "Lighting & Clocks"];
    return ["Needs Review", "Unclassified"];
  }

  if (category.startsWith("1. Phone Cables")) {
    return includes(name, /otg|adapter|convert|card reader/i)
      ? ["Cables & Adapters", "Adapters & OTG"]
      : ["Cables & Adapters", "Charging & Data Cables"];
  }

  if (category.startsWith("2. Charger")) {
    if (category.includes("Car Charger")) return ["Charging & Power", "Car Chargers"];
    if (category.includes("MacBook Charger")) return ["Charging & Power", "Laptop Chargers"];
    if (category.includes("Wall Charger")) return ["Charging & Power", "Wall Chargers"];
    if (category.includes("Wireless Charger")) return ["Charging & Power", "Wireless Chargers"];
    return ["Charging & Power", "Other Chargers"];
  }

  if (category === "3. Screen Protector") return ["Screen Protection", "Screen Protectors"];

  if (category.startsWith("4. Car FM")) {
    if (category.includes("Car Holder") || includes(name, /holder|mount|metal plate/i)) return ["Mounts, Holders & Grips", "Vehicle Mounts"];
    return ["Cables & Adapters", "Car Connectivity"];
  }

  if (category.startsWith("5. Phone Cases")) {
    if (category.includes("Air Pods") || includes(name, /earbud.*(case|pouch)|airpods.*case/i)) return ["Cases", "Earbud Cases"];
    if (category.includes("Air Tag") || includes(name, /air\s?tag.*(case|holder|cover)/i)) return ["Cases", "Tracker Cases"];
    return ["Cases", "Phone Cases"];
  }

  if (category.startsWith("6. iPad & Tablet Cases")) return ["Cases", "Tablet Cases"];
  if (category === "7. Power Bank") return ["Charging & Power", "Power Banks"];

  if (category.startsWith("8. Headphones")) {
    if (category.includes("Headphones Adapter")) return ["Cables & Adapters", "Audio Adapters"];
    if (category.includes("Line Headphones")) return ["Audio", "Wired Earphones & Headphones"];
    return ["Audio", "Wireless Earbuds & Headphones"];
  }

  if (category === "9. Holder, Stand, Fans") {
    if (includes(name, /\bfan\b|fans|neckband fan/i)) return ["Lifestyle Electronics", "Personal Fans"];
    if (includes(name, /selfie|live stream/i)) return ["Mounts, Holders & Grips", "Selfie Sticks & Live Stands"];
    if (includes(name, /laptop/i)) return ["Mounts, Holders & Grips", "Laptop Stands"];
    return ["Mounts, Holders & Grips", "Phone & Tablet Stands"];
  }

  if (category.startsWith("9.1 Watch Band")) return ["Watch Bands", "Watch Bands"];
  if (category === "9.2 Speaker") return ["Audio", "Speakers"];

  if (category.startsWith("9.3 Computer & Console Products")) {
    if (category.includes("Computer Cables")) return ["Cables & Adapters", "AV, Network & Computer Cables"];
    if (category.includes("Computer Hub")) return ["Cables & Adapters", "Hubs & Docks"];
    if (category.includes("Headset")) return ["Audio", "Headsets"];
    if (category.includes("Microphones")) return ["Audio", "Microphones"];
    if (category.includes("Wire Speaker")) return ["Audio", "Speakers"];
    if (category.includes("Laptop Bag")) return ["Cases", "Laptop Bags & Sleeves"];
    if (category.includes("Monitor mounts")) return ["Mounts, Holders & Grips", "Monitor Mounts"];
    if (category.includes("Consoles & Accessories")) return ["Gaming & Simulation", "Consoles & Controllers"];
    if (category.includes("Racing Simulator")) return ["Gaming & Simulation", "Simulation Equipment"];
    if (category.includes("Hard Drive") || category.includes("SD Card") || category.endsWith("> USB")) return ["Computer Hardware & Peripherals", "Storage"];
    if (category.includes("Keyboard") || category.includes("Mouse") || category.includes("Office combo") || category.includes("Webcams")) return ["Computer Hardware & Peripherals", "Input & Office Peripherals"];
    if (category.includes("Wireless Adapter")) return ["Computer Hardware & Peripherals", "Networking"];
    return ["Computer Hardware & Peripherals", "PC Components"];
  }

  if (category.startsWith("9.4 Gaming Chair")) return ["Gaming & Simulation", "Simulation Furniture"];

  if (category.startsWith("Card Holder & Pop Scoket")) {
    if (includes(name, /earbud.*pouch/i)) return ["Cases", "Earbud Cases"];
    return ["Mounts, Holders & Grips", "Wallets, Card Holders & Grips"];
  }

  if (category === "Drone") {
    if (includes(name, /^lcd frame$/i)) return ["Exclude", "Repair/Obsolete Item"];
    return ["Lifestyle Electronics", "Drones & Accessories"];
  }

  return ["Needs Review", "Unclassified"];
}

const classified = products.map((product) => {
  const [root, subcategory] = classify(product);
  return { ...product, proposedRoot: root, proposedSubcategory: subcategory };
});

const countBy = (rows, keyFn) =>
  [...rows.reduce((map, row) => {
    const key = keyFn(row);
    map.set(key, (map.get(key) || 0) + 1);
    return map;
  }, new Map())]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || a.key.localeCompare(b.key));

const report = {
  total: classified.length,
  proposedRoots: countBy(classified, (row) => row.proposedRoot),
  proposedPaths: countBy(classified, (row) => `${row.proposedRoot} > ${row.proposedSubcategory}`),
  needsReview: classified.filter((row) => row.proposedRoot === "Needs Review"),
  excluded: classified.filter((row) => row.proposedRoot === "Exclude"),
  services: classified.filter((row) => row.proposedRoot === "POS Services & Adjustments"),
};

await fs.writeFile("classification-simulation.json", JSON.stringify(report, null, 2), "utf8");
console.log(JSON.stringify(report, null, 2));
