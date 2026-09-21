# Used Devices on the Public Website

Everything the storefront needs to show second-hand devices. Nothing in this
document requires the staff portal: the website reads two functions with the
public key and renders the result.

The POS owns the device. This project owns the listing. A device appears here
only once staff have marked it ready for sale and it has at least one listing
photo, and it disappears the moment it is sold or taken off the shelf. The
storefront does not have to poll or reconcile anything.

## Where it lives

- Project: `fwlronvmgqzkleofriis` (the same project as `products`)
- Tables: `used_device_categories`, `used_device_listings`
- Images: the public storage bucket `used-device-listing-images`
- Migrations: `supabase/website-migrations/20260911002000_add_used_device_listings.sql`,
  `supabase/website-migrations/20260921170000_sell_used_devices_in_the_shop.sql`

The listing is the record of what the public is told. Each published listing
also has a mirror row in `products` (`source_system = 'pos_used_device'`, SKU =
the device code), under the shop category Second Hand Devices / Used Phones (and
so on), so the shop, the cart and checkout treat it like any other product. It
is written only by `upsert_used_device_listing`; do not edit it in the product
admin. Two rules keep it one of a kind:

- its slug starts with `used-`. The cart and both checkout functions read that
  as "one only";
- an order holds it. Checkout calls `claim_used_devices_for_order` once the
  order is saved, and reserves the device in the POS before the customer pays.
  Paid, being paid, or reserved to pay in store hides it from the shop. While
  the customer is only on the payment page it stays visible, and the same
  customer starting again replaces their old checkout (the old Stripe session
  is closed first, so nobody can pay twice). Anyone else is refused until the
  checkout lapses: the Stripe session expires after 30 minutes, the hold after 45.

## Where customers see it

The storefront pages live in the website repository and read this catalogue on every visit:

- the shop (`shop.html`) - Second Hand Devices in the category menu, each device a normal product card
- `used-devices.html` - the category list, `?category=used-phones` by default, with a tab per category
- `used-device.html?d=<slug>` - one device: its listing photos, brand, model, storage, colour,
  condition, battery (by the rule below), the device location, the price and Add to cart, with no
  quantity. `product.html?slug=used-...` sends the visitor here.

Nothing about them is prerendered, and they are left out of the sitemap and the Merchant Center feed,
because a device can sell at the counter at any moment.

## Reading the catalogue

Both calls are ordinary Supabase RPCs. Use the project's publishable
(anon) key, the same one the rest of the storefront already uses.

### List

```http
POST https://fwlronvmgqzkleofriis.supabase.co/rest/v1/rpc/get_used_device_listings
apikey: <publishable key>
Content-Type: application/json

{ "category_slug": "used-phones", "brand_filter": "Apple", "result_limit": 60, "result_offset": 0 }
```

Every argument is optional. Omit `category_slug` and `brand_filter` to get
everything. `result_limit` is capped at 200.

```jsonc
{
  "ok": true,
  "total": 14,
  "limit": 60,
  "offset": 0,
  "categories": [
    { "slug": "used-phones", "name": "Used Phones", "count": 9 },
    { "slug": "used-tablets", "name": "Used Tablets", "count": 2 }
    // ... always all six, so the nav does not change shape when a category empties
  ],
  "listings": [
    {
      "slug": "apple-iphone-13-128gb-blue-a1b2c3",
      "title": "Apple iPhone 13 128GB Blue",
      "brand": "Apple",
      "model": "iPhone 13",
      "storage": "128GB",
      "color": "Blue",
      "condition_grade": "Good",
      "condition_summary": "Good condition. Light signs of use.",
      "battery_health": 89,
      "price": 649.00,
      "description": "Good condition. Light signs of use.\n\nEvery second-hand device is tested in store ...",
      "highlights": [
        "21 of 21 inspection checks passed",
        "Battery health 89%",
        "128GB storage",
        "Wiped and reset, ready to set up",
        "No previous owner account attached",
        "In stock at Toowong"
      ],
      "images": [
        { "url": "https://fwlronvmgqzkleofriis.supabase.co/storage/v1/object/public/used-device-listing-images/USED-XXXX/1.jpg", "position": 1 }
      ],
      "published_at": "2026-09-11T02:14:00Z",
      "category_slug": "used-phones",
      "category_name": "Used Phones"
    }
  ]
}
```

### One device

```http
POST https://fwlronvmgqzkleofriis.supabase.co/rest/v1/rpc/get_used_device_listing
{ "listing_slug": "apple-iphone-13-128gb-blue-a1b2c3" }
```

Returns `{ "ok": true, "listing": { ... } }`, or `{ "ok": false, "message": "Listing not found" }`
when the slug is unknown **or the device has since sold**. Treat both the same
way: show a "no longer available" page, not an error. A sold device is a normal,
frequent outcome here, not a fault.

## Rendering notes

- `images` is ordered by `position`; the first is the main image. There is
  always at least one on a published listing — the database refuses to publish
  without one.
- `highlights` is a ready-made bullet list. It is generated from the actual
  inspection record, so its length varies. Render it as a list, do not assume a
  fixed count.
- `description` contains `\n\n` paragraph breaks and no markup.
- `price` is in AUD and includes GST, consistent with the rest of the site.
- `battery_health` is sent only when it is 85% or more. Below that it is null and the highlights carry
  "Good battery" instead, so the number never reaches the public site. It is also null for anything
  without a measurable battery. The storefront applies the same rule again as a safeguard.
- There is no inspection count in the highlights, and no "In stock at" line: the store comes as
  `store_code` and `store_name`, and the page shows it as the device location. The page drops either
  line from an older listing that still carries it.
- `product_id` and `sku` are the shop product, for the cart.
- Cache for minutes, not hours. A device can sell at the counter at any time,
  and the listing goes down within seconds of that happening.

## What is deliberately absent

A listing carries **no IMEI, no serial number, no seller detail, and no
purchase price**. That is not an oversight to be fixed by adding a field: it is
a rule enforced in three places, because a public page carrying a device
identifier or a seller's details is a real problem.

1. The POS builds the listing from a function that never reads those columns.
2. `used_device_listings` has a check constraint rejecting any run of fifteen
   digits in the title, description or condition summary.
3. The public read functions select an explicit column list. The store is
   public (it is where the device is), and so is the shop product's SKU, which
   is the internal stock code, not anything printed on the device.

If the storefront needs to identify a device for an enquiry form, use `slug`.

## How a listing gets here

Staff do not upload anything to this project. The chain is:

1. A staff member marks a device **ready for sale** in the POS. That requires a
   passed inspection, a clean lost-or-stolen check, and at least one listing
   photo.
2. The POS project queues a `publish` intention against the device.
3. `pos-used-device-publish` (an Edge Function in the staff project) copies the
   listing photos into this project's public bucket and calls
   `used-device-listings` here with a shared secret.
4. `upsert_used_device_listing` writes the row.

Price changes republish. Selling, returning to the seller, disposal, or moving
a device back to inspection withdraws it. The shop product follows the listing.

## Selling it online

1. Checkout saves the order, then `claim_used_devices_for_order` locks each
   device's listing and records the claim (`used_device_order_claims`). It
   refuses a second unit, a stale price, a sold listing, or a device another
   order holds.
2. The website calls `used-device-online-orders` in the staff project
   (`action: "hold"`, shared secret). The POS refuses a device that is no longer
   ready for sale or is held by another order; the website then deletes the order.
3. A card, Afterpay, Klarna, Zip or WeChat checkout goes to Stripe with a
   30-minute session. Pay in store is reserved until the order is paid or
   cancelled in the website admin.
4. Every five minutes while a device is reserved, the staff project asks
   `used-device-listings` (`action: "order-holds"`), which answers from
   `get_used_device_order_holds`, and applies it: paid is a sale in the POS,
   abandoned or cancelled frees the device, and the sale takes the listing down. Each intention carries a
`source_version`, and this project ignores anything older than what it already
holds, so a slow retry can never resurrect a sold device.

## Categories

Six fixed categories, keyed to the POS device types:

| slug | name | POS category |
| --- | --- | --- |
| `used-phones` | Used Phones | Phone |
| `used-tablets` | Used Tablets | Tablet |
| `used-laptops` | Used Laptops | Laptop |
| `used-watches` | Used Watches | Watch |
| `used-game-consoles` | Used Game Consoles | Game Console |
| `used-other` | Other Used Devices | Other |

Renaming a category is a `used_device_categories.name` update and needs no code
change. Changing a `slug` breaks existing links, so treat slugs as permanent.

## Marketing copy

The condition sentences and the closing paragraph are rows in
`pos_used_device_listing_copy` in the **staff** project, editable without a
migration. Changing them affects devices published after the change; existing
listings keep the text they were published with until they are republished.
