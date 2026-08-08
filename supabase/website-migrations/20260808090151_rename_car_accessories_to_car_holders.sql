begin;

update public.categories
set name = 'Car Holders',
    updated_at = timezone('utc'::text, now())
where slug = 'holder-car-play-charger';

do $$
begin
  if not exists (
    select 1
    from public.categories
    where slug = 'holder-car-play-charger'
      and name = 'Car Holders'
  ) then
    raise exception 'Car holder category was not renamed.';
  end if;
end
$$;

commit;
