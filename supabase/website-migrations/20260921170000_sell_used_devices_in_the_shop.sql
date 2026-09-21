-- Second-hand devices in the shop, bought online like any other product.
--
-- A listing is still the record of what the public is told about a device
-- (20260911002000). What changes is that each listing now has a mirror row in
-- `products`, under a "Second Hand Devices" category, so the shop, the cart and
-- checkout treat it like everything else. Two rules keep it a one-off:
--
--   * its slug starts with `used-`, which the cart and checkout read as "one
--     only", so it can never be ordered as two;
--   * an order that claims it holds it, and no other order can claim it while
--     it does. Checkout also tells the POS, so the device cannot be sold at the
--     counter at the same time. Once the order is paid, being paid, or reserved
--     to pay in store, the product is hidden. While the customer is only on the
--     payment page it stays visible, so a customer who goes back and tries
--     again is not locked out of their own device: their new checkout replaces
--     the old one (see claim_used_devices_for_order).
--
-- A hold is read from the order itself, so nothing has to remember to release
-- one: an order that is abandoned, fails or is cancelled simply stops holding.

begin;

-- 1. The shop category. The storefront builds its menu from this taxonomy and
-- only shows a category once something visible is in it.
insert into public.pos_category_taxonomy (category_name, subcategory_name, category_sort, subcategory_sort, active)
values
  ('Second Hand Devices', 'Used Phones', 105, 10, true),
  ('Second Hand Devices', 'Used Tablets', 105, 20, true),
  ('Second Hand Devices', 'Used Laptops', 105, 30, true),
  ('Second Hand Devices', 'Used Watches', 105, 40, true),
  ('Second Hand Devices', 'Used Game Consoles', 105, 50, true),
  ('Second Hand Devices', 'Other Used Devices', 105, 60, true)
on conflict (category_name, subcategory_name) do update set active = true;

alter table public.used_device_categories
  add column if not exists pos_category_id bigint references public.pos_category_taxonomy(id) on delete set null;

update public.used_device_categories category
set pos_category_id = taxonomy.id
from public.pos_category_taxonomy taxonomy
where taxonomy.category_name = 'Second Hand Devices'
  and taxonomy.subcategory_name = category.name;

alter table public.used_device_listings
  add column if not exists product_id bigint references public.products(id) on delete set null,
  add column if not exists store_name text not null default '';

create unique index if not exists used_device_listings_product_id_key
  on public.used_device_listings (product_id) where product_id is not null;

-- Where each device is, for the "Device location" line. New publishes carry it;
-- the listings already live said it in a highlight.
update public.used_device_listings listing
set store_name = coalesce((
  select substring(line from '^In stock at (.+)$')
  from jsonb_array_elements_text(listing.highlights) line
  where line ~ '^In stock at '
  limit 1
), '')
where listing.store_name = '';

-- 2. `used-` marks a one-off everywhere: the cart quantity, checkout, and which
-- page shows it.
update public.used_device_listings set slug = 'used-' || slug where slug not like 'used-%';

-- 3. Which orders hold which devices. A row here is written only by
-- claim_used_devices_for_order, so an order that never finished claiming holds
-- nothing.
create table if not exists public.used_device_order_claims (
  order_id bigint not null references public.orders(id) on delete cascade,
  listing_id bigint not null references public.used_device_listings(id) on delete cascade,
  product_id bigint not null,
  claimed_at timestamptz not null default timezone('utc'::text, now()),
  primary key (order_id, listing_id)
);
create index if not exists used_device_order_claims_product_id_idx on public.used_device_order_claims (product_id);
alter table public.used_device_order_claims enable row level security;
revoke all on public.used_device_order_claims from public, anon, authenticated;
grant all on public.used_device_order_claims to service_role;

-- The orders holding a device, the strongest first. Paid holds for good.
-- Waiting to be paid in store holds until the order is paid or cancelled. A
-- checkout nobody finished lets go after 45 minutes (the Stripe session itself
-- expires after 30); once Stripe is processing the payment it holds until
-- Stripe says how it went.
create or replace function private.used_device_order_holds(target_product_id bigint, excluded_order_id bigint default null)
returns table (
  order_id bigint,
  order_code text,
  hold_kind text,
  hold_until timestamptz,
  auth_user_id uuid,
  stripe_checkout_session_id text
)
language sql
stable
security definer
set search_path = ''
as $$
  select held.id, held.order_code, held.hold_kind, held.hold_until, held.auth_user_id, held.stripe_checkout_session_id
  from (
    select placed.id, placed.order_code, placed.created_at, placed.auth_user_id, placed.stripe_checkout_session_id,
      case
        when placed.payment_status in ('paid', 'partially_refunded') and placed.status <> 'cancelled' then 'sold'
        when placed.payment_status = 'unpaid' and placed.status not in ('cancelled', 'abandoned') then 'reserved'
        when placed.payment_status = 'pending' and placed.status = 'submitted'
          and placed.stripe_payment_intent_id is not null then 'processing'
        when placed.payment_status = 'pending' and placed.status = 'submitted'
          and placed.created_at > now() - interval '45 minutes' then 'checkout'
      end as hold_kind,
      case
        when placed.payment_status = 'pending' and placed.stripe_payment_intent_id is null
          then placed.created_at + interval '45 minutes'
      end as hold_until
    from public.used_device_order_claims claim
    join public.orders placed on placed.id = claim.order_id
    where claim.product_id = target_product_id
      and (excluded_order_id is null or placed.id <> excluded_order_id)
  ) held
  where held.hold_kind is not null
  order by case held.hold_kind when 'sold' then 0 when 'processing' then 1 when 'reserved' then 2 else 3 end,
    held.created_at;
$$;

-- A device is visible in the shop while it is published and no order has paid,
-- is paying, or has reserved it.
create or replace function private.refresh_used_device_products(target_product_ids bigint[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(array_length(target_product_ids, 1), 0) = 0 then return; end if;
  update public.products product
  set is_visible = wanted.visible
  from (
    select listing.product_id,
      (listing.status = 'published'
        and not exists (
          select 1 from private.used_device_order_holds(listing.product_id) holder
          where holder.hold_kind <> 'checkout'
        )) as visible
    from public.used_device_listings listing
    where listing.product_id = any(target_product_ids)
  ) wanted
  where product.id = wanted.product_id
    and product.is_visible is distinct from wanted.visible;
end;
$$;

-- The product row that stands for a listing in the shop. It is only ever
-- written from here, so the listing stays the source of truth.
create or replace function private.sync_used_device_product(target_listing_id bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  listing_row public.used_device_listings%rowtype;
  category_row public.used_device_categories%rowtype;
  product_id_value bigint;
  image_rows jsonb;
begin
  select * into listing_row from public.used_device_listings where id = target_listing_id for update;
  if not found then return null; end if;
  -- A device that never reached the shop needs no product.
  if listing_row.product_id is null and listing_row.status <> 'published' then return null; end if;
  select * into category_row from public.used_device_categories where id = listing_row.category_id;

  select coalesce(jsonb_agg(image order by (image->>'position')::integer), '[]'::jsonb) into image_rows
  from jsonb_array_elements(listing_row.images) image
  where coalesce(image->>'url', '') ~ '^https://';

  insert into public.products (
    sku, slug, name, brand, model, short_description, description, condition_label, compatibility,
    retail_price, compare_at_price, image_url, stock_quantity, min_order_quantity, is_featured,
    is_visible, is_pos_visible, pos_category_id, source_system, source_external_id, source_metadata,
    seo_title, seo_description
  ) values (
    listing_row.device_code,
    listing_row.slug,
    listing_row.title,
    -- The POS brand is a product line ("Apple iPhone"); the maker is its first word.
    split_part(btrim(listing_row.brand), ' ', 1),
    listing_row.model,
    concat_ws(' · ', nullif(listing_row.condition_grade, '') || ' condition',
      nullif(listing_row.storage, ''), nullif(listing_row.color, '')),
    listing_row.description,
    listing_row.condition_grade,
    'Second hand',
    listing_row.price,
    null,
    image_rows->0->>'url',
    1,
    1,
    false,
    false,
    -- The POS sells these through its own used-device screens, never as a product.
    false,
    category_row.pos_category_id,
    'pos_used_device',
    listing_row.device_code,
    jsonb_build_object(
      'listing_id', listing_row.id,
      'storage', listing_row.storage,
      'color', listing_row.color,
      'condition_grade', listing_row.condition_grade,
      'battery_health', listing_row.battery_health,
      'store_code', listing_row.store_code,
      'store_name', listing_row.store_name,
      'used_device_category', category_row.slug
    ),
    left(listing_row.title || ' | Second Hand | TECHM8', 120),
    left(btrim(concat_ws(' ', listing_row.title || '.', listing_row.condition_summary)), 300)
  )
  on conflict (sku) do update set
    slug = excluded.slug,
    name = excluded.name,
    brand = excluded.brand,
    model = excluded.model,
    short_description = excluded.short_description,
    description = excluded.description,
    condition_label = excluded.condition_label,
    compatibility = excluded.compatibility,
    retail_price = excluded.retail_price,
    image_url = excluded.image_url,
    stock_quantity = 1,
    min_order_quantity = 1,
    is_pos_visible = false,
    pos_category_id = excluded.pos_category_id,
    source_metadata = excluded.source_metadata,
    seo_title = excluded.seo_title,
    seo_description = excluded.seo_description
  -- Never overwrite a real product that happens to share the SKU.
  where public.products.source_system = 'pos_used_device'
  returning id into product_id_value;

  if product_id_value is null then
    raise exception 'SKU % already belongs to another product', listing_row.device_code;
  end if;

  delete from public.product_images where product_id = product_id_value;
  insert into public.product_images (product_id, image_url, alt_text, sort_order)
  select product_id_value, entry.image->>'url', listing_row.title, (entry.position - 1)::integer
  from jsonb_array_elements(image_rows) with ordinality as entry(image, position);

  if listing_row.product_id is distinct from product_id_value then
    update public.used_device_listings set product_id = product_id_value where id = listing_row.id;
  end if;
  perform private.refresh_used_device_products(array[product_id_value]);
  return product_id_value;
end;
$$;

-- Holds follow the order: when it is paid, abandoned, fails or is cancelled,
-- the devices it claimed are shown or hidden again straight away.
create or replace function private.refresh_used_devices_for_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.refresh_used_device_products(array(
    select claim.product_id from public.used_device_order_claims claim where claim.order_id = new.id));
  return null;
end;
$$;

drop trigger if exists orders_refresh_used_devices on public.orders;
create trigger orders_refresh_used_devices
after update of payment_status, status, stripe_payment_intent_id on public.orders
for each row execute function private.refresh_used_devices_for_order();

create or replace function private.refresh_used_device_after_release()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.refresh_used_device_products(array[old.product_id]);
  return null;
end;
$$;

-- An order deleted before payment started (checkout could not open) takes its
-- claim with it.
drop trigger if exists used_device_order_claims_release on public.used_device_order_claims;
create trigger used_device_order_claims_release
after delete on public.used_device_order_claims
for each row execute function private.refresh_used_device_after_release();

-- 4. Claiming. Checkout calls this once the order and its lines are saved. It
-- locks each device's listing, so two customers checking out the same device
-- at the same moment are served one after the other and the second is told.
--
-- The one exception is the same signed-in customer's own unfinished checkout:
-- they went back from the payment page. That order is returned as
-- `superseded`, and the caller closes its payment session before this order
-- goes any further, so the customer can never pay twice for one device.
create or replace function public.claim_used_devices_for_order(target_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
  line record;
  holder record;
  devices jsonb := '[]'::jsonb;
  superseded jsonb := '[]'::jsonb;
  product_ids bigint[] := '{}';
begin
  select * into order_row from public.orders where id = target_order_id;
  if not found then raise exception 'Order not found'; end if;

  for line in
    select item.quantity, item.unit_price, listing.id as listing_id, listing.device_code, listing.title,
           listing.status, listing.price, listing.product_id, listing.store_code, listing.store_name
    from public.order_items item
    join public.used_device_listings listing on listing.product_id = item.product_id
    where item.order_id = target_order_id
    order by listing.id
    for update of listing
  loop
    if line.product_id = any(product_ids) or line.quantity <> 1 then
      raise exception 'USED_DEVICE_QUANTITY: % is one of a kind and can only be ordered once.', line.title;
    end if;
    if line.status <> 'published' then
      raise exception 'USED_DEVICE_UNAVAILABLE: % has just been sold. Please remove it from your cart.', line.title;
    end if;
    if round(line.unit_price, 2) <> round(line.price, 2) then
      raise exception 'USED_DEVICE_PRICE: The price of % has changed. Please refresh your cart.', line.title;
    end if;
    for holder in select * from private.used_device_order_holds(line.product_id, target_order_id) loop
      if holder.hold_kind = 'checkout' and holder.auth_user_id is not null
        and holder.auth_user_id = order_row.auth_user_id then
        if not superseded @> jsonb_build_array(jsonb_build_object('order_id', holder.order_id)) then
          superseded := superseded || jsonb_build_object('order_id', holder.order_id,
            'order_code', holder.order_code, 'stripe_checkout_session_id', holder.stripe_checkout_session_id);
        end if;
      elsif holder.hold_kind = 'checkout' then
        raise exception 'USED_DEVICE_HELD: Another customer is paying for % right now. If they do not finish, it will be available again within 45 minutes.', line.title;
      elsif holder.auth_user_id is not null and holder.auth_user_id = order_row.auth_user_id then
        raise exception 'USED_DEVICE_HELD: You have already ordered % (order %).', line.title, holder.order_code;
      else
        raise exception 'USED_DEVICE_HELD: % has just been sold. Please remove it from your cart.', line.title;
      end if;
    end loop;

    insert into public.used_device_order_claims (order_id, listing_id, product_id)
    values (target_order_id, line.listing_id, line.product_id)
    on conflict (order_id, listing_id) do nothing;
    devices := devices || jsonb_build_object('device_code', line.device_code, 'title', line.title,
      'price', line.price, 'store_code', line.store_code, 'store_name', line.store_name);
    product_ids := product_ids || line.product_id;
  end loop;

  if coalesce(array_length(product_ids, 1), 0) = 0 then
    return jsonb_build_object('ok', true, 'devices', '[]'::jsonb, 'superseded', '[]'::jsonb);
  end if;

  perform private.refresh_used_device_products(product_ids);
  return jsonb_build_object(
    'ok', true,
    'order_code', order_row.order_code,
    'hold_kind', case when order_row.payment_status = 'unpaid' then 'reserved' else 'checkout' end,
    'hold_until', case when order_row.payment_status = 'unpaid' then null
      else order_row.created_at + interval '45 minutes' end,
    'fulfillment_method', order_row.fulfillment_method,
    'store_slug', order_row.store_slug,
    'devices', devices,
    'superseded', superseded
  );
end;
$$;

-- 5. What the POS asks: for each device, who holds it now. The POS applies the
-- answer, so a paid order becomes a sale and a lapsed one frees the device,
-- even if the POS never heard about the order as it happened.
create or replace function public.get_used_device_order_holds(device_codes text[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  perform private.refresh_used_device_products(array(
    select listing.product_id from public.used_device_listings listing
    where listing.device_code = any(device_codes) and listing.product_id is not null));

  select coalesce(jsonb_agg(jsonb_build_object(
    'device_code', code.value,
    'listing_status', listing.status,
    'hold', case when holder.order_id is null then null else jsonb_build_object(
      'kind', holder.hold_kind,
      'order_code', holder.order_code,
      'until', holder.hold_until,
      'amount', (select item.unit_price from public.order_items item
                 where item.order_id = holder.order_id and item.product_id = listing.product_id limit 1),
      'customer_name', placed.customer_name,
      'customer_phone', placed.phone,
      'payment_method', placed.payment_method_label,
      'fulfillment_method', placed.fulfillment_method,
      'store_slug', placed.store_slug,
      'paid_at', placed.paid_at
    ) end
  ) order by code.value), '[]'::jsonb) into result
  from unnest(device_codes) as code(value)
  left join public.used_device_listings listing on listing.device_code = code.value
  left join lateral (
    select * from private.used_device_order_holds(listing.product_id) limit 1
  ) holder on listing.product_id is not null
  left join public.orders placed on placed.id = holder.order_id;

  return jsonb_build_object('ok', true, 'devices', result);
end;
$$;

-- 6. Publishing now writes the product as well, and keeps the `used-` slug.
create or replace function public.upsert_used_device_listing(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  device_code_value text := trim(coalesce(payload->>'device_code', ''));
  version_value bigint := coalesce(nullif(payload->>'source_version', '')::bigint, 0);
  status_value text := coalesce(nullif(trim(payload->>'status'), ''), 'published');
  category_row public.used_device_categories%rowtype;
  existing public.used_device_listings%rowtype;
  listing_row public.used_device_listings%rowtype;
  slug_value text;
  product_id_value bigint;
begin
  if device_code_value = '' then raise exception 'device_code is required'; end if;
  if status_value not in ('draft', 'published', 'withdrawn', 'sold') then raise exception 'Invalid listing status'; end if;

  select * into category_row from public.used_device_categories
  where device_category = trim(coalesce(payload->>'device_category', '')) and active;
  if not found then raise exception 'No website category for this device type'; end if;

  select * into existing from public.used_device_listings where device_code = device_code_value for update;

  if found and existing.source_version > version_value then
    return jsonb_build_object('ok', true, 'skipped', true, 'reason', 'A newer version is already published',
      'slug', existing.slug, 'status', existing.status);
  end if;

  slug_value := coalesce(nullif(trim(payload->>'slug'), ''), existing.slug,
    lower(regexp_replace(
      trim(coalesce(payload->>'title', device_code_value)) || '-' || right(device_code_value, 6),
      '[^a-zA-Z0-9]+', '-', 'g')));
  slug_value := trim(both '-' from slug_value);
  if slug_value not like 'used-%' then slug_value := 'used-' || slug_value; end if;

  insert into public.used_device_listings (
    device_code, store_code, store_name, category_id, slug, title, brand, model, storage, color,
    condition_grade, condition_summary, battery_health, price, description,
    highlights, images, status, source_version, published_at, withdrawn_at, updated_at
  ) values (
    device_code_value,
    trim(coalesce(payload->>'store_code', '')),
    trim(coalesce(payload->>'store_name', '')),
    category_row.id,
    slug_value,
    trim(coalesce(payload->>'title', '')),
    trim(coalesce(payload->>'brand', '')),
    trim(coalesce(payload->>'model', '')),
    trim(coalesce(payload->>'storage', '')),
    trim(coalesce(payload->>'color', '')),
    trim(coalesce(payload->>'condition_grade', '')),
    trim(coalesce(payload->>'condition_summary', '')),
    nullif(payload->>'battery_health', '')::integer,
    round(coalesce(nullif(payload->>'price', '')::numeric, 0), 2),
    coalesce(payload->>'description', ''),
    case when jsonb_typeof(payload->'highlights') = 'array' then payload->'highlights' else '[]'::jsonb end,
    case when jsonb_typeof(payload->'images') = 'array' then payload->'images' else '[]'::jsonb end,
    status_value,
    version_value,
    case when status_value = 'published' then timezone('utc'::text, now()) else null end,
    case when status_value in ('withdrawn', 'sold') then timezone('utc'::text, now()) else null end,
    timezone('utc'::text, now())
  )
  on conflict (device_code) do update set
    store_code = excluded.store_code,
    store_name = case when excluded.store_name <> '' then excluded.store_name
      else public.used_device_listings.store_name end,
    category_id = excluded.category_id,
    slug = excluded.slug,
    title = excluded.title,
    brand = excluded.brand,
    model = excluded.model,
    storage = excluded.storage,
    color = excluded.color,
    condition_grade = excluded.condition_grade,
    condition_summary = excluded.condition_summary,
    battery_health = excluded.battery_health,
    price = excluded.price,
    description = excluded.description,
    highlights = excluded.highlights,
    images = excluded.images,
    status = excluded.status,
    source_version = excluded.source_version,
    published_at = case
      when excluded.status = 'published' then coalesce(public.used_device_listings.published_at, excluded.published_at)
      else public.used_device_listings.published_at
    end,
    withdrawn_at = excluded.withdrawn_at,
    updated_at = timezone('utc'::text, now())
  returning * into listing_row;

  product_id_value := private.sync_used_device_product(listing_row.id);

  return jsonb_build_object('ok', true, 'slug', listing_row.slug, 'status', listing_row.status,
    'source_version', listing_row.source_version, 'product_id', product_id_value);
end;
$$;

create or replace function public.withdraw_used_device_listing(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  device_code_value text := trim(coalesce(payload->>'device_code', ''));
  version_value bigint := coalesce(nullif(payload->>'source_version', '')::bigint, 0);
  status_value text := coalesce(nullif(trim(payload->>'status'), ''), 'withdrawn');
  listing_row public.used_device_listings%rowtype;
begin
  if device_code_value = '' then raise exception 'device_code is required'; end if;
  if status_value not in ('withdrawn', 'sold') then raise exception 'A listing can only be withdrawn or marked sold'; end if;

  update public.used_device_listings
  set status = status_value,
      source_version = greatest(source_version, version_value),
      withdrawn_at = timezone('utc'::text, now()),
      updated_at = timezone('utc'::text, now())
  where device_code = device_code_value
    and source_version <= version_value
  returning * into listing_row;

  if not found then
    return jsonb_build_object('ok', true, 'skipped', true, 'reason', 'No listing to withdraw, or a newer version already applied');
  end if;
  perform private.sync_used_device_product(listing_row.id);
  return jsonb_build_object('ok', true, 'slug', listing_row.slug, 'status', listing_row.status);
end;
$$;

-- 7. The public device pages only show a device someone can still buy. A link
-- from before the `used-` prefix still finds its device.
create or replace function public.get_used_device_listing(listing_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  slug_value text := trim(coalesce(listing_slug, ''));
  result jsonb;
begin
  select to_jsonb(row_data) into result
  from (
    select
      listing.slug, listing.title, listing.brand, listing.model, listing.storage,
      listing.color, listing.condition_grade, listing.condition_summary,
      listing.battery_health, listing.price, listing.description,
      listing.highlights, listing.images, listing.published_at,
      listing.store_code, listing.store_name,
      product.id as product_id, product.sku,
      category.slug as category_slug, category.name as category_name
    from public.used_device_listings listing
    join public.used_device_categories category on category.id = listing.category_id
    join public.products product on product.id = listing.product_id and product.is_visible
    where listing.status = 'published'
      and listing.slug in (slug_value, 'used-' || slug_value)
    limit 1
  ) row_data;

  if result is null then
    return jsonb_build_object('ok', false, 'message', 'Listing not found');
  end if;
  return jsonb_build_object('ok', true, 'listing', result);
end;
$$;

create or replace function public.get_used_device_listings(
  category_slug text default '',
  brand_filter text default '',
  result_limit integer default 60,
  result_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  category_value text := trim(coalesce(category_slug, ''));
  brand_value text := trim(coalesce(brand_filter, ''));
  safe_limit integer := least(greatest(coalesce(result_limit, 60), 1), 200);
  safe_offset integer := greatest(coalesce(result_offset, 0), 0);
  rows_payload jsonb;
  total_count integer;
begin
  select count(*) into total_count
  from public.used_device_listings listing
  join public.used_device_categories category on category.id = listing.category_id
  join public.products product on product.id = listing.product_id and product.is_visible
  where listing.status = 'published'
    and (category_value = '' or category.slug = category_value)
    and (brand_value = '' or lower(listing.brand) = lower(brand_value));

  select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.published_at desc), '[]'::jsonb)
  into rows_payload
  from (
    select
      listing.slug, listing.title, listing.brand, listing.model, listing.storage,
      listing.color, listing.condition_grade, listing.condition_summary,
      listing.battery_health, listing.price, listing.description,
      listing.highlights, listing.images, listing.published_at,
      listing.store_code, listing.store_name,
      product.id as product_id, product.sku,
      category.slug as category_slug, category.name as category_name
    from public.used_device_listings listing
    join public.used_device_categories category on category.id = listing.category_id
    join public.products product on product.id = listing.product_id and product.is_visible
    where listing.status = 'published'
      and (category_value = '' or category.slug = category_value)
      and (brand_value = '' or lower(listing.brand) = lower(brand_value))
    order by listing.published_at desc
    limit safe_limit offset safe_offset
  ) row_data;

  return jsonb_build_object(
    'ok', true,
    'total', total_count,
    'limit', safe_limit,
    'offset', safe_offset,
    'categories', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'slug', category.slug,
        'name', category.name,
        'count', (
          select count(*) from public.used_device_listings counted
          join public.products product on product.id = counted.product_id and product.is_visible
          where counted.category_id = category.id and counted.status = 'published'
        )
      ) order by category.sort_order), '[]'::jsonb)
      from public.used_device_categories category
      where category.active
    ),
    'listings', rows_payload
  );
end;
$$;

revoke all on function private.used_device_order_holds(bigint, bigint) from public, anon, authenticated;
revoke all on function private.refresh_used_device_products(bigint[]) from public, anon, authenticated;
revoke all on function private.sync_used_device_product(bigint) from public, anon, authenticated;
revoke all on function private.refresh_used_devices_for_order() from public, anon, authenticated;
revoke all on function private.refresh_used_device_after_release() from public, anon, authenticated;
revoke all on function public.claim_used_devices_for_order(bigint) from public, anon, authenticated;
revoke all on function public.get_used_device_order_holds(text[]) from public, anon, authenticated;
grant execute on function public.claim_used_devices_for_order(bigint) to service_role;
grant execute on function public.get_used_device_order_holds(text[]) to service_role;

-- 8. The devices already on the website get their product now.
do $$
declare
  listing_id_value bigint;
begin
  for listing_id_value in
    select id from public.used_device_listings where status = 'published' order by id
  loop
    perform private.sync_used_device_product(listing_id_value);
  end loop;
end;
$$;

commit;
