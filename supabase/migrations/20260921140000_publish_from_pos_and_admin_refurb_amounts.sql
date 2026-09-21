-- Putting a finished device on the website from the counter, what the public
-- listing says, and who prices the repair work.
--
--   * "Publish to Website" in the POS was only enabled once a device was
--     already marked ready for sale, which staff reached through a separate
--     form, so to them the button did nothing. It now does the whole step:
--     when every check is done and the device has a price, one press marks it
--     ready and sends it to the website. Until then the POS lists exactly what
--     is still missing.
--   * The public listing: battery health is shown only from 85% up; below that
--     it says "Good battery". The inspection line counts only the checks that
--     apply, so a tablet no longer reads "13 of 21 passed". The title stops
--     repeating the product line ("Apple iPhone iPhone 17 Pro").
--   * Refurbishment: staff record what was repaired or replaced; the admin
--     portal adds what it cost. Staff never see an amount.
--
-- Function bodies are normalised to LF before patching, because these bodies
-- carry a mix of CRLF and LF from earlier edits.

-- 1. What the website is sent.
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
  answers jsonb;
  checks_applicable integer;
  checks_passed integer;
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

  -- The pre-sale test decides what the public is told. A check marked N/A does
  -- not apply to this device (a tablet has no SIM tray or ear speaker), so it
  -- is left out of the count rather than reading as a failure.
  answers := public.pos_used_device_latest_sale_test_answers(device_row.id);
  select
    count(*) filter (where lower(coalesce(answers->>item.item_key, '')) in ('pass', 'fail')),
    count(*) filter (where lower(coalesce(answers->>item.item_key, '')) = 'pass')
  into checks_applicable, checks_passed
  from public.pos_used_device_inspection_items item
  where item.active and item.category = device_row.category;

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

  if checks_applicable > 0 then
    highlights := highlights || to_jsonb(format('%s of %s inspection checks passed', checks_passed, checks_applicable));
  end if;
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
  if store_row.store_name is not null then
    highlights := highlights || to_jsonb('In stock at ' || store_row.store_name);
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

-- 2. What the POS website panel shows: why the button is or is not available.
create or replace function public.get_pos_used_device_website_status(session_token text, store_code text, device_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  context jsonb;
  device_row public.pos_used_devices%rowtype;
  queue_row public.pos_used_device_publish_queue%rowtype;
  blockers text[];
begin
  context := public.authorize_pos_used_device_evidence(session_token, store_code, device_code);
  select * into device_row from public.pos_used_devices where id = (context->>'device_id')::bigint;
  select * into queue_row from public.pos_used_device_publish_queue
  where device_id = device_row.id and completed_at is null
  order by requested_at desc limit 1;

  blockers := public.pos_used_device_listing_blockers(device_row.id);
  if device_row.status in ('inspection', 'ready_for_sale') and device_row.sale_price <= 0 then
    blockers := array_append(blockers, 'No sale price has been set yet');
  end if;

  return jsonb_build_object(
    'ok', true,
    'status', device_row.status,
    'sale_price', device_row.sale_price,
    'website_status', device_row.website_status,
    'website_slug', device_row.website_slug,
    'website_synced_at', device_row.website_synced_at,
    'listing_photo_count', (
      select count(*) from public.pos_used_device_updates entry
      where entry.device_id = device_row.id and entry.kind = 'photo' and entry.stage = 'listing'
    ),
    'blockers', to_jsonb(blockers),
    'can_publish', device_row.status in ('inspection', 'ready_for_sale') and coalesce(array_length(blockers, 1), 0) = 0,
    'pending', case when queue_row.id is null then null else jsonb_build_object(
      'action', queue_row.action,
      'requested_at', queue_row.requested_at,
      'attempts', queue_row.attempts,
      'last_error', queue_row.last_error
    ) end
  );
end;
$$;

-- 3. The button itself: a finished device goes on sale and online in one step.
create or replace function public.request_pos_used_device_publish(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  context jsonb;
  device_row public.pos_used_devices%rowtype;
  action_value text := coalesce(nullif(trim(payload->>'action'), ''), 'publish');
  actor_name text;
  blockers text[];
begin
  context := public.authorize_pos_used_device_evidence(
    session_token, payload->>'store_code', payload->>'device_code');
  actor_name := coalesce(nullif(context->>'author', ''), 'Staff');
  select * into device_row from public.pos_used_devices
  where id = (context->>'device_id')::bigint
  for update;

  if action_value not in ('publish', 'withdraw') then raise exception 'Invalid publish action'; end if;

  if action_value = 'publish' then
    if device_row.status not in ('inspection', 'ready_for_sale') then
      raise exception 'Only a device that is in stock can go on the website';
    end if;
    blockers := public.pos_used_device_listing_blockers(device_row.id);
    if device_row.sale_price <= 0 then
      blockers := array_append(blockers, 'No sale price has been set yet');
    end if;
    if coalesce(array_length(blockers, 1), 0) > 0 then
      raise exception 'Not ready for the website yet: %', array_to_string(blockers, '; ');
    end if;

    if device_row.status = 'inspection' then
      -- Going on sale queues the publish through the website trigger.
      update public.pos_used_devices
      set status = 'ready_for_sale',
          ready_at = coalesce(ready_at, now()),
          updated_by = actor_name
      where id = device_row.id
      returning * into device_row;
      insert into public.pos_used_device_transactions (
        transaction_code, device_id, store_id, transaction_type, from_status, to_status,
        amount, staff_name, notes, transaction_payload
      ) values (
        'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
        device_row.id, device_row.store_id, 'status_change', 'inspection', 'ready_for_sale',
        0, actor_name, 'Put on sale and on the website from the POS',
        jsonb_build_object('source', 'pos_publish')
      );
      return jsonb_build_object('ok', true, 'device_code', device_row.device_code,
        'status', device_row.status, 'website_status', device_row.website_status);
    end if;
  end if;

  perform public.enqueue_pos_used_device_publish(device_row.id, device_row.device_code, action_value, actor_name);
  update public.pos_used_devices set website_status = 'queued' where id = device_row.id;
  return jsonb_build_object('ok', true, 'device_code', device_row.device_code,
    'status', device_row.status, 'website_status', 'queued');
end;
$$;

comment on function public.request_pos_used_device_publish(text, jsonb) is
  'Publish or take down a device. Publishing a finished device that is still in inspection marks it ready for sale in the same step; anything outstanding is refused with the list of what is missing.';

-- 4. Refurbishment: staff say what was done, the admin says what it cost.
alter table public.pos_used_device_costs
  alter column amount drop not null;

do $migration$
declare
  constraint_name text;
begin
  for constraint_name in
    select conname from pg_constraint
    where conrelid = 'public.pos_used_device_costs'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%amount%'
  loop
    execute format('alter table public.pos_used_device_costs drop constraint %I', constraint_name);
  end loop;
end;
$migration$;

alter table public.pos_used_device_costs
  add constraint pos_used_device_costs_amount_check check (amount is null or amount > 0),
  add column if not exists amount_set_by text not null default '',
  add column if not exists amount_set_at timestamptz;

update public.pos_used_device_costs
set amount_set_by = staff_name, amount_set_at = created_at
where amount is not null and amount_set_at is null;

comment on column public.pos_used_device_costs.amount is
  'What the work cost, entered in the admin portal. Null until the admin prices it; staff never see it.';

create or replace function public.add_pos_used_device_cost(session_token text, store_code text, device_code text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  context jsonb;
  cost_id uuid := (payload->>'id')::uuid;
  device_id_value bigint;
  is_admin_value boolean;
  kind_value text := coalesce(nullif(btrim(payload->>'kind'), ''), 'part');
  description_value text := btrim(coalesce(payload->>'description', ''));
  amount_value numeric(12,2);
  existing public.pos_used_device_costs%rowtype;
begin
  context := public.authorize_pos_used_device_evidence(session_token, store_code, device_code);
  if not (context->>'writable')::boolean then raise exception 'Closed device records are read-only'; end if;
  device_id_value := (context->>'device_id')::bigint;
  is_admin_value := coalesce((context->>'is_admin')::boolean, false);
  if cost_id is null then raise exception 'Cost ID is required'; end if;
  if kind_value not in ('part', 'labour', 'external') then raise exception 'Invalid cost type'; end if;
  if description_value = '' or length(description_value) > 300 then
    raise exception 'Describe what was repaired or replaced in up to 300 characters';
  end if;

  -- Only the admin prices the work. A staff entry is a record of what was done.
  if is_admin_value and nullif(btrim(coalesce(payload->>'amount', '')), '') is not null then
    amount_value := round((payload->>'amount')::numeric, 2);
    if amount_value <= 0 then raise exception 'An amount must be above zero'; end if;
  end if;

  select * into existing from public.pos_used_device_costs where id = cost_id;
  if found then
    if existing.device_id <> device_id_value then raise exception 'Cost ID already used'; end if;
    return jsonb_build_object('ok', true, 'id', existing.id);
  end if;

  insert into public.pos_used_device_costs(
    id, device_id, kind, description, amount, repair_ticket_code, staff_name, amount_set_by, amount_set_at
  ) values (
    cost_id, device_id_value, kind_value, description_value, amount_value,
    left(btrim(coalesce(payload->>'repair_ticket_code', '')), 100), context->>'author',
    case when amount_value is null then '' else context->>'author' end,
    case when amount_value is null then null else now() end
  );

  return jsonb_build_object('ok', true, 'id', cost_id);
end;
$$;

-- Staff see what has been done to a device, so nobody records it twice. The
-- amounts are the admin's.
create or replace function public.get_pos_used_device_costs(session_token text, store_code text, device_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  context jsonb;
  device_id_value bigint;
  is_admin_value boolean;
  result jsonb;
begin
  context := public.authorize_pos_used_device_evidence(session_token, store_code, device_code);
  is_admin_value := coalesce((context->>'is_admin')::boolean, false);
  device_id_value := (context->>'device_id')::bigint;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', cost.id, 'kind', cost.kind, 'description', cost.description,
    'amount', case when is_admin_value then cost.amount end,
    'repair_ticket_code', cost.repair_ticket_code,
    'staff_name', cost.staff_name, 'created_at', cost.created_at
  ) order by cost.created_at desc, cost.id), '[]'::jsonb) into result
  from public.pos_used_device_costs cost
  where cost.device_id = device_id_value;

  return jsonb_build_object(
    'ok', true,
    'costs', result,
    'can_view_costs', is_admin_value,
    'refurb_cost', case when is_admin_value then public.pos_used_device_refurb_cost(device_id_value) end,
    'writable', context->'writable'
  );
end;
$$;

-- The admin portal: price a line staff recorded, or add a priced line.
create or replace function public.save_admin_used_device_cost(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_name text;
  cost_row public.pos_used_device_costs%rowtype;
  device_row public.pos_used_devices%rowtype;
  amount_value numeric(12,2);
  kind_value text := coalesce(nullif(btrim(payload->>'kind'), ''), 'part');
  description_value text := btrim(coalesce(payload->>'description', ''));
begin
  if not public.is_valid_admin_session(session_token) then raise exception 'Invalid admin session'; end if;
  actor_name := coalesce(public.admin_session_actor_name(session_token), 'Admin');

  if nullif(btrim(coalesce(payload->>'amount', '')), '') is not null then
    amount_value := round((payload->>'amount')::numeric, 2);
    if amount_value <= 0 then raise exception 'An amount must be above zero'; end if;
  end if;

  if nullif(btrim(coalesce(payload->>'cost_id', '')), '') is not null then
    select * into cost_row from public.pos_used_device_costs
    where id = (payload->>'cost_id')::uuid
    for update;
    if not found then raise exception 'That repair line no longer exists'; end if;
    update public.pos_used_device_costs
    set amount = amount_value,
        amount_set_by = case when amount_value is null then '' else actor_name end,
        amount_set_at = case when amount_value is null then null else now() end
    where id = cost_row.id
    returning * into cost_row;
  else
    select * into device_row from public.pos_used_devices
    where device_code = coalesce(btrim(payload->>'device_code'), '');
    if not found then raise exception 'Used device not found'; end if;
    if device_row.status in ('returned_to_seller', 'disposed') then
      raise exception 'Closed device records are read-only';
    end if;
    if kind_value not in ('part', 'labour', 'external') then raise exception 'Invalid cost type'; end if;
    if description_value = '' or length(description_value) > 300 then
      raise exception 'Describe what was repaired or replaced in up to 300 characters';
    end if;
    insert into public.pos_used_device_costs(
      id, device_id, kind, description, amount, repair_ticket_code, staff_name, amount_set_by, amount_set_at
    ) values (
      gen_random_uuid(), device_row.id, kind_value, description_value, amount_value,
      left(btrim(coalesce(payload->>'repair_ticket_code', '')), 100), actor_name,
      case when amount_value is null then '' else actor_name end,
      case when amount_value is null then null else now() end
    ) returning * into cost_row;
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', cost_row.id,
    'amount', cost_row.amount,
    'refurb_cost', public.pos_used_device_refurb_cost(cost_row.device_id)
  );
end;
$$;

revoke all on function public.save_admin_used_device_cost(text, jsonb) from public;
grant execute on function public.save_admin_used_device_cost(text, jsonb) to anon, authenticated, service_role;

comment on function public.save_admin_used_device_cost(text, jsonb) is
  'Admin-session-only: set or clear the amount on a repair line staff recorded, or add a priced line. Amounts are never shown to staff.';

-- The admin detail shows who priced each line.
do $migration$
declare
  definition text;
  patched text;
begin
  select replace(pg_get_functiondef('public.get_admin_used_device_detail(text,text)'::regprocedure), chr(13), '')
    into definition;
  patched := replace(
    definition,
    $anchor$    'repair_ticket_code', cost.repair_ticket_code, 'staff_name', cost.staff_name, 'created_at', cost.created_at
  ) order by cost.created_at desc), '[]'::jsonb) into costs_payload$anchor$,
    $replacement$    'repair_ticket_code', cost.repair_ticket_code, 'staff_name', cost.staff_name, 'created_at', cost.created_at,
    'amount_set_by', cost.amount_set_by, 'amount_set_at', cost.amount_set_at
  ) order by cost.created_at desc), '[]'::jsonb) into costs_payload$replacement$
  );
  if patched = definition then
    raise exception 'refurbishment patch: the admin detail costs anchor was not found';
  end if;
  execute patched;
end;
$migration$;

-- 5. Devices already on the website pick up the new listing text.
do $migration$
declare
  device_row record;
begin
  for device_row in
    select id, device_code from public.pos_used_devices
    where status = 'ready_for_sale' and website_status in ('published', 'queued', 'failed')
  loop
    perform public.enqueue_pos_used_device_publish(device_row.id, device_row.device_code, 'publish', 'system');
    update public.pos_used_devices set website_status = 'queued' where id = device_row.id;
  end loop;
end;
$migration$;
