// Collection pages embed their product list in the Next.js flight stream
// (self.__next_f). Each variant carries every business tier price and the
// exact warehouse stock, so prices are read from data, not rendered text.

function failure(message, code) {
  const error = new Error(message);
  error.code = code;
  return error;
}

// Returns the JSON value that starts at `start` without parsing the rest of the stream.
function sliceJsonValue(text, start) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < text.length; index += 1) {
    const char = text[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') inString = false;
    } else if (char === '"') {
      inString = true;
    } else if (char === '[' || char === '{') {
      depth += 1;
    } else if (char === ']' || char === '}') {
      depth -= 1;
      if (depth === 0) return text.slice(start, index + 1);
    }
  }
  return null;
}

function numberAfter(text, key, from) {
  const match = new RegExp(`"${key}":(\\d+)`).exec(text.slice(from, from + 2000));
  return match ? Number(match[1]) : null;
}

export function readEmbeddedCollection(flightText) {
  const marker = flightText.indexOf('"initialItems":');
  if (marker < 0) return null;
  const start = flightText.indexOf('[', marker);
  const json = start >= 0 ? sliceJsonValue(flightText, start) : null;
  if (!json) return null;
  const items = JSON.parse(json);
  const end = start + json.length;
  return {
    items,
    total: numberAfter(flightText, 'initialTotal', end),
    perPage: numberAfter(flightText, 'perPage', end),
  };
}

// Matches the site's own labels: 0 is out of stock, 1-10 low stock, 11+ in stock.
export function stockLabel(count) {
  if (!Number.isFinite(count) || count <= 0) return 'Out of Stock';
  return count <= 10 ? 'Low Stock' : 'In Stock';
}

function branchCount(inventory, code) {
  const branch = (inventory || []).find((entry) => String(entry.branch_code || '').toLowerCase() === code);
  return branch ? Number(branch.inventory) : 0;
}

// hrefByVariant maps variant ids to the product links rendered on the page.
export function productsFromCollection(collection, tierKey, hrefByVariant = {}) {
  if (!tierKey) throw failure('memberTierPriceKey is missing from the Crazy Parts config.', 'CRAZYPARTS_TIER_MISMATCH');
  const products = [];
  for (const item of collection.items) {
    const variants = item.variants || [];
    for (const variant of variants) {
      const tierPrices = variant.business_account_price_ex_tax;
      if (!tierPrices || typeof tierPrices !== 'object') {
        throw failure(`Crazy Parts page data has no business prices for ${item.name}. The site data may have changed.`, 'CRAZYPARTS_PRICES_UNAVAILABLE');
      }
      const memberPrice = Number(tierPrices[tierKey]);
      const inventory = Array.isArray(variant.branch_inventory) ? variant.branch_inventory : item.branch_inventory;
      const retailPrice = Number(variant.retail_price_ex_tax);
      products.push({
        title: String((variants.length > 1 ? variant.title || variant.name : item.name) || '').trim(),
        href: hrefByVariant[variant.id] || `/product/${item.id}?variant_id=${variant.id}`,
        variantId: variant.id,
        imageUrl: variant.images?.[0]?.url || item.images?.[0]?.url || null,
        memberPrice: Number.isFinite(memberPrice) && memberPrice > 0 ? memberPrice : null,
        retailPrice: Number.isFinite(retailPrice) && retailPrice > 0 ? retailPrice : null,
        // Promotions (for example "Parts Clearance 70% OFF") discount the tier
        // price on screen without storing the result, so the caller reads those.
        promotional: Number(variant.promotion_id) > 0,
        syd: `SYD:${stockLabel(branchCount(inventory, 'syd'))}`,
        mel: `MEL:${stockLabel(branchCount(inventory, 'mel'))}`,
      });
    }
  }
  return products;
}
