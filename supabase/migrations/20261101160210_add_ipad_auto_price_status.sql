insert into public.crazyparts_update_status(family,brand,schedule_day,sort_order,status,message)
values('iPad','iPad Pro / Air / Mini',2,3,'scheduled','Runs after OPPO on day 2; protected legacy models are excluded.')
on conflict(family) do update set brand=excluded.brand,schedule_day=2,updated_at=now();
