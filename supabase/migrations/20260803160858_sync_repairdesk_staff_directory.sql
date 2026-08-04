alter table public.staff_directory
  add column if not exists repairdesk_user_id bigint,
  add column if not exists job_role text,
  add column if not exists default_store_id bigint references public.store_locations(id) on delete set null;

create unique index if not exists staff_directory_repairdesk_user_id_key
  on public.staff_directory (repairdesk_user_id)
  where repairdesk_user_id is not null;

create index if not exists staff_directory_default_store_id_idx
  on public.staff_directory (default_store_id);

with repairdesk_staff (display_name, email, repairdesk_user_id, job_role, default_store_code) as (
  values
    ('Andy', 'shangzelin2001@gmail.com', 37564::bigint, 'technician', 'parkridge'),
    ('Anna', 'Ana04maria14@gmail.com', 82237::bigint, 'store_manager', 'northlakes'),
    ('Bonnie', 'bonniechiu1212aabb@gmail.com', 69850::bigint, 'store_manager', 'fairfield'),
    ('Fiona', 'yingmccoy@gmail.com', 75726::bigint, 'store_manager', 'toowong'),
    ('Jinny', 'gksmftka@gmail.com', 80470::bigint, 'technician', 'fairfield'),
    ('Joanna Chen', '824195774@qq.com', 48578::bigint, 'store_manager', 'parkridge')
)
insert into public.staff_directory (
  display_name,
  email,
  repairdesk_user_id,
  job_role,
  default_store_id,
  active
)
select
  staff.display_name,
  staff.email,
  staff.repairdesk_user_id,
  staff.job_role,
  stores.id,
  true
from repairdesk_staff staff
join public.store_locations stores on stores.store_code = staff.default_store_code
on conflict (display_name) do update
set
  email = excluded.email,
  repairdesk_user_id = excluded.repairdesk_user_id,
  job_role = excluded.job_role,
  default_store_id = excluded.default_store_id,
  active = true,
  updated_at = now();

update public.staff_directory
set active = false,
    updated_at = now()
where display_name in ('Henry Ang', 'JANAPHY', 'Steven T');

update public.staff_directory
set job_role = 'admin',
    active = true,
    updated_at = now()
where display_name = 'Bowen';

create or replace function public.get_daily_report_setup(session_token text, target_store_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  stores_payload jsonb;
  staff_payload jsonb;
  inventory_payload jsonb;
begin
  if not public.is_valid_staff_session(session_token) then
    raise exception 'Invalid session';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'store_code', store_code,
        'store_name', store_name
      )
      order by sort_order, store_name
    ),
    '[]'::jsonb
  )
  into stores_payload
  from public.store_locations
  where active = true
    and store_code <> 'warehouse';

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', staff.id,
        'display_name', staff.display_name,
        'email', staff.email,
        'repairdesk_user_id', staff.repairdesk_user_id,
        'job_role', staff.job_role,
        'default_store_code', stores.store_code,
        'default_store_name', stores.store_name
      )
      order by staff.display_name
    ),
    '[]'::jsonb
  )
  into staff_payload
  from public.staff_directory staff
  left join public.store_locations stores on stores.id = staff.default_store_id
  where staff.active = true;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', lcd.id,
        'model_name', lcd.model_name,
        'variant_name', lcd.variant_name,
        'category_key', lcd.category_key,
        'current_qty', lcd.current_qty
      )
      order by lcd.category_key, lcd.model_name, lcd.variant_name
    ),
    '[]'::jsonb
  )
  into inventory_payload
  from public.lcd_inventory_items lcd
  join public.store_locations stores on stores.id = lcd.store_id
  where lcd.active = true
    and stores.active = true
    and stores.store_code <> 'warehouse'
    and (
      target_store_code is null
      or target_store_code = ''
      or stores.store_code = target_store_code
    );

  return jsonb_build_object(
    'ok', true,
    'stores', stores_payload,
    'staff', staff_payload,
    'lcd_items', inventory_payload
  );
end;
$$;
