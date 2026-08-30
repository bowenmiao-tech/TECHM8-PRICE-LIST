begin;

create or replace function private.inherit_cloned_product_catalog_group()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  source_product public.products%rowtype;
  source_group public.product_groups%rowtype;
  source_sku text;
  source_signature text;
  clone_signature text;
  detected_colour text;
  inherited_before boolean := false;
  is_compatible_clone boolean := false;
begin
  if coalesce(new.sku, '') !~* '-COPY$' then
    return new;
  end if;

  source_sku := regexp_replace(new.sku, '(-COPY)+$', '', 'i');

  select product.*
  into source_product
  from public.products product
  where upper(product.sku) = upper(source_sku)
  order by product.id
  limit 1;

  if not found or source_product.product_group_id is null then
    return new;
  end if;

  select product_group.*
  into source_group
  from public.product_groups product_group
  where product_group.id = source_product.product_group_id;

  if not found then
    return new;
  end if;

  inherited_before := coalesce(
    (new.source_metadata #>> '{catalog_clone,group_inherited}')::boolean,
    false
  );
  source_signature := private.catalog_clone_name_signature(source_product.name, source_product.model);
  clone_signature := private.catalog_clone_name_signature(new.name, new.model);
  is_compatible_clone := (
      source_signature = clone_signature
      and lower(coalesce(new.model, '')) = lower(coalesce(source_product.model, ''))
    ) or (
      source_group.product_family = 'Branded Case Collection'
      and lower(coalesce(new.brand, '')) = lower(coalesce(source_product.brand, ''))
      and lower(coalesce(new.model, '')) = lower(coalesce(source_product.model, ''))
    );

  if is_compatible_clone and (new.product_group_id is null or inherited_before) then
    new.product_group_id := source_product.product_group_id;
    new.pos_category_id := coalesce(source_product.pos_category_id, source_group.pos_category_id);
    new.pos_sort_order := coalesce(source_product.pos_sort_order, source_group.pos_sort_order);
    detected_colour := private.catalog_colour_from_product_name(new.name);

    if source_group.product_family = 'Branded Case Collection' then
      new.variant_name := trim(regexp_replace(new.name, '\s+for\s+.*$', '', 'i'));
      new.variant_color := detected_colour;
    elsif detected_colour is not null then
      new.variant_name := detected_colour;
      new.variant_color := detected_colour;
    else
      new.variant_name := coalesce(new.variant_name, source_product.variant_name);
      new.variant_color := coalesce(new.variant_color, source_product.variant_color);
    end if;

    new.source_metadata := jsonb_set(
      coalesce(new.source_metadata, '{}'::jsonb),
      '{catalog_clone}',
      jsonb_build_object(
        'source_product_id', source_product.id,
        'source_sku', source_product.sku,
        'group_inherited', true
      ),
      true
    );
  elsif inherited_before and not is_compatible_clone then
    new.product_group_id := null;
    new.variant_name := null;
    new.variant_color := null;
    new.source_metadata := jsonb_set(
      coalesce(new.source_metadata, '{}'::jsonb),
      '{catalog_clone,group_inherited}',
      'false'::jsonb,
      true
    );
  end if;

  return new;
end;
$$;

revoke all on function private.inherit_cloned_product_catalog_group() from public, anon, authenticated;

commit;
