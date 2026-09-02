-- Generalizes the RepairDesk invoice customer sync so it can run per store.
--
-- The Toowong-only entry point is kept as a thin wrapper so existing runbooks
-- and any recorded history keep working unchanged.

create or replace function public.sync_repairdesk_invoice_customers(target_store_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  source_customer record;
  matched_customer_id bigint;
  customer_code_value text;
  source_code_value text;
  store_display_name text;
  created_count integer := 0;
  updated_count integer := 0;
  source_count integer := 0;
begin
  select rules.display_name
  into store_display_name
  from (
    values
      ('toowong',   'TechM8 Toowong'),
      ('fairfield', 'TechM8 Fairfield')
  ) as rules(store_code, display_name)
  where rules.store_code = target_store_code;

  if store_display_name is null then
    raise exception 'Store "%" is not approved for RepairDesk invoice customer sync', target_store_code;
  end if;

  for source_customer in
    with raw_customers as (
      select
        sales_order.invoice_number,
        sales_order.created_at,
        coalesce(
          nullif(trim(sales_order.order_payload #>> '{source_customer,name}'), ''),
          nullif(trim(sales_order.customer_name), '')
        ) as full_name,
        trim(coalesce(sales_order.order_payload #>> '{source_customer,first_name}', '')) as first_name,
        trim(coalesce(sales_order.order_payload #>> '{source_customer,last_name}', '')) as last_name,
        trim(coalesce(sales_order.order_payload #>> '{source_customer,phone}', sales_order.customer_phone, '')) as phone,
        lower(trim(coalesce(sales_order.order_payload #>> '{source_customer,email}', sales_order.customer_email, ''))) as email,
        trim(coalesce(sales_order.order_payload #>> '{source_customer,address}', '')) as address1,
        trim(coalesce(sales_order.order_payload #>> '{source_customer,city}', '')) as city,
        trim(coalesce(sales_order.order_payload #>> '{source_customer,state}', '')) as state,
        trim(coalesce(sales_order.order_payload #>> '{source_customer,postcode}', '')) as postcode,
        trim(coalesce(sales_order.order_payload #>> '{source_customer,country}', '')) as country,
        trim(coalesce(sales_order.order_payload #>> '{source_customer,driving_licence}', '')) as driving_licence,
        store_location.id as store_id
      from public.pos_sales_orders sales_order
      join public.store_locations store_location on store_location.id = sales_order.store_id
      where store_location.store_code = target_store_code
        and lower(coalesce(sales_order.order_payload->>'legacy_import', 'false')) = 'true'
        and lower(coalesce(sales_order.order_payload->>'source_system', '')) = 'repairdesk'
    ), normalized_customers as (
      select
        raw_customer.*,
        lower(trim(regexp_replace(coalesce(raw_customer.full_name, ''), '\s+', ' ', 'g'))) as name_key,
        case
          when regexp_replace(raw_customer.phone, '[^0-9]', '', 'g') like '61%'
            and length(regexp_replace(raw_customer.phone, '[^0-9]', '', 'g')) = 11
            then '0' || substr(regexp_replace(raw_customer.phone, '[^0-9]', '', 'g'), 3)
          else regexp_replace(raw_customer.phone, '[^0-9]', '', 'g')
        end as normalized_phone
      from raw_customers raw_customer
    ), valid_customers as (
      select
        normalized_customer.*,
        case
          when normalized_customer.normalized_phone <> ''
            then 'phone:' || normalized_customer.normalized_phone || '|name:' || normalized_customer.name_key
          else 'email:' || normalized_customer.email || '|name:' || normalized_customer.name_key
        end as canonical_key
      from normalized_customers normalized_customer
      where normalized_customer.name_key not in ('', 'walkin customer', 'walk in customer')
        and (normalized_customer.normalized_phone <> '' or normalized_customer.email <> '')
    ), ranked_customers as (
      select
        valid_customer.*,
        row_number() over (
          partition by valid_customer.canonical_key
          order by valid_customer.created_at desc, valid_customer.invoice_number desc
        ) as customer_rank,
        min(valid_customer.invoice_number) over (partition by valid_customer.canonical_key) as first_invoice_number,
        max(valid_customer.invoice_number) over (partition by valid_customer.canonical_key) as last_invoice_number
      from valid_customers valid_customer
    )
    select *
    from ranked_customers ranked_customer
    where ranked_customer.customer_rank = 1
  loop
    matched_customer_id := null;
    select customer.id
    into matched_customer_id
    from public.pos_customers customer
    where customer.active = true
      and lower(trim(regexp_replace(concat_ws(' ', customer.first_name, customer.last_name), '\s+', ' ', 'g'))) = source_customer.name_key
      and (
        (source_customer.normalized_phone <> '' and customer.normalized_phone = source_customer.normalized_phone)
        or (source_customer.email <> '' and lower(customer.email) = source_customer.email)
      )
    order by customer.updated_at desc, customer.id
    limit 1;

    source_code_value := 'INV-CUS-' || upper(substr(md5(source_customer.canonical_key), 1, 20));

    if matched_customer_id is null then
      customer_code_value := 'RD-' || source_code_value;
      insert into public.pos_customers (
        customer_code,
        store_id,
        first_name,
        last_name,
        company,
        phone,
        normalized_phone,
        alert_number,
        email,
        customer_group,
        notes,
        created_by,
        updated_by,
        active,
        source_system,
        source_store_name,
        source_customer_code,
        address1,
        address2,
        postcode,
        city,
        state,
        country,
        driving_licence,
        referred_by,
        contact_person
      ) values (
        customer_code_value,
        source_customer.store_id,
        coalesce(nullif(source_customer.first_name, ''), source_customer.full_name),
        source_customer.last_name,
        '',
        source_customer.phone,
        source_customer.normalized_phone,
        '',
        source_customer.email,
        'Regular Customer',
        '',
        'RepairDesk invoice import',
        'RepairDesk invoice import',
        true,
        'repairdesk',
        store_display_name,
        source_code_value,
        source_customer.address1,
        '',
        source_customer.postcode,
        source_customer.city,
        source_customer.state,
        source_customer.country,
        source_customer.driving_licence,
        '',
        ''
      )
      on conflict (customer_code) do update set
        active = true,
        updated_by = excluded.updated_by,
        updated_at = now()
      returning id into matched_customer_id;
      created_count := created_count + 1;
    else
      update public.pos_customers customer
      set
        phone = case when customer.phone = '' then source_customer.phone else customer.phone end,
        normalized_phone = case when customer.normalized_phone = '' then source_customer.normalized_phone else customer.normalized_phone end,
        email = case when customer.email = '' then source_customer.email else customer.email end,
        address1 = case when customer.address1 = '' then source_customer.address1 else customer.address1 end,
        postcode = case when customer.postcode = '' then source_customer.postcode else customer.postcode end,
        city = case when customer.city = '' then source_customer.city else customer.city end,
        state = case when customer.state = '' then source_customer.state else customer.state end,
        country = case when customer.country = '' then source_customer.country else customer.country end,
        driving_licence = case when customer.driving_licence = '' then source_customer.driving_licence else customer.driving_licence end,
        updated_by = 'RepairDesk invoice import',
        updated_at = now()
      where customer.id = matched_customer_id;
      updated_count := updated_count + 1;
    end if;

    insert into public.pos_customer_sources (
      customer_id,
      source_system,
      source_store_name,
      source_customer_code,
      source_payload
    ) values (
      matched_customer_id,
      'repairdesk',
      store_display_name,
      source_code_value,
      jsonb_build_object(
        'source', 'RepairDesk invoice history',
        'canonical_key', source_customer.canonical_key,
        'first_invoice_number', source_customer.first_invoice_number,
        'last_invoice_number', source_customer.last_invoice_number,
        'name', source_customer.full_name,
        'phone', source_customer.phone,
        'email', source_customer.email
      )
    )
    on conflict (source_system, source_store_name, source_customer_code) do update set
      customer_id = excluded.customer_id,
      source_payload = excluded.source_payload,
      imported_at = now();
    source_count := source_count + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'store_code', target_store_code,
    'created_customers', created_count,
    'updated_customers', updated_count,
    'source_records', source_count
  );
end;
$$;

create or replace function public.sync_repairdesk_toowong_invoice_customers()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.sync_repairdesk_invoice_customers('toowong');
$$;

revoke all on function public.sync_repairdesk_invoice_customers(text) from public;
revoke all on function public.sync_repairdesk_invoice_customers(text) from anon;
revoke all on function public.sync_repairdesk_invoice_customers(text) from authenticated;
grant execute on function public.sync_repairdesk_invoice_customers(text) to service_role;

revoke all on function public.sync_repairdesk_toowong_invoice_customers() from public;
revoke all on function public.sync_repairdesk_toowong_invoice_customers() from anon;
revoke all on function public.sync_repairdesk_toowong_invoice_customers() from authenticated;
grant execute on function public.sync_repairdesk_toowong_invoice_customers() to service_role;

comment on function public.sync_repairdesk_invoice_customers(text) is
  'Creates or enriches searchable POS customer records from protected RepairDesk invoice history for one approved store.';

comment on function public.sync_repairdesk_toowong_invoice_customers() is
  'Toowong-only entry point kept for existing runbooks; delegates to sync_repairdesk_invoice_customers.';
