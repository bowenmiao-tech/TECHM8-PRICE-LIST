update public.crazyparts_update_status
set sort_order = case family
      when 'Xiaomi' then 5
      when 'Redmi' then 6
      when 'Motorola' then 7
      when 'Nokia' then 8
      when 'Oneplus' then 9
      when 'Realme' then 10
      when 'Vivo' then 11
      when 'Sony' then 12
      else sort_order
    end,
    updated_at = now()
where family in ('Xiaomi', 'Redmi', 'Motorola', 'Nokia', 'Oneplus', 'Realme', 'Vivo', 'Sony');

insert into public.crazyparts_update_status (
  family,
  brand,
  schedule_day,
  sort_order,
  status,
  message
)
values (
  'Apple Mac',
  'iMac + MacBook',
  3,
  4,
  'scheduled',
  'Waiting for the next scheduled or manual update.'
)
on conflict (family) do update
set brand = excluded.brand,
    schedule_day = excluded.schedule_day,
    sort_order = excluded.sort_order,
    updated_at = now();
