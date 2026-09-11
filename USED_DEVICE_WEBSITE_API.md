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
- Migration: `supabase/website-migrations/20260911002000_add_used_device_listings.sql`

Used devices are deliberately **not** rows in `products`. A product is a
repeatable SKU with a quantity per store; a used device is one physical thing
whose stock is always one and which is gone when it sells. None of the product
grouping, variant, fit-profile or inventory rules apply to it.

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
        "23 of 23 inspection checks passed",
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
- `battery_health` is null for anything without a measurable battery.
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
3. The public read functions select an explicit column list that excludes
   `device_code` and `store_code`.

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
a device back to inspection withdraws it. Each intention carries a
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
