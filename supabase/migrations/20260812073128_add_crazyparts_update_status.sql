create table if not exists public.crazyparts_update_status (
  family text primary key,
  brand text not null,
  schedule_day smallint not null check (schedule_day between 1 and 28),
  sort_order smallint not null,
  status text not null default 'scheduled'
    check (status in ('scheduled', 'running', 'syncing', 'completed', 'failed', 'rate_limited')),
  total_models integer not null default 0 check (total_models >= 0),
  processed_models integer not null default 0 check (processed_models >= 0),
  eligible_models integer not null default 0 check (eligible_models >= 0),
  repair_rows integer not null default 0 check (repair_rows >= 0),
  progress_percent numeric(5,2) not null default 0
    check (progress_percent between 0 and 100),
  message text not null default '',
  started_at timestamptz,
  completed_at timestamptz,
  last_success_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.crazyparts_update_status enable row level security;

revoke all on table public.crazyparts_update_status from anon, authenticated;
grant select on table public.crazyparts_update_status to anon, authenticated, service_role;
grant insert, update, delete on table public.crazyparts_update_status to service_role;

drop policy if exists "Crazy Parts update progress is readable" on public.crazyparts_update_status;
create policy "Crazy Parts update progress is readable"
on public.crazyparts_update_status
for select
to anon, authenticated
using (true);

insert into public.crazyparts_update_status (family, brand, schedule_day, sort_order)
values
  ('A Series', 'Samsung A Series', 1, 1),
  ('Oppo', 'OPPO', 2, 2),
  ('Huawei', 'HUAWEI', 3, 3),
  ('Xiaomi', 'XIAOMI', 4, 4),
  ('Redmi', 'REDMI', 5, 5),
  ('Motorola', 'MOTOROLA', 6, 6),
  ('Nokia', 'NOKIA', 7, 7),
  ('Oneplus', 'ONEPLUS', 8, 8),
  ('Realme', 'REALME', 9, 9),
  ('Vivo', 'VIVO', 10, 10),
  ('Sony', 'SONY', 11, 11)
on conflict (family) do update
set brand = excluded.brand,
    schedule_day = excluded.schedule_day,
    sort_order = excluded.sort_order,
    updated_at = now();

update public.crazyparts_update_status as status
set status = 'completed',
    progress_percent = 100,
    message = 'Latest verified prices are live.',
    completed_at = prices.latest_update,
    last_success_at = prices.latest_update,
    updated_at = now()
from (
  select brand, max(updated_at) as latest_update
  from public.repair_prices
  where brand in ('Samsung A Series', 'SONY')
  group by brand
) as prices
where status.brand = prices.brand;
