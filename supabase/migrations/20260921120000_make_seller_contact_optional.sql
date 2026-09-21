-- A seller's phone number and email are optional at the counter.
--
-- Not every seller wants to leave a number, and the purchase does not depend on
-- one: identity is the ID document sighted and recorded, which stays required.
--
-- Two things leaned on the phone number and are adjusted with it:
--
--   * The seller becomes a customer by matching on phone, then email. With
--     neither, there is nothing reliable to match a repeat visit against, so
--     the purchase is saved without a customer link rather than creating a
--     fresh duplicate customer every time.
--   * The repeat-seller alert only looked at purchases that had a phone
--     number, so a seller who left it blank was never counted -- not even by
--     their ID, which was being compared only among sellers with phones. It now
--     counts everyone by ID, and by phone where there is one.

-- 1. The purchase no longer requires a phone number.
do $migration$
declare
  definition text;
  patched text;
begin
  select replace(pg_get_functiondef('public.create_pos_used_device_acquisition(text,jsonb)'::regprocedure), chr(13), '')
    into definition;
  patched := replace(
    definition,
    $anchor$  if seller_phone_value = '' then raise exception 'Seller phone is required'; end if;$anchor$,
    $replacement$  -- Phone and email are optional; the ID sighted below is what identifies the seller.$replacement$
  );
  if patched = definition then
    raise exception 'optional contact patch: the phone requirement anchor was not found';
  end if;
  execute patched;
end;
$migration$;

-- 2. Link the seller to a customer by phone, then email; with neither, leave it.
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
  -- Without a phone or an email a returning seller could never be matched, so
  -- every visit would add another copy of the same person.
  if name_value = '' or (normalized_phone_value = '' and email_value = '') then return null; end if;

  if normalized_phone_value <> '' then
    select * into customer_row
    from public.pos_customers customer
    where customer.active
      and customer.normalized_phone = normalized_phone_value
    order by customer.updated_at desc, customer.id
    limit 1;
  end if;

  if customer_row.id is null and email_value <> '' then
    select * into customer_row
    from public.pos_customers customer
    where customer.active
      and lower(customer.email) = email_value
    order by customer.updated_at desc, customer.id
    limit 1;
  end if;

  if customer_row.id is not null then
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

comment on function public.pos_link_buyback_customer(bigint, text, text, text, text, text) is
  'Finds or creates the customer record behind a buyback seller. Matches on phone number, then email; with neither the purchase is left unlinked. Only fills in contact details an existing record is missing.';

-- 3. Repeat sellers are counted by ID for everyone, and by phone where given.
do $migration$
declare
  definition text;
  patched text;
begin
  select replace(pg_get_functiondef('public.get_admin_used_device_alerts(text,integer)'::regprocedure), chr(13), '')
    into definition;
  patched := replace(
    definition,
    $anchor$  repeat_sellers as (
    select recent.*, count(*) over (partition by recent.phone_digits) as phone_visits,
      count(*) over (partition by lower(recent.seller_id_reference)) as id_visits
    from recent where recent.phone_digits <> ''
  ),$anchor$,
    $replacement$  repeat_sellers as (
    select recent.*,
      case when recent.phone_digits <> ''
        then count(*) over (partition by recent.phone_digits) else 0 end as phone_visits,
      count(*) over (partition by lower(recent.seller_id_reference)) as id_visits
    from recent
  ),$replacement$
  );
  if patched = definition then
    raise exception 'optional contact patch: the repeat seller anchor was not found';
  end if;
  execute patched;
end;
$migration$;
