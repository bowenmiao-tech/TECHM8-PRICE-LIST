update public.products
set is_visible = false,
    is_pos_visible = false,
    import_status = 'archived',
    updated_at = timezone('utc'::text, now())
where source_system = 'repairdesk_phone_cases'
  and import_status = 'active'
  and cost_price >= retail_price;

update public.product_groups product_group
set status = 'archived',
    is_visible = false,
    is_pos_visible = false,
    updated_at = timezone('utc'::text, now())
where exists (
    select 1
    from public.products product
    where product.product_group_id = product_group.id
      and product.source_system = 'repairdesk_phone_cases'
  )
  and not exists (
    select 1
    from public.products product
    where product.product_group_id = product_group.id
      and product.source_system = 'repairdesk_phone_cases'
      and product.import_status = 'active'
      and product.is_pos_visible
  );

do $$
begin
  if (select count(*) from public.products where source_system = 'repairdesk_phone_cases' and import_status = 'active') <> 149 then
    raise exception 'Expected 149 approved phone case products after the cost guard.';
  end if;

  if exists (
    select 1
    from public.products
    where source_system = 'repairdesk_phone_cases'
      and import_status = 'active'
      and (cost_price <= 0 or retail_price <= 0 or cost_price >= retail_price or not is_pos_visible)
  ) then
    raise exception 'An active phone case still has an invalid cost, retail price, or POS status.';
  end if;
end $$;
