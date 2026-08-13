begin;

do $$
declare
  target_category_id bigint;
  updated_count integer;
begin
  select id
  into target_category_id
  from public.pos_category_taxonomy
  where category_name = 'Uncategorized'
    and subcategory_name = 'Uncategorized'
    and active
  limit 1;

  if target_category_id is null then
    raise exception 'The Uncategorized POS taxonomy entry is missing.';
  end if;

  update public.products
  set pos_category_id = target_category_id,
      short_description = 'Uncategorized',
      source_metadata = coalesce(source_metadata, '{}'::jsonb)
        || jsonb_build_object(
          'pos_main_category', 'Uncategorized',
          'pos_subcategory', 'Uncategorized'
        ),
      updated_at = timezone('utc'::text, now())
  where source_system = 'repairdesk_misc_accessories'
    and source_external_id = '10322'
    and sku = 'TM8-MISC-10322';

  get diagnostics updated_count = row_count;
  if updated_count <> 1 then
    raise exception 'Expected to update exactly one CTF Earbuds Pouch product, updated %.', updated_count;
  end if;

  if exists (
    select 1
    from public.products product
    join public.pos_category_taxonomy taxonomy on taxonomy.id = product.pos_category_id
    where taxonomy.category_name = 'Other Electronics'
      and taxonomy.subcategory_name = 'Earbud Cases'
      and product.is_pos_visible
  ) then
    raise exception 'Earbud Cases still has POS-visible products.';
  end if;

  update public.pos_category_taxonomy
  set active = false,
      updated_at = now()
  where category_name = 'Other Electronics'
    and subcategory_name = 'Earbud Cases';
end
$$;

commit;
