alter table public.pos_sales_orders
add column if not exists invoice_number bigint;

alter table public.pos_sales_orders
alter column invoice_number drop identity if exists;

drop index if exists public.pos_sales_orders_invoice_number_key;
drop sequence if exists public.pos_sales_orders_invoice_number_seq;

create table if not exists public.pos_store_invoice_counters (
  store_id bigint primary key references public.store_locations(id) on delete restrict,
  last_number bigint not null default 0 check (last_number >= 0),
  updated_at timestamptz not null default now()
);

drop trigger if exists pos_store_invoice_counters_set_updated_at on public.pos_store_invoice_counters;
create trigger pos_store_invoice_counters_set_updated_at
before update on public.pos_store_invoice_counters
for each row
execute function public.set_updated_at();

alter table public.pos_store_invoice_counters enable row level security;
revoke all on public.pos_store_invoice_counters from public, anon, authenticated;
grant select, insert, update on public.pos_store_invoice_counters to service_role;

with renumbered as (
  select
    sales_order.id,
    row_number() over (
      partition by sales_order.store_id
      order by sales_order.created_at, sales_order.id
    )::bigint as invoice_number
  from public.pos_sales_orders sales_order
)
update public.pos_sales_orders sales_order
set invoice_number = renumbered.invoice_number
from renumbered
where renumbered.id = sales_order.id;

alter table public.pos_sales_orders
alter column invoice_number set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'pos_sales_orders_invoice_number_positive'
      and conrelid = 'public.pos_sales_orders'::regclass
  ) then
    alter table public.pos_sales_orders
    add constraint pos_sales_orders_invoice_number_positive
    check (invoice_number > 0);
  end if;
end;
$$;

create unique index if not exists pos_sales_orders_store_invoice_number_key
on public.pos_sales_orders (store_id, invoice_number);

insert into public.pos_store_invoice_counters (store_id, last_number)
select
  store_location.id,
  coalesce(max(sales_order.invoice_number), 0)
from public.store_locations store_location
left join public.pos_sales_orders sales_order
  on sales_order.store_id = store_location.id
group by store_location.id
on conflict (store_id) do update
set
  last_number = excluded.last_number,
  updated_at = now();

create or replace function public.pos_sales_order_payload(order_row public.pos_sales_orders)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select order_row.order_payload || jsonb_build_object(
    'id', order_row.order_code,
    'invoice_number', order_row.invoice_number,
    'store_db_code', store_location.store_code,
    'store_name', store_location.store_name,
    'business_date', order_row.business_date,
    'staff_name', order_row.staff_name,
    'customer_name', order_row.customer_name,
    'customer_phone', order_row.customer_phone,
    'customer_email', order_row.customer_email,
    'payment_method', order_row.payment_method,
    'total', order_row.total,
    'receipt_email_count', order_row.receipt_email_count,
    'last_receipt_email', order_row.last_receipt_email,
    'receipt_emailed_at', order_row.receipt_emailed_at,
    'created_at', order_row.created_at,
    'database_saved_at', order_row.updated_at,
    'sync_pending', false
  )
  from public.store_locations store_location
  where store_location.id = order_row.store_id;
$$;

create or replace function public.save_pos_sales_order(session_token text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_store public.store_locations%rowtype;
  selected_staff public.staff_directory%rowtype;
  saved_order public.pos_sales_orders%rowtype;
  order_code_value text;
  created_at_value timestamptz;
  business_date_value date;
  total_value numeric(12,2);
  payment_total numeric(12,2);
  next_invoice_number bigint;
begin
  if not public.is_valid_staff_session(session_token) then
    raise exception 'Invalid session';
  end if;

  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Order payload must be a JSON object';
  end if;

  order_code_value := coalesce(trim(payload->>'id'), '');
  if order_code_value = '' then
    raise exception 'Order id is required';
  end if;

  if jsonb_typeof(payload->'items') <> 'array' or jsonb_array_length(payload->'items') = 0 then
    raise exception 'Order must contain at least one item';
  end if;

  if jsonb_typeof(payload->'payments') <> 'array' or jsonb_array_length(payload->'payments') = 0 then
    raise exception 'Order must contain at least one payment';
  end if;

  total_value := round(coalesce(nullif(payload->>'total', '')::numeric, 0), 2);
  if total_value < 0 then
    raise exception 'Order total cannot be negative';
  end if;

  select round(coalesce(sum(coalesce(nullif(payment->>'amount', '')::numeric, 0)), 0), 2)
  into payment_total
  from jsonb_array_elements(payload->'payments') payment;

  if payment_total < total_value then
    raise exception 'Payment total is less than order total';
  end if;

  select *
  into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and (
      lower(regexp_replace(store_location.store_code, '[^a-z0-9]', '', 'g')) =
        lower(regexp_replace(coalesce(payload->>'store_db_code', payload->>'store_id', ''), '[^a-z0-9]', '', 'g'))
      or upper(store_location.store_code) = upper(coalesce(payload->>'store_code', ''))
    )
  limit 1;

  if not found then
    raise exception 'Store not found';
  end if;

  select *
  into selected_staff
  from public.staff_directory staff
  where staff.active = true
    and lower(staff.display_name) = lower(coalesce(trim(payload->>'staff_name'), ''))
  limit 1;

  if not found then
    raise exception 'Staff member not found';
  end if;

  created_at_value := coalesce(nullif(payload->>'created_at', '')::timestamptz, now());
  business_date_value := coalesce(
    nullif(payload->>'business_date', '')::date,
    (created_at_value at time zone 'Australia/Brisbane')::date
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(order_code_value, 0)
  );

  select *
  into saved_order
  from public.pos_sales_orders sales_order
  where sales_order.order_code = order_code_value
  for update;

  if found then
    if saved_order.store_id <> selected_store.id then
      raise exception 'Order store cannot be changed';
    end if;

    update public.pos_sales_orders
    set
      business_date = business_date_value,
      staff_name = selected_staff.display_name,
      shift_id = nullif(trim(payload->>'shift_id'), ''),
      customer_name = coalesce(nullif(trim(payload->>'customer_name'), ''), 'Walk-in Customer'),
      customer_phone = coalesce(trim(payload->>'customer_phone'), ''),
      customer_email = coalesce(trim(payload->>'customer_email'), ''),
      payment_method = coalesce(nullif(trim(payload->>'payment_method'), ''), 'Unknown'),
      total = total_value,
      order_payload = payload || jsonb_build_object('sync_pending', false),
      updated_at = now()
    where order_code = order_code_value
    returning * into saved_order;
  else
    insert into public.pos_store_invoice_counters (store_id, last_number)
    values (selected_store.id, 1)
    on conflict (store_id) do update
    set
      last_number = public.pos_store_invoice_counters.last_number + 1,
      updated_at = now()
    returning last_number into next_invoice_number;

    insert into public.pos_sales_orders (
      order_code,
      invoice_number,
      store_id,
      business_date,
      staff_name,
      shift_id,
      customer_name,
      customer_phone,
      customer_email,
      payment_method,
      total,
      order_payload,
      created_at
    )
    values (
      order_code_value,
      next_invoice_number,
      selected_store.id,
      business_date_value,
      selected_staff.display_name,
      nullif(trim(payload->>'shift_id'), ''),
      coalesce(nullif(trim(payload->>'customer_name'), ''), 'Walk-in Customer'),
      coalesce(trim(payload->>'customer_phone'), ''),
      coalesce(trim(payload->>'customer_email'), ''),
      coalesce(nullif(trim(payload->>'payment_method'), ''), 'Unknown'),
      total_value,
      payload || jsonb_build_object('sync_pending', false),
      created_at_value
    )
    returning * into saved_order;
  end if;

  return jsonb_build_object(
    'ok', true,
    'order', public.pos_sales_order_payload(saved_order)
  );
end;
$$;

drop function if exists public.reseed_pos_invoice_number();

create or replace function public.reseed_pos_store_invoice_counters()
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  next_numbers jsonb;
begin
  insert into public.pos_store_invoice_counters (store_id, last_number)
  select
    store_location.id,
    coalesce(max(sales_order.invoice_number), 0)
  from public.store_locations store_location
  left join public.pos_sales_orders sales_order
    on sales_order.store_id = store_location.id
  group by store_location.id
  on conflict (store_id) do update
  set
    last_number = excluded.last_number,
    updated_at = now();

  select coalesce(
    jsonb_object_agg(store_location.store_code, counter.last_number + 1),
    '{}'::jsonb
  )
  into next_numbers
  from public.pos_store_invoice_counters counter
  join public.store_locations store_location
    on store_location.id = counter.store_id;

  return next_numbers;
end;
$$;

revoke execute on function public.reseed_pos_store_invoice_counters() from public, anon, authenticated;
grant execute on function public.reseed_pos_store_invoice_counters() to service_role;

