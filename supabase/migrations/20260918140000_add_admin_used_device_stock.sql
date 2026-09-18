-- The admin view of second-hand stock: what is for sale, what has sold, and
-- the one decision only the owner makes -- what a device is listed at.
--
-- The counter buys a device and tests it. It arrives unpriced. Until now the
-- admin portal could see payouts, exceptions and the dealer register but not
-- the devices themselves, and pricing happened on the shop floor. These three
-- functions move that decision to the admin portal:
--
--   stock   - every device, split into for sale and sold, with the store it is
--             sitting in and whether it is live on the website.
--   detail  - everything recorded about one device, including the seller and
--             the payout, which is admin-only data.
--   listing - set the price and, when nothing is outstanding, put it online.
--
-- Publishing itself is untouched: writing `sale_price` and `ready_for_sale`
-- fires the existing website trigger, which queues the publish.

-- Why a device cannot go on the website yet, in the words the admin needs to
-- read. One definition, used by the list, the detail panel and the gate.
create or replace function public.pos_used_device_listing_blockers(target_device_id bigint)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  device_row public.pos_used_devices%rowtype;
  blockers text[] := array[]::text[];
  outstanding integer;
begin
  select * into device_row from public.pos_used_devices where id = target_device_id;
  if not found then return array['This device no longer exists']; end if;
  if device_row.status = 'sold' then return array['This device has been sold']; end if;
  if device_row.status in ('returned_to_seller', 'disposed') then
    return array['This device is closed and no longer in stock'];
  end if;

  if device_row.clean_check_status not in ('Clean', 'Not Applicable') then
    blockers := array_append(blockers, format('The lost or stolen check is still %s', lower(device_row.clean_check_status)));
  end if;
  if not device_row.activation_lock_removed then
    blockers := array_append(blockers, 'Activation locks are not confirmed removed');
  end if;
  if not device_row.data_erased_confirmed then
    blockers := array_append(blockers, 'Customer data is not confirmed erased');
  end if;

  select count(*) into outstanding
  from public.pos_used_device_inspection_items item
  where item.active
    and item.category = device_row.category
    and lower(coalesce(device_row.inspection->>item.item_key, '')) not in ('pass', 'na');
  if outstanding > 0 then
    blockers := array_append(blockers, format('%s inspection check%s still to pass', outstanding,
      case when outstanding = 1 then '' else 's' end));
  end if;

  if device_row.evidence_required and not exists (
    select 1 from public.pos_used_device_updates entry
    where entry.device_id = device_row.id and entry.kind = 'photo' and entry.stage = 'listing'
  ) then
    blockers := array_append(blockers, 'No listing photo has been added');
  end if;

  return blockers;
end;
$$;

revoke all on function public.pos_used_device_listing_blockers(bigint) from public, anon, authenticated;
grant execute on function public.pos_used_device_listing_blockers(bigint) to service_role;

comment on function public.pos_used_device_listing_blockers(bigint) is
  'Everything standing between a device and the website, as sentences. Empty means it only needs a price.';

-- Who is acting, for the ledger. An admin is named by their staff record when
-- they have one, and by their login email when they do not.
create or replace function public.admin_session_actor_name(session_token text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(nullif(staff.display_name, ''), admin_user.login_email)
  from public.admin_sessions admin_session
  join public.admin_users admin_user on admin_user.id = admin_session.admin_user_id
  left join public.staff_directory staff
    on lower(staff.email) = lower(admin_user.login_email) and staff.active
  where admin_session.expires_at > now()
    and admin_user.active
    and extensions.crypt(session_token, admin_session.session_hash) = admin_session.session_hash
  limit 1;
$$;

revoke all on function public.admin_session_actor_name(text) from public, anon, authenticated;
grant execute on function public.admin_session_actor_name(text) to service_role;

-- 1. The stock list, in two halves.
create or replace function public.get_admin_used_device_stock(session_token text, payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  group_value text := coalesce(nullif(trim(payload->>'group'), ''), 'for_sale');
  store_value text := lower(coalesce(trim(payload->>'store_code'), ''));
  query_value text := trim(coalesce(payload->>'q', ''));
  safe_limit integer := least(greatest(coalesce((payload->>'limit')::integer, 300), 1), 1000);
  wanted_statuses text[];
  counts_payload jsonb;
  stores_payload jsonb;
  devices_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  if group_value not in ('for_sale', 'sold', 'closed') then raise exception 'Unknown device group'; end if;

  wanted_statuses := case group_value
    when 'for_sale' then array['inspection', 'ready_for_sale']
    when 'sold' then array['sold']
    else array['returned_to_seller', 'disposed']
  end;

  -- Counts are deliberately unfiltered: the tabs must not move when the admin
  -- narrows the list to one store.
  select jsonb_build_object(
    'for_sale', count(*) filter (where device.status in ('inspection', 'ready_for_sale')),
    'sold', count(*) filter (where device.status = 'sold'),
    'closed', count(*) filter (where device.status in ('returned_to_seller', 'disposed')),
    'live', count(*) filter (where device.status = 'ready_for_sale' and device.website_status = 'published'),
    'unpriced', count(*) filter (where device.status in ('inspection', 'ready_for_sale') and device.sale_price <= 0),
    'stock_cost', round(coalesce(sum(device.purchase_cost + public.pos_used_device_refurb_cost(device.id))
      filter (where device.status in ('inspection', 'ready_for_sale')), 0), 2),
    'stock_retail', round(coalesce(sum(device.sale_price)
      filter (where device.status in ('inspection', 'ready_for_sale')), 0), 2)
  ) into counts_payload
  from public.pos_used_devices device;

  select coalesce(jsonb_agg(jsonb_build_object(
    'store_code', grouped.store_code,
    'store_name', grouped.store_name,
    'count', grouped.device_count
  ) order by grouped.store_name), '[]'::jsonb) into stores_payload
  from (
    select store.store_code, store.store_name, count(*)::integer as device_count
    from public.pos_used_devices device
    join public.store_locations store on store.id = device.store_id
    where device.status = any(wanted_statuses)
    group by store.store_code, store.store_name
  ) grouped;

  select coalesce(jsonb_agg(to_jsonb(row_data)
    order by row_data.action_first desc, row_data.sort_at desc), '[]'::jsonb)
  into devices_payload
  from (
    select
      device.device_code as id,
      device.device_code,
      store.store_code,
      store.store_name,
      device.category,
      device.brand,
      device.model,
      device.storage,
      device.color,
      device.condition_grade,
      device.battery_health,
      device.imei,
      device.serial_number,
      device.status,
      device.website_status,
      device.sale_price,
      device.purchase_cost,
      round(device.purchase_cost + public.pos_used_device_refurb_cost(device.id), 2) as total_cost,
      acquisition.buyback_number,
      device.acquired_at,
      device.ready_at,
      device.sold_at,
      sales_order.invoice_number as sold_invoice_number,
      round(coalesce(sale_ledger.amount, device.sale_price), 2) as sold_amount,
      case when device.status = 'sold'
        then round(coalesce(sale_ledger.amount, device.sale_price)
          - device.purchase_cost - public.pos_used_device_refurb_cost(device.id), 2)
      end as margin,
      (select count(*)::integer from public.pos_used_device_updates entry
        where entry.device_id = device.id and entry.kind = 'photo' and entry.stage = 'listing') as listing_photo_count,
      (select count(*)::integer from public.pos_used_device_updates entry
        where entry.device_id = device.id and entry.kind = 'photo' and entry.stage = 'intake') as intake_photo_count,
      (extract(day from now() - device.acquired_at))::integer as days_held,
      public.pos_used_device_listing_blockers(device.id) as blockers,
      -- Anything the admin has to act on floats to the top of the list.
      (device.status = 'inspection' or device.sale_price <= 0) as action_first,
      coalesce(device.sold_at, device.acquired_at) as sort_at
    from public.pos_used_devices device
    join public.store_locations store on store.id = device.store_id
    join public.pos_used_device_acquisitions acquisition on acquisition.id = device.acquisition_id
    left join public.pos_sales_orders sales_order on sales_order.id = device.sold_order_id
    left join lateral (
      select ledger.amount
      from public.pos_used_device_transactions ledger
      where ledger.device_id = device.id and ledger.transaction_type = 'sale'
      order by ledger.created_at desc
      limit 1
    ) sale_ledger on true
    where device.status = any(wanted_statuses)
      and (store_value = '' or store.store_code = store_value)
      and (
        query_value = ''
        or device.device_code ilike '%' || query_value || '%'
        or device.brand ilike '%' || query_value || '%'
        or device.model ilike '%' || query_value || '%'
        or device.storage ilike '%' || query_value || '%'
        or device.color ilike '%' || query_value || '%'
        or device.imei ilike '%' || query_value || '%'
        or device.serial_number ilike '%' || query_value || '%'
        or acquisition.seller_name ilike '%' || query_value || '%'
        or acquisition.buyback_number::text = regexp_replace(query_value, '[^0-9]', '', 'g')
      )
    order by action_first desc, sort_at desc
    limit safe_limit
  ) row_data;

  return jsonb_build_object(
    'ok', true,
    'group', group_value,
    'counts', counts_payload,
    'stores', stores_payload,
    'devices', devices_payload
  );
end;
$$;

revoke all on function public.get_admin_used_device_stock(text, jsonb) from public;
grant execute on function public.get_admin_used_device_stock(text, jsonb) to anon, authenticated, service_role;

comment on function public.get_admin_used_device_stock(text, jsonb) is
  'Admin-session-only second-hand stock, split into for sale, sold and closed, with the store each device is in and what is stopping it going online.';

-- 2. Everything recorded about one device.
create or replace function public.get_admin_used_device_detail(session_token text, target_device_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  device_row public.pos_used_devices%rowtype;
  acquisition_row public.pos_used_device_acquisitions%rowtype;
  store_row public.store_locations%rowtype;
  invoice_number_value bigint;
  sold_amount_value numeric(12,2);
  inspection_payload jsonb;
  costs_payload jsonb;
  ledger_payload jsonb;
  photos_payload jsonb;
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;

  select * into device_row from public.pos_used_devices device
  where device.device_code = coalesce(trim(target_device_code), '');
  if not found then raise exception 'Used device not found'; end if;

  select * into acquisition_row from public.pos_used_device_acquisitions where id = device_row.acquisition_id;
  select * into store_row from public.store_locations where id = device_row.store_id;
  select sales_order.invoice_number into invoice_number_value
  from public.pos_sales_orders sales_order where sales_order.id = device_row.sold_order_id;
  select round(ledger.amount, 2) into sold_amount_value
  from public.pos_used_device_transactions ledger
  where ledger.device_id = device_row.id and ledger.transaction_type = 'sale'
  order by ledger.created_at desc limit 1;

  -- The current checklist for this category, then anything answered against
  -- this device that is no longer on the list, so nothing recorded disappears.
  select coalesce(jsonb_agg(jsonb_build_object(
    'key', entry.item_key, 'label', entry.label, 'answer', entry.answer, 'retired', entry.retired
  ) order by entry.position, entry.item_key), '[]'::jsonb) into inspection_payload
  from (
    select item.item_key, item.label, item.position,
      lower(coalesce(device_row.inspection->>item.item_key, '')) as answer, false as retired
    from public.pos_used_device_inspection_items item
    where item.active and item.category = device_row.category
    union all
    select answered.key, replace(answered.key, '_', ' '), 10000, lower(answered.value), true
    from jsonb_each_text(device_row.inspection) answered(key, value)
    where not exists (
      select 1 from public.pos_used_device_inspection_items item
      where item.active and item.category = device_row.category and item.item_key = answered.key
    )
  ) entry;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', cost.id, 'kind', cost.kind, 'description', cost.description, 'amount', cost.amount,
    'repair_ticket_code', cost.repair_ticket_code, 'staff_name', cost.staff_name, 'created_at', cost.created_at
  ) order by cost.created_at desc), '[]'::jsonb) into costs_payload
  from public.pos_used_device_costs cost where cost.device_id = device_row.id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'type', ledger.transaction_type, 'amount', ledger.amount, 'from_status', ledger.from_status,
    'to_status', ledger.to_status, 'staff_name', ledger.staff_name, 'notes', ledger.notes,
    'created_at', ledger.created_at
  ) order by ledger.created_at desc), '[]'::jsonb) into ledger_payload
  from public.pos_used_device_transactions ledger where ledger.device_id = device_row.id;

  select jsonb_object_agg(stage_counts.stage, stage_counts.stage_count) into photos_payload
  from (
    select entry.stage, count(*)::integer as stage_count
    from public.pos_used_device_updates entry
    where entry.device_id = device_row.id and entry.kind = 'photo'
    group by entry.stage
  ) stage_counts;

  return jsonb_build_object(
    'ok', true,
    'device', jsonb_build_object(
      'id', device_row.device_code,
      'device_code', device_row.device_code,
      'store_code', store_row.store_code,
      'store_name', store_row.store_name,
      'category', device_row.category,
      'brand', device_row.brand,
      'model', device_row.model,
      'variant', device_row.variant,
      'storage', device_row.storage,
      'color', device_row.color,
      'condition_grade', device_row.condition_grade,
      'battery_health', device_row.battery_health,
      'imei', device_row.imei,
      'serial_number', device_row.serial_number,
      'status', device_row.status,
      'website_status', device_row.website_status,
      'website_slug', device_row.website_slug,
      'website_synced_at', device_row.website_synced_at,
      'clean_check_status', device_row.clean_check_status,
      'clean_check_reference', device_row.clean_check_reference,
      'activation_lock_removed', device_row.activation_lock_removed,
      'data_erased_confirmed', device_row.data_erased_confirmed,
      'notes', device_row.notes,
      'purchase_cost', device_row.purchase_cost,
      'refurb_cost', public.pos_used_device_refurb_cost(device_row.id),
      'total_cost', round(device_row.purchase_cost + public.pos_used_device_refurb_cost(device_row.id), 2),
      'sale_price', device_row.sale_price,
      'sold_amount', sold_amount_value,
      'sold_invoice_number', invoice_number_value,
      'acquired_at', device_row.acquired_at,
      'acquired_by', device_row.acquired_by,
      'ready_at', device_row.ready_at,
      'sold_at', device_row.sold_at,
      'updated_by', device_row.updated_by,
      'days_held', (extract(day from now() - device_row.acquired_at))::integer,
      'blockers', to_jsonb(public.pos_used_device_listing_blockers(device_row.id))
    ),
    'seller', jsonb_build_object(
      'buyback_number', acquisition_row.buyback_number,
      'acquisition_code', acquisition_row.acquisition_code,
      'name', acquisition_row.seller_name,
      'phone', acquisition_row.seller_phone,
      'email', acquisition_row.seller_email,
      'address', acquisition_row.seller_address,
      'id_type', acquisition_row.seller_id_type,
      'id_reference', acquisition_row.seller_id_reference,
      'is_owner', acquisition_row.seller_is_owner,
      'owner_name', acquisition_row.owner_name,
      'owner_address', acquisition_row.owner_address,
      'acquisition_statement', acquisition_row.acquisition_statement,
      'payout_method', acquisition_row.payout_method,
      'payout_amount', acquisition_row.payout_amount,
      'payout_reference_type', acquisition_row.payout_reference_type,
      'payout_payid', acquisition_row.payout_payid,
      'payout_bsb', acquisition_row.payout_bsb,
      'payout_account_number', acquisition_row.payout_account_number,
      'payout_account_name', acquisition_row.payout_account_name
    ),
    'inspection', inspection_payload,
    'costs', costs_payload,
    'ledger', ledger_payload,
    'photos', coalesce(photos_payload, '{}'::jsonb)
  );
end;
$$;

revoke all on function public.get_admin_used_device_detail(text, text) from public;
grant execute on function public.get_admin_used_device_detail(text, text) to anon, authenticated, service_role;

comment on function public.get_admin_used_device_detail(text, text) is
  'Admin-session-only detail for one second-hand device: the record, the seller, the payout destination, the checklist, refurbishment costs and the ledger.';

-- 3. The owner prices it and, when nothing is outstanding, puts it online.
create or replace function public.set_admin_used_device_listing(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  device_row public.pos_used_devices%rowtype;
  actor_name text;
  price_value numeric(12,2) := round(coalesce(nullif(payload->>'sale_price', '')::numeric, -1), 2);
  should_publish boolean := lower(coalesce(payload->>'publish', 'false')) = 'true';
  note_value text := trim(coalesce(payload->>'note', ''));
  previous_status text;
  previous_price numeric(12,2);
  blockers text[];
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  actor_name := coalesce(public.admin_session_actor_name(session_token), 'Admin');
  if length(note_value) > 500 then raise exception 'The note is too long'; end if;

  select * into device_row from public.pos_used_devices device
  where device.device_code = coalesce(trim(payload->>'device_code'), '')
  for update;
  if not found then raise exception 'Used device not found'; end if;
  if device_row.status = 'sold' then raise exception 'This device has been sold'; end if;
  if device_row.status in ('returned_to_seller', 'disposed') then
    raise exception 'This device is closed and no longer in stock';
  end if;
  if price_value < 0 then raise exception 'Enter the price this device is listed at'; end if;
  if price_value = 0 and should_publish then raise exception 'A device cannot go online at zero'; end if;

  blockers := public.pos_used_device_listing_blockers(device_row.id);
  if should_publish and array_length(blockers, 1) > 0 then
    raise exception 'This device is not ready to go online: %', array_to_string(blockers, '; ');
  end if;

  previous_status := device_row.status;
  previous_price := device_row.sale_price;

  update public.pos_used_devices
  set sale_price = price_value,
      status = case when should_publish then 'ready_for_sale' else status end,
      ready_at = coalesce(ready_at, case when should_publish then now() end),
      updated_by = actor_name
  where id = device_row.id
  returning * into device_row;

  if previous_price is distinct from device_row.sale_price then
    insert into public.pos_used_device_transactions (
      transaction_code, device_id, store_id, transaction_type, from_status, to_status,
      amount, staff_name, notes, transaction_payload
    ) values (
      'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
      device_row.id, device_row.store_id, 'price_change', previous_status, device_row.status,
      device_row.sale_price, actor_name,
      coalesce(nullif(note_value, ''), 'Listed price set in the admin portal'),
      jsonb_build_object('previous_price', previous_price, 'sale_price', device_row.sale_price, 'source', 'admin')
    );
  end if;

  if previous_status is distinct from device_row.status then
    insert into public.pos_used_device_transactions (
      transaction_code, device_id, store_id, transaction_type, from_status, to_status,
      amount, staff_name, notes, transaction_payload
    ) values (
      'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
      device_row.id, device_row.store_id, 'status_change', previous_status, device_row.status,
      0, actor_name,
      coalesce(nullif(note_value, ''), 'Approved for sale in the admin portal'),
      jsonb_build_object('source', 'admin')
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'device_code', device_row.device_code,
    'store_code', (select store.store_code from public.store_locations store where store.id = device_row.store_id),
    'status', device_row.status,
    'sale_price', device_row.sale_price,
    'website_status', device_row.website_status,
    'published', should_publish
  );
end;
$$;

revoke all on function public.set_admin_used_device_listing(text, jsonb) from public;
grant execute on function public.set_admin_used_device_listing(text, jsonb) to anon, authenticated, service_role;

comment on function public.set_admin_used_device_listing(text, jsonb) is
  'Admin-session-only: set what a second-hand device is listed at and, when nothing is outstanding, move it to ready for sale. The existing website trigger queues the publish.';
