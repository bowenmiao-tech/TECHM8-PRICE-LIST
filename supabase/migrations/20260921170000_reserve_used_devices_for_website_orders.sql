-- Second-hand devices bought on the website.
--
-- The website now sells a used device through its normal cart and checkout
-- (website-migrations/20260921170000_sell_used_devices_in_the_shop). The device
-- is still one physical thing in one store, so the two sides have to agree on
-- who gets it:
--
--   * When a customer checks out, the website asks this project to reserve the
--     device against their order (hold_pos_used_devices_online). If it is no
--     longer for sale, or another order has it, the website does not take the
--     order.
--   * While it is reserved, it cannot be sold at the counter, repriced, or
--     taken off sale (guard_pos_used_device_online_hold, and the sale-line
--     guard).
--   * The website is the record of how the order went. The POS asks it every
--     few minutes (apply_pos_used_device_online_sync): paid becomes a sale here,
--     an abandoned or cancelled order frees the device again.
--
-- The listing text also changes: the inspection count and the "In stock at"
-- line are dropped from the highlights; the store is sent on its own, as the
-- device location.

begin;

-- ---------------------------------------------------------------------------
-- 1. The reservation, on the device itself.
-- ---------------------------------------------------------------------------
alter table public.pos_used_devices
  add column if not exists online_order_code text,
  add column if not exists online_hold_kind text,
  add column if not exists online_hold_until timestamptz,
  add column if not exists online_hold_at timestamptz,
  add column if not exists online_hold_details jsonb not null default '{}'::jsonb,
  add column if not exists sold_online_order_code text;

alter table public.pos_used_devices drop constraint if exists pos_used_devices_online_hold_kind_check;
alter table public.pos_used_devices add constraint pos_used_devices_online_hold_kind_check
  check (online_hold_kind is null or online_hold_kind in ('checkout', 'processing', 'reserved'));

create index if not exists pos_used_devices_online_order_code_idx
  on public.pos_used_devices (online_order_code) where online_order_code is not null;

alter table public.pos_used_device_transactions drop constraint if exists pos_used_device_transactions_transaction_type_check;
alter table public.pos_used_device_transactions add constraint pos_used_device_transactions_transaction_type_check
  check (transaction_type = any (array[
    'acquisition', 'status_change', 'price_change', 'sale', 'refund_return', 'returned_to_seller',
    'disposal', 'detail_change', 'transfer_out', 'transfer_in', 'transfer_cancelled', 'sale_test',
    'photo_removed', 'online_hold', 'online_release'
  ]));

-- A checkout reservation lapses on its own after its time; one waiting to be
-- paid in store, or whose payment is being processed, lasts until the website
-- says otherwise.
create or replace function public.pos_used_device_online_hold_active(device_row public.pos_used_devices)
returns boolean
language sql
stable
set search_path = ''
as $$
  select device_row.online_order_code is not null
    and (device_row.online_hold_until is null or device_row.online_hold_until > now());
$$;

-- ---------------------------------------------------------------------------
-- 2. While a website order holds the device, nothing here may undo that.
-- ---------------------------------------------------------------------------
create or replace function public.guard_pos_used_device_online_hold()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.pos_used_device_online_hold_active(old) then return new; end if;
  if new.sale_price is distinct from old.sale_price then
    raise exception 'This device is reserved for website order %. Its price cannot change until that order is paid or cancelled', old.online_order_code;
  end if;
  if new.status is distinct from old.status
    and not (new.status = 'sold' and new.sold_online_order_code = old.online_order_code) then
    raise exception 'This device is reserved for website order %. It cannot be changed until that order is paid or cancelled', old.online_order_code;
  end if;
  return new;
end;
$$;

drop trigger if exists pos_used_devices_guard_online_hold on public.pos_used_devices;
create trigger pos_used_devices_guard_online_hold
before update of status, sale_price on public.pos_used_devices
for each row execute function public.guard_pos_used_device_online_hold();

-- The counter sale is refused with a message staff can act on, before the
-- line is written.
do $patch_sale_guard$
declare
  definition text;
  patched text;
begin
  select replace(pg_get_functiondef(oid), chr(13), '') into definition
  from pg_proc
  where proname = 'prepare_pos_used_device_sale_line' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'prepare_pos_used_device_sale_line was not found'; end if;

  patched := replace(
    definition,
    $anchor$if device_row.status <> 'ready_for_sale' then raise exception 'Used device is no longer available for sale'; end if;$anchor$,
    $replacement$if device_row.status <> 'ready_for_sale' then raise exception 'Used device is no longer available for sale'; end if;
  if public.pos_used_device_online_hold_active(device_row) then
    raise exception 'This device is reserved for website order %. Take payment for that order in the website admin, or cancel it there first', device_row.online_order_code;
  end if;$replacement$
  );
  if patched = definition then
    raise exception 'online reservations: the sale-guard anchor was not found';
  end if;
  execute patched;
end;
$patch_sale_guard$;

-- ---------------------------------------------------------------------------
-- 3. Reserving and releasing, called by the website's checkout through the
--    used-device-online-orders function. Service role only.
-- ---------------------------------------------------------------------------
create or replace function public.hold_pos_used_devices_online(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_code_value text := trim(coalesce(payload->>'order_code', ''));
  kind_value text := coalesce(nullif(trim(payload->>'hold_kind'), ''), 'checkout');
  until_value timestamptz := nullif(payload->>'hold_until', '')::timestamptz;
  replaces_value text[] := array(select jsonb_array_elements_text(coalesce(payload->'replaces', '[]'::jsonb)));
  details_value jsonb := jsonb_strip_nulls(jsonb_build_object(
    'fulfillment_method', nullif(payload->>'fulfillment_method', ''),
    'store_slug', nullif(payload->>'store_slug', ''),
    'customer_name', nullif(payload->>'customer_name', '')
  ));
  device_code_value text;
  device_row public.pos_used_devices%rowtype;
  held jsonb := '[]'::jsonb;
begin
  if order_code_value = '' then raise exception 'An order code is required'; end if;
  if kind_value not in ('checkout', 'reserved') then raise exception 'Invalid reservation'; end if;
  if kind_value = 'checkout' and until_value is null then until_value := now() + interval '45 minutes'; end if;
  if kind_value = 'reserved' then until_value := null; end if;

  for device_code_value in
    select distinct trim(code.value)
    from jsonb_array_elements_text(coalesce(payload->'device_codes', '[]'::jsonb)) as code(value)
    order by 1
  loop
    select * into device_row from public.pos_used_devices where device_code = device_code_value for update;
    if not found then raise exception 'USED_DEVICE_UNAVAILABLE: % is not a device this business holds', device_code_value; end if;
    if device_row.status <> 'ready_for_sale' then
      raise exception 'USED_DEVICE_UNAVAILABLE: % is no longer for sale', device_code_value;
    end if;
    if public.pos_used_device_online_hold_active(device_row)
      and device_row.online_order_code <> order_code_value
      and not (device_row.online_order_code = any(replaces_value)) then
      raise exception 'USED_DEVICE_HELD: % is reserved for website order %', device_code_value, device_row.online_order_code;
    end if;

    update public.pos_used_devices
    set online_order_code = order_code_value,
        online_hold_kind = kind_value,
        online_hold_until = until_value,
        online_hold_at = now(),
        online_hold_details = details_value
    where id = device_row.id;

    if device_row.online_order_code is distinct from order_code_value then
      insert into public.pos_used_device_transactions (
        transaction_code, device_id, store_id, transaction_type, from_status, to_status, amount,
        payment_method, staff_name, counterparty_name, notes, transaction_payload
      ) values (
        'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
        device_row.id, device_row.store_id, 'online_hold', device_row.status, device_row.status, 0,
        'Website', 'Website', coalesce(details_value->>'customer_name', ''),
        case kind_value
          when 'reserved' then format('Reserved by website order %s, to be paid in store', order_code_value)
          else format('Reserved while the customer pays for website order %s', order_code_value)
        end,
        details_value || jsonb_build_object('order_code', order_code_value, 'hold_kind', kind_value,
          'hold_until', until_value, 'replaces', to_jsonb(replaces_value))
      );
    end if;
    held := held || to_jsonb(device_code_value);
  end loop;

  return jsonb_build_object('ok', true, 'order_code', order_code_value, 'devices', held);
end;
$$;

create or replace function public.release_pos_used_devices_online(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  order_code_value text := trim(coalesce(payload->>'order_code', ''));
  reason_value text := coalesce(nullif(trim(payload->>'reason'), ''), 'The website order was not completed');
  device_row public.pos_used_devices%rowtype;
  released jsonb := '[]'::jsonb;
begin
  if order_code_value = '' then raise exception 'An order code is required'; end if;
  for device_row in
    select * from public.pos_used_devices where online_order_code = order_code_value order by id for update
  loop
    update public.pos_used_devices
    set online_order_code = null, online_hold_kind = null, online_hold_until = null,
        online_hold_at = null, online_hold_details = '{}'::jsonb
    where id = device_row.id;
    insert into public.pos_used_device_transactions (
      transaction_code, device_id, store_id, transaction_type, from_status, to_status, amount,
      payment_method, staff_name, notes, transaction_payload
    ) values (
      'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
      device_row.id, device_row.store_id, 'online_release', device_row.status, device_row.status, 0,
      'Website', 'Website', format('%s (%s). Back on sale.', reason_value, order_code_value),
      jsonb_build_object('order_code', order_code_value)
    );
    released := released || to_jsonb(device_row.device_code);
  end loop;
  return jsonb_build_object('ok', true, 'order_code', order_code_value, 'devices', released);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Catching up with the website. The payload is the website's own answer
--    (get_used_device_order_holds) for each device: who holds it now, if anyone.
-- ---------------------------------------------------------------------------
create or replace function public.get_pos_used_device_online_sync_codes()
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(device.device_code order by device.device_code), '{}')
  from public.pos_used_devices device
  where device.online_order_code is not null
     or (device.status = 'ready_for_sale' and device.website_status in ('published', 'queued'));
$$;

create or replace function public.apply_pos_used_device_online_sync(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  entry jsonb;
  hold jsonb;
  device_row public.pos_used_devices%rowtype;
  order_code_value text;
  kind_value text;
  sold jsonb := '[]'::jsonb;
  released jsonb := '[]'::jsonb;
  conflicts jsonb := '[]'::jsonb;
begin
  for entry in select value from jsonb_array_elements(coalesce(payload->'devices', '[]'::jsonb))
  loop
    -- One device that cannot be settled must not hold up the rest.
    begin
    select * into device_row from public.pos_used_devices
    where device_code = trim(coalesce(entry->>'device_code', '')) for update;
    if not found then continue; end if;
    hold := case when jsonb_typeof(entry->'hold') = 'object' then entry->'hold' end;
    order_code_value := trim(coalesce(hold->>'order_code', ''));
    kind_value := hold->>'kind';

    if hold is null then
      -- Nobody holds it on the website any more.
      if device_row.online_order_code is not null then
        perform public.release_pos_used_devices_online(jsonb_build_object(
          'order_code', device_row.online_order_code,
          'reason', 'The website order was not completed'));
        released := released || to_jsonb(device_row.device_code);
      end if;

    elsif kind_value = 'sold' then
      if device_row.status = 'sold' then
        if device_row.sold_online_order_code is distinct from order_code_value then
          -- Sold twice: at the counter and online. Someone has to sort it out.
          conflicts := conflicts || jsonb_build_object('device_code', device_row.device_code,
            'order_code', order_code_value, 'problem', 'Already sold in store');
        end if;
      elsif device_row.status = 'ready_for_sale' then
        -- The website is the record of who paid, so its order wins over any
        -- reservation held here, then the sale goes through.
        update public.pos_used_devices
        set online_order_code = order_code_value, online_hold_kind = null, online_hold_until = null,
            online_hold_at = null, online_hold_details = '{}'::jsonb
        where id = device_row.id;
        update public.pos_used_devices
        set status = 'sold',
            sold_at = coalesce(nullif(hold->>'paid_at', '')::timestamptz, now()),
            sold_online_order_code = order_code_value,
            online_order_code = null,
            updated_by = 'Website'
        where id = device_row.id;
        insert into public.pos_used_device_transactions (
          transaction_code, device_id, store_id, transaction_type, from_status, to_status, amount,
          payment_method, staff_name, counterparty_name, counterparty_phone, notes, transaction_payload
        ) values (
          'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
          device_row.id, device_row.store_id, 'sale', 'ready_for_sale', 'sold',
          greatest(coalesce(nullif(hold->>'amount', '')::numeric, device_row.sale_price), 0),
          trim(concat_ws(' ', 'Website', nullif(hold->>'payment_method', ''))),
          'Website',
          coalesce(hold->>'customer_name', ''),
          coalesce(hold->>'customer_phone', ''),
          format('Sold online, website order %s', order_code_value),
          jsonb_strip_nulls(jsonb_build_object('order_code', order_code_value,
            'fulfillment_method', hold->>'fulfillment_method', 'store_slug', hold->>'store_slug'))
        );
        sold := sold || to_jsonb(device_row.device_code);
      else
        conflicts := conflicts || jsonb_build_object('device_code', device_row.device_code,
          'order_code', order_code_value, 'problem', format('Device is %s', device_row.status));
      end if;

    elsif kind_value in ('checkout', 'processing', 'reserved') then
      if device_row.status = 'ready_for_sale'
        and (device_row.online_order_code is distinct from order_code_value
          or device_row.online_hold_kind is distinct from kind_value
          or device_row.online_hold_until is distinct from nullif(hold->>'until', '')::timestamptz) then
        update public.pos_used_devices
        set online_order_code = order_code_value,
            online_hold_kind = kind_value,
            online_hold_until = nullif(hold->>'until', '')::timestamptz,
            online_hold_at = coalesce(online_hold_at, now()),
            online_hold_details = jsonb_strip_nulls(jsonb_build_object(
              'fulfillment_method', hold->>'fulfillment_method', 'store_slug', hold->>'store_slug',
              'customer_name', hold->>'customer_name'))
        where id = device_row.id;
      end if;
    end if;
    exception when others then
      conflicts := conflicts || jsonb_build_object('device_code', entry->>'device_code',
        'order_code', entry#>>'{hold,order_code}', 'problem', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('ok', true, 'sold', sold, 'released', released, 'conflicts', conflicts);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. What the POS and the admin portal show about it.
-- ---------------------------------------------------------------------------
create or replace function public.pos_used_device_payload(device_row public.pos_used_devices)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', device_row.device_code,
    'device_code', device_row.device_code,
    'store_code', store_location.store_code,
    'store_name', store_location.store_name,
    'category', device_row.category,
    'brand', device_row.brand,
    'model', device_row.model,
    'variant', device_row.variant,
    'color', device_row.color,
    'storage', device_row.storage,
    'imei', device_row.imei,
    'serial_number', device_row.serial_number,
    'condition_grade', device_row.condition_grade,
    'battery_health', device_row.battery_health,
    'intake_battery_health', device_row.intake_battery_health,
    'intake_condition_grade', device_row.intake_condition_grade,
    'inspection', device_row.inspection,
    'clean_check_status', device_row.clean_check_status,
    'clean_check_reference', device_row.clean_check_reference,
    'clean_checked_at', device_row.clean_checked_at,
    'activation_lock_removed', device_row.activation_lock_removed,
    'data_erased_confirmed', device_row.data_erased_confirmed,
    'sale_price', device_row.sale_price,
    'status', device_row.status,
    'notes', device_row.notes,
    'photo_urls', device_row.photo_urls,
    'acquired_by', device_row.acquired_by,
    'acquired_at', device_row.acquired_at,
    'updated_by', device_row.updated_by,
    'ready_at', device_row.ready_at,
    'sold_at', device_row.sold_at,
    'sold_order_id', sales_order.order_code,
    'sold_invoice_number', sales_order.invoice_number,
    'sold_online_order_code', device_row.sold_online_order_code,
    'online_order', case when public.pos_used_device_online_hold_active(device_row) then jsonb_build_object(
      'order_code', device_row.online_order_code,
      'kind', device_row.online_hold_kind,
      'until', device_row.online_hold_until,
      'since', device_row.online_hold_at,
      'fulfillment_method', device_row.online_hold_details->>'fulfillment_method',
      'store_slug', device_row.online_hold_details->>'store_slug'
    ) end,
    'seller', jsonb_build_object(
      'name', acquisition.seller_name,
      'phone', acquisition.seller_phone,
      'email', acquisition.seller_email,
      'address', acquisition.seller_address,
      'id_type', acquisition.seller_id_type,
      'id_reference', acquisition.seller_id_reference,
      'age_confirmed', acquisition.seller_age_confirmed,
      'is_owner', acquisition.seller_is_owner,
      'owner_name', acquisition.owner_name,
      'owner_address', acquisition.owner_address,
      'acquisition_statement', acquisition.acquisition_statement,
      'ownership_declaration', acquisition.ownership_declaration
    ),
    'acquisition', jsonb_build_object(
      'id', acquisition.acquisition_code,
      'buyback_number', acquisition.buyback_number,
      'shift_id', acquisition.shift_id,
      'payout_method', acquisition.payout_method,
      'acquired_by', acquisition.acquired_by,
      'acquired_at', acquisition.acquired_at
    ),
    'created_at', device_row.created_at,
    'updated_at', device_row.updated_at
  )
  from public.pos_used_device_acquisitions acquisition
  join public.store_locations store_location on store_location.id = device_row.store_id
  left join public.pos_sales_orders sales_order on sales_order.id = device_row.sold_order_id
  where acquisition.id = device_row.acquisition_id;
$$;

do $patch_admin_stock$
declare
  definition text;
  patched text;
begin
  select replace(pg_get_functiondef('public.get_admin_used_device_stock(text,jsonb)'::regprocedure), chr(13), '')
  into definition;
  patched := replace(
    definition,
    $anchor$      sales_order.invoice_number as sold_invoice_number,$anchor$,
    $replacement$      sales_order.invoice_number as sold_invoice_number,
      device.sold_online_order_code,
      case when public.pos_used_device_online_hold_active(device) then device.online_order_code end as online_order_code,
      case when public.pos_used_device_online_hold_active(device) then device.online_hold_kind end as online_hold_kind,$replacement$
  );
  if patched = definition then
    raise exception 'online reservations: the admin stock anchor was not found';
  end if;
  execute patched;

  select replace(pg_get_functiondef('public.get_admin_used_device_detail(text,text)'::regprocedure), chr(13), '')
  into definition;
  patched := replace(
    definition,
    $anchor$      'sold_invoice_number', invoice_number_value,$anchor$,
    $replacement$      'sold_invoice_number', invoice_number_value,
      'sold_online_order_code', device_row.sold_online_order_code,
      'online_order_code', case when public.pos_used_device_online_hold_active(device_row) then device_row.online_order_code end,
      'online_hold_kind', case when public.pos_used_device_online_hold_active(device_row) then device_row.online_hold_kind end,
      'online_hold_until', case when public.pos_used_device_online_hold_active(device_row) then device_row.online_hold_until end,$replacement$
  );
  if patched = definition then
    raise exception 'online reservations: the admin detail anchor was not found';
  end if;
  execute patched;
end;
$patch_admin_stock$;

-- ---------------------------------------------------------------------------
-- 6. The listing. The inspection count is not something the public needs, and
--    the store is sent on its own as the device location rather than as a
--    highlight.
-- ---------------------------------------------------------------------------
create or replace function public.pos_used_device_listing_payload(target_device_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  device_row public.pos_used_devices%rowtype;
  store_row public.store_locations%rowtype;
  highlights jsonb := '[]'::jsonb;
  condition_line text;
  closing_line text;
  description_text text;
  brand_words text[];
  word_count integer;
  tail_value text;
  model_value text;
  brand_value text;
  title_text text;
  public_battery integer;
  battery_label text;
  images_payload jsonb;
begin
  select * into device_row from public.pos_used_devices where id = target_device_id;
  if not found then raise exception 'Used device not found'; end if;
  select * into store_row from public.store_locations where id = device_row.store_id;

  -- A battery under 85% is not a number to advertise; it is still a working,
  -- tested battery.
  if device_row.battery_health is not null and device_row.battery_health >= 85 then
    public_battery := device_row.battery_health;
    battery_label := format('Battery health %s%%', device_row.battery_health);
  elsif device_row.battery_health is not null then
    public_battery := null;
    battery_label := 'Good battery';
  end if;

  select coalesce(value, 'Tested in store before sale.') into condition_line
  from public.pos_used_device_listing_copy where key = 'condition.' || device_row.condition_grade;
  select coalesce(value, '') into closing_line
  from public.pos_used_device_listing_copy where key = 'closing';

  if battery_label is not null then
    highlights := highlights || to_jsonb(battery_label);
  end if;
  if device_row.storage <> '' then
    highlights := highlights || to_jsonb(device_row.storage || ' storage');
  end if;
  if device_row.data_erased_confirmed then
    highlights := highlights || to_jsonb('Wiped and reset, ready to set up'::text);
  end if;
  if device_row.activation_lock_removed then
    highlights := highlights || to_jsonb('No previous owner account attached'::text);
  end if;

  -- The POS brand is the repair catalogue's product line ("Apple iPhone",
  -- "Samsung Galaxy S") and the model usually repeats its tail ("iPhone 17 Pro",
  -- "Galaxy S24 Ultra"). Drop the longest tail of the brand the model already
  -- starts with, so the title says it once.
  brand_value := btrim(device_row.brand);
  model_value := btrim(device_row.model);
  brand_words := regexp_split_to_array(brand_value, '\s+');
  for word_count in reverse coalesce(array_length(brand_words, 1), 0)..1 loop
    tail_value := array_to_string(
      brand_words[array_length(brand_words, 1) - word_count + 1:array_length(brand_words, 1)], ' ');
    if left(lower(model_value), length(tail_value)) = lower(tail_value) then
      brand_value := coalesce(array_to_string(
        brand_words[1:array_length(brand_words, 1) - word_count], ' '), '');
      exit;
    end if;
  end loop;
  title_text := btrim(regexp_replace(
    concat_ws(' ', nullif(brand_value, ''), model_value, nullif(device_row.storage, ''), nullif(device_row.color, '')),
    '\s+', ' ', 'g'));

  description_text := btrim(concat_ws(E'\n\n', condition_line, nullif(closing_line, '')));

  select coalesce(jsonb_agg(jsonb_build_object(
    'storage_path', ordered.storage_path,
    'position', ordered.position
  ) order by ordered.position), '[]'::jsonb) into images_payload
  from (
    select entry.storage_path,
           row_number() over (order by entry.created_at, entry.id) as position
    from public.pos_used_device_updates entry
    where entry.device_id = device_row.id and entry.kind = 'photo' and entry.stage = 'listing'
  ) ordered;

  return jsonb_build_object(
    'device_code', device_row.device_code,
    'device_category', device_row.category,
    'store_code', coalesce(store_row.store_code, ''),
    'store_name', coalesce(store_row.store_name, ''),
    'title', title_text,
    'brand', device_row.brand,
    'model', device_row.model,
    'storage', device_row.storage,
    'color', device_row.color,
    'condition_grade', device_row.condition_grade,
    'condition_summary', condition_line,
    'battery_health', public_battery,
    'battery_label', battery_label,
    'price', device_row.sale_price,
    'description', description_text,
    'highlights', highlights,
    'images', images_payload,
    'website_status', device_row.website_status,
    'website_slug', device_row.website_slug
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Grants. The website reaches these only through the edge function, which
--    checks the shared secret.
-- ---------------------------------------------------------------------------
revoke all on function public.pos_used_device_online_hold_active(public.pos_used_devices) from public, anon, authenticated;
revoke all on function public.guard_pos_used_device_online_hold() from public, anon, authenticated;
revoke all on function public.hold_pos_used_devices_online(jsonb) from public, anon, authenticated;
revoke all on function public.release_pos_used_devices_online(jsonb) from public, anon, authenticated;
revoke all on function public.get_pos_used_device_online_sync_codes() from public, anon, authenticated;
revoke all on function public.apply_pos_used_device_online_sync(jsonb) from public, anon, authenticated;
grant execute on function public.pos_used_device_online_hold_active(public.pos_used_devices) to anon, authenticated, service_role;
grant execute on function public.hold_pos_used_devices_online(jsonb) to service_role;
grant execute on function public.release_pos_used_devices_online(jsonb) to service_role;
grant execute on function public.get_pos_used_device_online_sync_codes() to service_role;
grant execute on function public.apply_pos_used_device_online_sync(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 8. Every five minutes, while any device is reserved online, ask the website
--    how its order went.
-- ---------------------------------------------------------------------------
do $schedule$
begin
  if exists (select 1 from cron.job where jobname = 'used-device-online-sync') then
    perform cron.unschedule('used-device-online-sync');
  end if;
  perform cron.schedule(
    'used-device-online-sync',
    '*/5 * * * *',
    $job$
  select net.http_post(
    url := 'https://abkjbhmifswfexpjkval.supabase.co/functions/v1/used-device-online-orders',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := '{"action":"sync"}'::jsonb,
    timeout_milliseconds := 55000
  ) where exists (
    select 1 from public.pos_used_devices where online_order_code is not null
  );
$job$
  );
end;
$schedule$;

-- ---------------------------------------------------------------------------
-- 9. Send the devices already on the website again, with the new listing text
--    and the store as their location.
-- ---------------------------------------------------------------------------
do $republish$
declare
  device_row record;
begin
  for device_row in
    select id, device_code from public.pos_used_devices
    where status = 'ready_for_sale' and website_status in ('published', 'queued', 'failed')
  loop
    perform public.enqueue_pos_used_device_publish(device_row.id, device_row.device_code, 'publish', 'system');
  end loop;
end;
$republish$;

commit;
