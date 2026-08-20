begin;

create temporary table ctfy_product_target on commit drop as
select product.id, product.product_group_id
from public.products product
join public.product_groups product_group on product_group.id = product.product_group_id
where product.source_system = 'repairdesk_phone_cases'
  and product.import_status = 'active'
  and product.brand = 'CASETiFY'
  and product_group.product_family = 'Branded Case Collection';

do $$
begin
  if (select count(*) from ctfy_product_target) <> 267 then
    raise exception 'Expected 267 CASETiFY products before the CTFY rename.';
  end if;
  if (select count(distinct product_group_id) from ctfy_product_target) <> 25 then
    raise exception 'Expected 25 CASETiFY product groups before the CTFY rename.';
  end if;
end $$;

update public.products product
set brand = 'CTFY',
    updated_at = timezone('utc'::text, now())
where product.id in (select id from ctfy_product_target);

update public.product_groups product_group
set name = regexp_replace(product_group.name, '^CASETiFY Cases', 'CTFY', 'i'),
    updated_at = timezone('utc'::text, now())
where product_group.id in (
  select distinct product_group_id from ctfy_product_target
)
  and product_group.product_family = 'Branded Case Collection';

do $$
begin
  if (
    select count(*)
    from public.products product
    join ctfy_product_target target on target.id = product.id
    where product.brand = 'CTFY'
  ) <> 267 then
    raise exception 'CTFY product rename verification failed.';
  end if;
  if (
    select count(*)
    from public.product_groups product_group
    where product_group.id in (select distinct product_group_id from ctfy_product_target)
      and product_group.name ~ '^CTFY(?:\s+for\s+.+)?$'
  ) <> 25 then
    raise exception 'CTFY product-group rename verification failed.';
  end if;
  if exists (
    select 1
    from public.products product
    join ctfy_product_target target on target.id = product.id
    where product.brand = 'CASETiFY'
  ) then
    raise exception 'A CASETiFY product label remains after the CTFY rename.';
  end if;
end $$;

commit;

select
  count(*) as ctfy_products,
  count(distinct product.product_group_id) as ctfy_groups
from public.products product
join public.product_groups product_group on product_group.id = product.product_group_id
where product.source_system = 'repairdesk_phone_cases'
  and product.import_status = 'active'
  and product.brand = 'CTFY'
  and product_group.product_family = 'Branded Case Collection';
