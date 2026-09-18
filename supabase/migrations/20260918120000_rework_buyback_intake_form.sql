-- The buyback intake form, rebuilt around what happens at the counter.
--
--   * Phones and tablets are inspected against the paper inspection form, item
--     for item, plus wireless charging and the camera button. Power, housing,
--     battery and liquid damage leave the checklist: two of them are not on the
--     paper form and battery health has its own field.
--   * Condition, sale price and the IMEI check reference leave intake. None of
--     them can be answered honestly while the seller is standing there; they
--     belong to the listing step, which already collects all three. Intake
--     records a condition so the column stays populated, and the sale price
--     starts at zero until someone prices the device.
--   * A purchase is numbered per store, like an invoice, so a seller can be
--     given a buyback number that means something to both sides.
--   * The seller becomes a customer record. One person's sales and buybacks are
--     then answerable from the same place instead of two disconnected lists.
--   * A bank transfer records where the money went: a PayID, or a BSB, account
--     number and account name.
--
-- Function bodies are normalised to LF before patching, because these bodies
-- carry a mix of CRLF and LF from earlier edits.

-- 1. The checklist the screen draws and the ready-for-sale gate enforces.
update public.pos_used_device_inspection_items
set active = false
where category in ('Phone', 'Tablet')
  and item_key in ('power', 'housing', 'battery', 'liquid');

insert into public.pos_used_device_inspection_items (category, item_key, label, position)
select device_category.name, item.item_key, item.label, item.position
from (values ('Phone'::text), ('Tablet')) as device_category(name)
cross join (values
  ('touch', 'Touch working', 10),
  ('display_lcd', 'LCD working', 20),
  ('vibrate', 'Vibrate switch working (iPhone)', 30),
  ('power_button', 'Power button working', 40),
  ('volume_buttons', 'Volume buttons working', 50),
  ('fingerprint', 'Fingerprint scanner working', 60),
  ('face_id', 'Face ID working', 70),
  ('charging_port', 'Charging port working', 80),
  ('ear_speaker', 'Ear speaker working', 90),
  ('proximity', 'Proximity sensor working', 100),
  ('loudspeaker', 'Loudspeaker working', 110),
  ('mic', 'Mic working', 120),
  ('rear_camera', 'Rear camera working', 130),
  ('front_camera', 'Front camera working', 140),
  ('flash', 'Flash working', 150),
  ('sim_reader', 'SIM card reader working', 160),
  ('bluetooth', 'Bluetooth working', 170),
  ('wifi', 'Wi-Fi working', 180),
  ('back_glass', 'Back glass intact', 190),
  ('wireless_charging', 'Wireless charging working', 200),
  ('camera_button', 'Camera button working', 210)
) as item(item_key, label, position)
on conflict (category, item_key) do update
set label = excluded.label,
    position = excluded.position,
    active = true;

-- 2. A device arrives without a price. It gets one before it is sold, which the
--    ready-for-sale gate below enforces.
do $migration$
declare
  constraint_name text;
begin
  select conname into constraint_name
  from pg_constraint
  where conrelid = 'public.pos_used_devices'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%sale_price%'
    and pg_get_constraintdef(oid) like '%>%'
    and pg_get_constraintdef(oid) not like '%>=%';
  if constraint_name is null then
    raise exception 'The positive sale price constraint was not found';
  end if;
  execute format('alter table public.pos_used_devices drop constraint %I', constraint_name);
end;
$migration$;

alter table public.pos_used_devices
  add constraint pos_used_devices_sale_price_check check (sale_price >= 0);

alter table public.pos_used_devices
  alter column sale_price set default 0;

-- 3. The purchase record: its own number, the customer it belongs to, and where
--    a bank payout was sent.
alter table public.pos_used_device_acquisitions
  add column if not exists buyback_number bigint,
  add column if not exists customer_id bigint references public.pos_customers(id) on delete set null,
  add column if not exists payout_reference_type text not null default '',
  add column if not exists payout_payid text not null default '',
  add column if not exists payout_bsb text not null default '',
  add column if not exists payout_account_number text not null default '',
  add column if not exists payout_account_name text not null default '';

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'pos_used_device_acquisitions_payout_reference_check'
      and conrelid = 'public.pos_used_device_acquisitions'::regclass
  ) then
    alter table public.pos_used_device_acquisitions
    add constraint pos_used_device_acquisitions_payout_reference_check
    check (payout_reference_type in ('', 'PayID', 'Bank Account'));
  end if;
end;
$migration$;

create table if not exists public.pos_store_buyback_counters (
  store_id bigint primary key references public.store_locations(id) on delete restrict,
  last_number bigint not null default 0 check (last_number >= 0),
  updated_at timestamptz not null default now()
);

drop trigger if exists pos_store_buyback_counters_set_updated_at on public.pos_store_buyback_counters;
create trigger pos_store_buyback_counters_set_updated_at
before update on public.pos_store_buyback_counters
for each row
execute function public.set_updated_at();

alter table public.pos_store_buyback_counters enable row level security;
revoke all on public.pos_store_buyback_counters from public, anon, authenticated;
grant select, insert, update on public.pos_store_buyback_counters to service_role;

-- Existing purchases are numbered in the order they were made, per store.
with renumbered as (
  select
    acquisition.id,
    row_number() over (
      partition by acquisition.store_id
      order by acquisition.acquired_at, acquisition.id
    )::bigint as buyback_number
  from public.pos_used_device_acquisitions acquisition
)
update public.pos_used_device_acquisitions acquisition
set buyback_number = renumbered.buyback_number
from renumbered
where renumbered.id = acquisition.id
  and acquisition.buyback_number is null;

create unique index if not exists pos_used_device_acquisitions_store_number_key
on public.pos_used_device_acquisitions (store_id, buyback_number);

insert into public.pos_store_buyback_counters (store_id, last_number)
select
  store_location.id,
  coalesce(max(acquisition.buyback_number), 0)
from public.store_locations store_location
left join public.pos_used_device_acquisitions acquisition
  on acquisition.store_id = store_location.id
group by store_location.id
on conflict (store_id) do update
set last_number = greatest(public.pos_store_buyback_counters.last_number, excluded.last_number),
    updated_at = now();

-- Past sellers who already exist as customers are linked by phone number, so
-- the history panel is not empty for people the shop already knows.
update public.pos_used_device_acquisitions acquisition
set customer_id = (
  select customer.id
  from public.pos_customers customer
  where customer.active
    and customer.normalized_phone <> ''
    and customer.normalized_phone = regexp_replace(acquisition.seller_phone, '[^0-9]', '', 'g')
  order by customer.updated_at desc, customer.id
  limit 1
)
where acquisition.customer_id is null;

create index if not exists pos_used_device_acquisitions_customer_idx
on public.pos_used_device_acquisitions (customer_id, acquired_at desc)
where customer_id is not null;

-- 4. The seller becomes a customer. An existing customer is matched on phone
--    number first and email second, and is never renamed by a buyback: only
--    contact details the record is missing are filled in.
create or replace function public.pos_link_buyback_customer(
  target_store_id bigint,
  seller_name text,
  seller_phone text,
  seller_email text,
  seller_address text,
  staff_name text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  customer_row public.pos_customers%rowtype;
  name_value text := trim(coalesce(seller_name, ''));
  phone_value text := trim(coalesce(seller_phone, ''));
  email_value text := lower(trim(coalesce(seller_email, '')));
  address_value text := trim(coalesce(seller_address, ''));
  normalized_phone_value text := regexp_replace(coalesce(seller_phone, ''), '[^0-9]', '', 'g');
  first_name_value text := split_part(name_value, ' ', 1);
  last_name_value text := trim(substr(name_value, length(split_part(name_value, ' ', 1)) + 1));
begin
  if name_value = '' or normalized_phone_value = '' then return null; end if;

  select * into customer_row
  from public.pos_customers customer
  where customer.active
    and customer.normalized_phone = normalized_phone_value
  order by customer.updated_at desc, customer.id
  limit 1;

  if not found and email_value <> '' then
    select * into customer_row
    from public.pos_customers customer
    where customer.active
      and lower(customer.email) = email_value
    order by customer.updated_at desc, customer.id
    limit 1;
  end if;

  if found then
    update public.pos_customers
    set email = case when email = '' then email_value else email end,
        phone = case when phone = '' then phone_value else phone end,
        normalized_phone = case when normalized_phone = '' then normalized_phone_value else normalized_phone end,
        address1 = case when address1 = '' then address_value else address1 end,
        updated_by = coalesce(nullif(trim(staff_name), ''), updated_by)
    where id = customer_row.id
    returning * into customer_row;
    return customer_row.id;
  end if;

  insert into public.pos_customers (
    customer_code, store_id, first_name, last_name, phone, normalized_phone,
    email, address1, customer_group, notes, created_by, updated_by
  ) values (
    'CUS-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
    target_store_id,
    first_name_value,
    last_name_value,
    phone_value,
    normalized_phone_value,
    email_value,
    address_value,
    'Regular Customer',
    '',
    coalesce(nullif(trim(staff_name), ''), 'POS'),
    coalesce(nullif(trim(staff_name), ''), 'POS')
  ) returning * into customer_row;

  return customer_row.id;
end;
$$;

revoke all on function public.pos_link_buyback_customer(bigint, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.pos_link_buyback_customer(bigint, text, text, text, text, text)
  to service_role;

comment on function public.pos_link_buyback_customer(bigint, text, text, text, text, text) is
  'Finds or creates the customer record behind a buyback seller. Matches on phone number, then email; only fills in contact details the existing record is missing.';

-- 5. Intake: no condition, no sale price, no check reference; a customer, a
--    buyback number and the payout destination instead.
do $migration$
declare
  definition text;
  patched text;
  previous text;
begin
  select replace(pg_get_functiondef(oid), chr(13), '') into definition
  from pg_proc
  where proname = 'create_pos_used_device_acquisition' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'create_pos_used_device_acquisition was not found'; end if;

  patched := definition;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  intake_photo_count integer;$anchor$,
    $replacement$  intake_photo_count integer;
  condition_grade_value text := coalesce(nullif(trim(payload->>'condition_grade'), ''), 'Good');
  payout_method_value text := trim(coalesce(payload->>'payout_method', ''));
  payout_reference_type_value text := trim(coalesce(payload->>'payout_reference_type', ''));
  payout_payid_value text := trim(coalesce(payload->>'payout_payid', ''));
  payout_bsb_value text := regexp_replace(coalesce(payload->>'payout_bsb', ''), '[^0-9]', '', 'g');
  payout_account_number_value text := regexp_replace(coalesce(payload->>'payout_account_number', ''), '[^0-9]', '', 'g');
  payout_account_name_value text := trim(coalesce(payload->>'payout_account_name', ''));
  buyback_number_value bigint;
  customer_id_value bigint;$replacement$
  );
  if patched = previous then
    raise exception 'buyback intake patch: the declaration anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  if trim(coalesce(payload->>'condition_grade', '')) not in ('As New', 'Good', 'Fair', 'Poor', 'Faulty') then
    raise exception 'Device condition is required';
  end if;$anchor$,
    $replacement$  -- Condition is graded once the device has been cleaned up and listed, not
  -- while the seller is waiting. Intake records a default it can be corrected
  -- from.
  if condition_grade_value not in ('As New', 'Good', 'Fair', 'Poor', 'Faulty') then
    raise exception 'Invalid device condition';
  end if;$replacement$
  );
  if patched = previous then
    raise exception 'buyback intake patch: the condition anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  if clean_status_value = 'Clean' and trim(coalesce(payload->>'clean_check_reference', '')) = '' then
    raise exception 'IMEI check reference is required for a clean result';
  end if;
$anchor$,
    ''
  );
  if patched = previous then
    raise exception 'buyback intake patch: the check reference anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  if purchase_cost_value <= 0 or sale_price_value <= 0 then raise exception 'Purchase cost and sale price must be above zero'; end if;$anchor$,
    $replacement$  if purchase_cost_value <= 0 then raise exception 'Purchase price must be above zero'; end if;
  -- The device is priced for sale after inspection, so intake may leave it at
  -- zero. The ready-for-sale gate refuses to shelf a device without a price.
  if sale_price_value < 0 then raise exception 'Sale price cannot be negative'; end if;$replacement$
  );
  if patched = previous then
    raise exception 'buyback intake patch: the price anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  if trim(coalesce(payload->>'payout_method', '')) not in ('Cash', 'Bank Transfer') then raise exception 'Invalid payout method'; end if;$anchor$,
    $replacement$  if payout_method_value not in ('Cash', 'Bank Transfer') then raise exception 'Invalid payout method'; end if;
  -- A transfer has to say where it went, or the payout cannot be proved later.
  if payout_method_value = 'Bank Transfer' then
    if payout_reference_type_value not in ('PayID', 'Bank Account') then
      raise exception 'Record the PayID or the bank account the transfer was sent to';
    end if;
    if payout_reference_type_value = 'PayID' and payout_payid_value = '' then
      raise exception 'A PayID payout needs the mobile number or email it was sent to';
    end if;
    if payout_reference_type_value = 'Bank Account' then
      if length(payout_bsb_value) <> 6 then raise exception 'A BSB contains six digits'; end if;
      if length(payout_account_number_value) < 5 then raise exception 'Record the account number the transfer was sent to'; end if;
      if payout_account_name_value = '' then raise exception 'Record the account name the transfer was sent to'; end if;
    end if;
  else
    payout_reference_type_value := '';
    payout_payid_value := '';
    payout_bsb_value := '';
    payout_account_number_value := '';
    payout_account_name_value := '';
  end if;
  if payout_reference_type_value = 'PayID' then
    payout_bsb_value := '';
    payout_account_number_value := '';
    payout_account_name_value := '';
  elsif payout_reference_type_value = 'Bank Account' then
    payout_payid_value := '';
  end if;$replacement$
  );
  if patched = previous then
    raise exception 'buyback intake patch: the payout anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  insert into public.pos_used_device_acquisitions (
    acquisition_code, store_id, shift_id, seller_name, seller_phone, seller_email,
    seller_address, seller_id_type, seller_id_reference, seller_age_confirmed,
    seller_is_owner, owner_name, owner_address, acquisition_statement,
    ownership_declaration, payout_method, payout_amount, declaration_text,
    acquired_by
  ) values ($anchor$,
    $replacement$  -- The seller is a customer of this shop like any other.
  customer_id_value := public.pos_link_buyback_customer(
    selected_store.id, seller_name_value, seller_phone_value,
    payload->>'seller_email', seller_address_value, selected_staff.display_name
  );

  insert into public.pos_store_buyback_counters (store_id, last_number)
  values (selected_store.id, 1)
  on conflict (store_id) do update
  set last_number = public.pos_store_buyback_counters.last_number + 1,
      updated_at = now()
  returning last_number into buyback_number_value;

  insert into public.pos_used_device_acquisitions (
    acquisition_code, store_id, shift_id, seller_name, seller_phone, seller_email,
    seller_address, seller_id_type, seller_id_reference, seller_age_confirmed,
    seller_is_owner, owner_name, owner_address, acquisition_statement,
    ownership_declaration, payout_method, payout_amount, declaration_text,
    acquired_by, buyback_number, customer_id, payout_reference_type,
    payout_payid, payout_bsb, payout_account_number, payout_account_name
  ) values ($replacement$
  );
  if patched = previous then
    raise exception 'buyback intake patch: the acquisition insert anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$    declaration_value,
    selected_staff.display_name
  ) returning * into acquisition_row;$anchor$,
    $replacement$    declaration_value,
    selected_staff.display_name,
    buyback_number_value,
    customer_id_value,
    payout_reference_type_value,
    payout_payid_value,
    payout_bsb_value,
    payout_account_number_value,
    payout_account_name_value
  ) returning * into acquisition_row;$replacement$
  );
  if patched = previous then
    raise exception 'buyback intake patch: the acquisition values anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$    trim(payload->>'condition_grade'),$anchor$,
    $replacement$    condition_grade_value,$replacement$
  );
  if patched = previous then
    raise exception 'buyback intake patch: the device condition value anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$    trim(payload->>'payout_method'),$anchor$,
    $replacement$    payout_method_value,$replacement$
  );
  if patched = previous then
    raise exception 'buyback intake patch: the payout method value anchor was not found';
  end if;

  execute patched;
end;
$migration$;

comment on function public.create_pos_used_device_acquisition(text, jsonb) is
  'POS buyback intake: store-authorized purchase with at least one intake photo, claimed atomically with the acquisition. Numbers the purchase per store, records the seller as a customer, records where a bank payout went, and starts the device in inspection without a condition grade or sale price.';

-- 6. The listing step is where a price is required.
do $migration$
declare
  definition text;
  patched text;
  previous text;
begin
  select replace(pg_get_functiondef(oid), chr(13), '') into definition
  from pg_proc
  where proname = 'update_pos_used_device' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'update_pos_used_device was not found'; end if;

  patched := definition;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  if price_value <= 0 then raise exception 'Sale price must be above zero'; end if;$anchor$,
    $replacement$  if price_value < 0 then raise exception 'Sale price cannot be negative'; end if;
  if status_value = 'ready_for_sale' and price_value <= 0 then
    raise exception 'Set a sale price before this device is ready for sale';
  end if;$replacement$
  );
  if patched = previous then
    raise exception 'buyback intake patch: the update price anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  if clean_status_value = 'Clean' and trim(clean_reference_value) = '' then raise exception 'IMEI check reference is required for a clean result'; end if;
$anchor$,
    ''
  );
  if patched = previous then
    raise exception 'buyback intake patch: the update check reference anchor was not found';
  end if;

  execute patched;
end;
$migration$;

-- 7. The POS shows the buyback number on the device it bought. The payout
--    amount and the bank details stay out of the staff payload, like every
--    other cost figure.
do $migration$
declare
  definition text;
  patched text;
begin
  select replace(pg_get_functiondef(oid), chr(13), '') into definition
  from pg_proc
  where proname = 'pos_used_device_payload' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'pos_used_device_payload was not found'; end if;

  patched := replace(
    definition,
    $anchor$      'id', acquisition.acquisition_code,
      'shift_id', acquisition.shift_id,$anchor$,
    $replacement$      'id', acquisition.acquisition_code,
      'buyback_number', acquisition.buyback_number,
      'shift_id', acquisition.shift_id,$replacement$
  );
  if patched = definition then
    raise exception 'buyback intake patch: the payload acquisition anchor was not found';
  end if;

  execute patched;
end;
$migration$;

-- 8. One customer, both sides of the counter: what they bought from the shop is
--    already answerable; this is what the shop bought from them.
create or replace function public.get_pos_customer_buybacks(
  session_token text,
  target_store_code text,
  customer_code text default '',
  search_query text default '',
  result_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  customer_row public.pos_customers%rowtype;
  -- Named apart from the column it is compared against, or the lookup below is
  -- an ambiguous reference.
  customer_code_value text := trim(coalesce(customer_code, ''));
  query_value text := trim(coalesce(search_query, ''));
  phone_query text := regexp_replace(coalesce(search_query, ''), '[^0-9]', '', 'g');
  safe_limit integer := least(greatest(coalesce(result_limit, 100), 1), 200);
  rows_payload jsonb;
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid session'; end if;
  perform public.pos_authorized_actor(session_token, target_store_code, null);

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = coalesce(trim(target_store_code), '')
    and store_location.store_code <> 'warehouse';
  if not found then raise exception 'Store not found'; end if;

  select * into customer_row
  from public.pos_customers customer
  where customer.customer_code = customer_code_value
  limit 1;

  if customer_row.id is null and char_length(query_value) < 2 then
    return jsonb_build_object('ok', true, 'buybacks', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.acquired_at desc), '[]'::jsonb)
  into rows_payload
  from (
    select
      acquisition.acquisition_code as id,
      acquisition.buyback_number,
      acquisition.acquired_at,
      acquisition.acquired_by,
      acquisition.payout_method,
      acquisition.seller_name,
      acquisition.seller_phone,
      (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', device.device_code,
          'brand', device.brand,
          'model', device.model,
          'storage', device.storage,
          'color', device.color,
          'category', device.category,
          'status', device.status
        ) order by device.id), '[]'::jsonb)
        from public.pos_used_devices device
        where device.acquisition_id = acquisition.id
      ) as devices
    from public.pos_used_device_acquisitions acquisition
    where acquisition.store_id = selected_store.id
      and (
        (customer_row.id is not null and acquisition.customer_id = customer_row.id)
        or (
          phone_query <> ''
          and regexp_replace(acquisition.seller_phone, '[^0-9]', '', 'g') = phone_query
        )
        or (
          phone_query = ''
          and query_value <> ''
          and lower(acquisition.seller_name) = lower(query_value)
        )
      )
    order by acquisition.acquired_at desc
    limit safe_limit
  ) row_data;

  return jsonb_build_object('ok', true, 'buybacks', rows_payload);
end;
$$;

revoke all on function public.get_pos_customer_buybacks(text, text, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.get_pos_customer_buybacks(text, text, text, text, integer)
  to anon, authenticated, service_role;

comment on function public.get_pos_customer_buybacks(text, text, text, text, integer) is
  'The devices this store has bought from one customer, newest first. Carries no payout amount: what the shop paid is admin-only, like every other cost figure in the POS.';

comment on table public.pos_store_buyback_counters is
  'Per-store buyback numbering, the same shape as the invoice counters. A buyback number is what the seller is quoted.';
