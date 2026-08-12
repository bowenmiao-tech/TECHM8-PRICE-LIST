begin;

do $stocktake_test$
declare
  target_id bigint := 132;
  target_group_id bigint;
  target_store_id bigint;
  target_taxonomy_id bigint;
  prior_quantity integer;
  old_product_category_id bigint;
  old_other_inventory jsonb;
  old_sibling_inventory jsonb;
  result_payload jsonb;
  expected_total integer;
  saved_total integer;
  audit_count integer;
begin
  select product_group_id, pos_category_id
  into target_group_id, old_product_category_id
  from public.products
  where id = target_id;

  select id into target_store_id from public.stores where slug = 'park-ridge';
  select id into target_taxonomy_id
  from public.pos_category_taxonomy
  where category_name = 'Tablet Cases' and subcategory_name = 'Apple iPad';

  select coalesce((
    select quantity
    from public.product_store_inventory
    where product_id = target_id and store_id = target_store_id
  ), 0)
  into prior_quantity;

  select coalesce(jsonb_object_agg(store_id::text, quantity), '{}'::jsonb)
  into old_other_inventory
  from public.product_store_inventory
  where product_id = target_id and store_id <> target_store_id;

  select coalesce(jsonb_object_agg((product_id::text || ':' || store_id::text), quantity), '{}'::jsonb)
  into old_sibling_inventory
  from public.product_store_inventory
  where product_id <> target_id
    and product_id in (select id from public.products where product_group_id = target_group_id);

  result_payload := public.apply_pos_stocktake_update(
    target_id,
    'park-ridge',
    target_taxonomy_id,
    prior_quantity + 3,
    'Codex Transaction Test'
  );

  if (select pos_category_id from public.product_groups where id = target_group_id) is distinct from target_taxonomy_id then
    raise exception 'Grouped POS category was not updated';
  end if;

  if (select pos_category_id from public.products where id = target_id) is distinct from old_product_category_id then
    raise exception 'Variant-level POS category should not change for grouped products';
  end if;

  if old_other_inventory is distinct from (
    select coalesce(jsonb_object_agg(store_id::text, quantity), '{}'::jsonb)
    from public.product_store_inventory
    where product_id = target_id and store_id <> target_store_id
  ) then
    raise exception 'Another store inventory row changed';
  end if;

  if old_sibling_inventory is distinct from (
    select coalesce(jsonb_object_agg((product_id::text || ':' || store_id::text), quantity), '{}'::jsonb)
    from public.product_store_inventory
    where product_id <> target_id
      and product_id in (select id from public.products where product_group_id = target_group_id)
  ) then
    raise exception 'A sibling variant inventory row changed';
  end if;

  select coalesce(sum(quantity), 0)::integer
  into expected_total
  from public.product_store_inventory
  where product_id = target_id;

  select stock_quantity into saved_total from public.products where id = target_id;
  if saved_total is distinct from expected_total then
    raise exception 'Aggregate stock was not recalculated';
  end if;

  select count(*) into audit_count
  from public.pos_stocktake_changes
  where product_id = target_id
    and staff_name = 'Codex Transaction Test'
    and new_quantity = prior_quantity + 3
    and new_pos_category_id = target_taxonomy_id;

  if audit_count <> 1 then
    raise exception 'Audit row missing';
  end if;

  raise notice 'Stocktake transaction test passed: %', result_payload;
end
$stocktake_test$;

rollback;
