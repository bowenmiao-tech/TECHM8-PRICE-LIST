-- Google Pixel joins the Crazy Parts monthly sequence on day 3, after Apple Mac.
update public.crazyparts_update_status
set sort_order = sort_order + 1,
    updated_at = now()
where family in ('Xiaomi', 'Redmi', 'Motorola', 'Nokia', 'Oneplus', 'Realme', 'Vivo', 'Sony')
  and not exists (select 1 from public.crazyparts_update_status where family = 'Pixel');

insert into public.crazyparts_update_status (family, brand, schedule_day, sort_order, status, message)
values ('Pixel', 'Google Pixel', 3, 5, 'scheduled', 'Runs after Apple Mac on day 3. Screens add $150, other parts add $130.')
on conflict (family) do update
set brand = excluded.brand,
    schedule_day = excluded.schedule_day,
    sort_order = excluded.sort_order,
    updated_at = now();
