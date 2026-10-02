-- Product project: China purchase tracking.
-- Supplier order -> domestic parcel -> forwarder batch -> arrival in Australia
-- -> sign + count -> stock into a store. Browser roles never touch these
-- tables; the admin-purchasing Edge Function verifies the admin session and
-- calls the service-role functions below.

alter table public.suppliers
  add column if not exists wechat text,
  add column if not exists platform text,
  add column if not exists is_active boolean not null default true;

create table if not exists public.purchase_forwarders (
  id bigint generated always as identity primary key,
  name text not null,
  tracking_url text,
  website_url text,
  warehouse_address text,
  contact text,
  channels text[] not null default '{}',
  tracking_prefixes text[] not null default '{}',
  notes text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint purchase_forwarders_name_present check (btrim(name) <> '')
);
create unique index if not exists purchase_forwarders_name_key
  on public.purchase_forwarders (lower(btrim(name)));

create sequence if not exists public.purchase_order_number_seq;
create sequence if not exists public.purchase_shipment_number_seq;

create table if not exists public.purchase_orders (
  id bigint generated always as identity primary key,
  po_number text not null unique
    default ('PO-' || lpad(nextval('public.purchase_order_number_seq')::text, 5, '0')),
  supplier_id bigint references public.suppliers(id) on delete set null,
  supplier_order_ref text,
  order_date date not null default (timezone('Australia/Brisbane', now()))::date,
  currency text not null default 'CNY' check (currency in ('CNY', 'AUD', 'USD')),
  goods_amount numeric(12,2) check (goods_amount >= 0),
  domestic_shipping_amount numeric(12,2) not null default 0 check (domestic_shipping_amount >= 0),
  invoice_received_at date,
  paid_amount numeric(12,2) check (paid_amount >= 0),
  paid_at date,
  payment_method text,
  payment_ref text,
  cancelled_at timestamptz,
  notes text,
  source text not null default 'admin',
  source_ref text,
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.purchase_order_items (
  id bigint generated always as identity primary key,
  purchase_order_id bigint not null references public.purchase_orders(id) on delete cascade,
  line_no integer not null default 1,
  description text not null check (btrim(description) <> ''),
  quantity integer not null check (quantity > 0 and quantity <= 1000000),
  unit_cost numeric(12,4) check (unit_cost >= 0),
  product_id bigint references public.products(id) on delete set null,
  declared_name text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists purchase_order_items_order_idx
  on public.purchase_order_items (purchase_order_id, line_no);

create table if not exists public.purchase_shipments (
  id bigint generated always as identity primary key,
  shipment_number text not null unique
    default ('SH-' || lpad(nextval('public.purchase_shipment_number_seq')::text, 5, '0')),
  forwarder_id bigint references public.purchase_forwarders(id) on delete set null,
  channel text,
  tracking_numbers text[] not null default '{}',
  status text not null default 'draft'
    check (status in ('draft', 'declared', 'shipped', 'arrived', 'received', 'stocked', 'closed')),
  declared_at date,
  shipped_at date,
  eta date,
  arrived_at date,
  received_at timestamptz,
  received_by text,
  received_store_id bigint references public.stores(id) on delete set null,
  received_cartons integer check (received_cartons >= 0),
  stocked_at timestamptz,
  stocked_by text,
  freight_amount numeric(12,2) check (freight_amount >= 0),
  freight_currency text not null default 'CNY' check (freight_currency in ('CNY', 'AUD', 'USD')),
  weight_kg numeric(10,2) check (weight_kg >= 0),
  notes text,
  source text not null default 'admin',
  source_ref text,
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists purchase_shipments_status_idx on public.purchase_shipments (status);

create table if not exists public.purchase_parcels (
  id bigint generated always as identity primary key,
  purchase_order_id bigint references public.purchase_orders(id) on delete set null,
  supplier_id bigint references public.suppliers(id) on delete set null,
  contents text not null default '',
  courier text,
  tracking_no text,
  carton_count integer not null default 1 check (carton_count between 0 and 10000),
  shipped_at date,
  forwarder_id bigint references public.purchase_forwarders(id) on delete set null,
  channel text,
  forwarder_received_at date,
  forwarder_ref text,
  shipment_id bigint references public.purchase_shipments(id) on delete set null,
  declared_value numeric(12,2) check (declared_value >= 0),
  has_battery boolean not null default false,
  has_magnet boolean not null default false,
  weight_kg numeric(10,2) check (weight_kg >= 0),
  notes text,
  source text not null default 'admin',
  source_ref text,
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint purchase_parcels_identifiable
    check (btrim(contents) <> '' or btrim(coalesce(tracking_no, '')) <> '')
);
create index if not exists purchase_parcels_shipment_idx on public.purchase_parcels (shipment_id);
create index if not exists purchase_parcels_order_idx on public.purchase_parcels (purchase_order_id);
create index if not exists purchase_parcels_tracking_idx on public.purchase_parcels (lower(tracking_no));

-- The stock ledger for purchased goods. One posting shares a receipt_key so a
-- retried request can never credit the same count twice.
create table if not exists public.purchase_receipt_lines (
  id bigint generated always as identity primary key,
  receipt_key uuid not null,
  line_no integer not null,
  shipment_id bigint not null references public.purchase_shipments(id) on delete restrict,
  parcel_id bigint references public.purchase_parcels(id) on delete set null,
  purchase_order_item_id bigint references public.purchase_order_items(id) on delete set null,
  product_id bigint not null references public.products(id) on delete restrict,
  store_id bigint not null references public.stores(id) on delete restrict,
  quantity integer not null default 0 check (quantity between 0 and 1000000),
  damaged_quantity integer not null default 0 check (damaged_quantity between 0 and 1000000),
  unit_cost_aud numeric(12,4) check (unit_cost_aud >= 0),
  quantity_before integer not null,
  quantity_after integer not null,
  note text,
  created_by text not null,
  created_at timestamptz not null default now(),
  constraint purchase_receipt_lines_has_quantity check (quantity + damaged_quantity > 0),
  constraint purchase_receipt_lines_balance check (quantity_after = quantity_before + quantity),
  unique (receipt_key, line_no)
);
create index if not exists purchase_receipt_lines_shipment_idx on public.purchase_receipt_lines (shipment_id);
create index if not exists purchase_receipt_lines_item_idx on public.purchase_receipt_lines (purchase_order_item_id);

drop trigger if exists set_updated_at_purchase_forwarders on public.purchase_forwarders;
create trigger set_updated_at_purchase_forwarders before update on public.purchase_forwarders
  for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_purchase_orders on public.purchase_orders;
create trigger set_updated_at_purchase_orders before update on public.purchase_orders
  for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_purchase_order_items on public.purchase_order_items;
create trigger set_updated_at_purchase_order_items before update on public.purchase_order_items
  for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_purchase_shipments on public.purchase_shipments;
create trigger set_updated_at_purchase_shipments before update on public.purchase_shipments
  for each row execute function public.set_updated_at();
drop trigger if exists set_updated_at_purchase_parcels on public.purchase_parcels;
create trigger set_updated_at_purchase_parcels before update on public.purchase_parcels
  for each row execute function public.set_updated_at();

alter table public.purchase_forwarders enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_items enable row level security;
alter table public.purchase_shipments enable row level security;
alter table public.purchase_parcels enable row level security;
alter table public.purchase_receipt_lines enable row level security;

revoke all on table public.purchase_forwarders from public, anon, authenticated;
revoke all on table public.purchase_orders from public, anon, authenticated;
revoke all on table public.purchase_order_items from public, anon, authenticated;
revoke all on table public.purchase_shipments from public, anon, authenticated;
revoke all on table public.purchase_parcels from public, anon, authenticated;
revoke all on table public.purchase_receipt_lines from public, anon, authenticated;
revoke all on sequence public.purchase_order_number_seq from public, anon, authenticated;
revoke all on sequence public.purchase_shipment_number_seq from public, anon, authenticated;

grant all on table public.purchase_forwarders to service_role;
grant all on table public.purchase_orders to service_role;
grant all on table public.purchase_order_items to service_role;
grant all on table public.purchase_shipments to service_role;
grant all on table public.purchase_parcels to service_role;
grant all on table public.purchase_receipt_lines to service_role;
grant usage, select on sequence public.purchase_order_number_seq to service_role;
grant usage, select on sequence public.purchase_shipment_number_seq to service_role;

insert into public.purchase_forwarders (name, tracking_url, website_url, channels, tracking_prefixes, sort_order, notes)
values
  ('FST Express', 'http://139.9.106.206:21000/outtrack?companyId=17', 'http://www.fstexpress.com.au/',
    array['海运普货', '海运纯电', '空运普货', '空运电池', '跨境V5'], array['ACWL', 'BKP'], 10, null),
  ('浩兔', 'http://47.120.76.208:20000/#/tmsouttrack?companyId=21', 'https://ayt.itdida.com/query.xhtml',
    array['海运普货', '空运普货'], array['HT', 'APE'], 20, '第二个查询网站: https://ayt.itdida.com/query.xhtml'),
  ('UPS', 'https://www.ups.com/au/en/services/tracking/information.page', null,
    array['快递'], array['1Z'], 30, null),
  ('FedEx 联邦', 'https://www.fedex.com/zh-cn/tracking.html', null,
    array['快递'], '{}', 40, null)
on conflict do nothing;
