begin;

do $$
declare
  ipad_97_z_fold_group_id bigint;
  affected_rows integer;
begin
  select id
  into ipad_97_z_fold_group_id
  from public.product_groups
  where code = 'TM8-GRP-IPAD-97-LEGACY-ZFD';

  if ipad_97_z_fold_group_id is null then
    raise exception 'Required product group TM8-GRP-IPAD-97-LEGACY-ZFD was not found';
  end if;

  update public.products
  set name = 'Z-Fold Case for iPad 9.7-inch (Gen 5/6 and Air 1/2) - Gold',
      short_description = 'Z-Fold Case in Gold.',
      retail_price = 39.95,
      product_group_id = ipad_97_z_fold_group_id,
      variant_name = 'Gold',
      variant_color = 'Gold',
      import_status = 'active',
      is_pos_visible = true,
      is_visible = false,
      source_metadata = coalesce(source_metadata, '{}'::jsonb) || jsonb_build_object(
        'catalog_correction', jsonb_build_object(
          'corrected_at', '2026-08-06',
          'reason', 'wrong_family_name',
          'original_family', 'Z-Flip Case',
          'corrected_family', 'Z-Fold Case',
          'target_group_code', 'TM8-GRP-IPAD-97-LEGACY-ZFD'
        )
      ),
      updated_at = timezone('utc'::text, now())
  where sku = 'TM8-TAB-9614';

  get diagnostics affected_rows = row_count;
  if affected_rows <> 1 then
    raise exception 'Expected to update one Gold product (TM8-TAB-9614), updated %', affected_rows;
  end if;

  update public.products
  set name = regexp_replace(name, 'Z-Flip', 'Z-Fold', 'gi'),
      short_description = regexp_replace(short_description, 'Z-Flip', 'Z-Fold', 'gi'),
      retail_price = 39.95,
      import_status = 'archived',
      is_pos_visible = false,
      is_visible = false,
      source_metadata = coalesce(source_metadata, '{}'::jsonb) || jsonb_build_object(
        'catalog_correction', jsonb_build_object(
          'corrected_at', '2026-08-06',
          'reason', 'duplicate_after_z_fold_reclassification',
          'original_family', 'Z-Flip Case',
          'corrected_family', 'Z-Fold Case',
          'replacement_sku', case sku
            when 'TM8-TAB-9604' then 'TM8-TAB-6433'
            when 'TM8-TAB-9605' then 'TM8-TAB-6432'
            when 'TM8-TAB-9606' then 'TM8-TAB-6428'
          end
        )
      ),
      updated_at = timezone('utc'::text, now())
  where sku in ('TM8-TAB-9604', 'TM8-TAB-9605', 'TM8-TAB-9606');

  get diagnostics affected_rows = row_count;
  if affected_rows <> 3 then
    raise exception 'Expected to archive three duplicate Air/Pro variants, archived %', affected_rows;
  end if;

  update public.products
  set import_status = 'archived',
      is_pos_visible = false,
      is_visible = false,
      source_metadata = coalesce(source_metadata, '{}'::jsonb) || jsonb_build_object(
        'catalog_correction', jsonb_build_object(
          'corrected_at', '2026-08-06',
          'reason', 'duplicate_variant',
          'replacement_sku', 'TM8-TAB-6417'
        )
      ),
      updated_at = timezone('utc'::text, now())
  where sku = 'TM8-TAB-8121';

  get diagnostics affected_rows = row_count;
  if affected_rows <> 1 then
    raise exception 'Expected to archive one duplicate Yellow variant, archived %', affected_rows;
  end if;

  update public.product_groups
  set name = regexp_replace(name, 'Z-Flip', 'Z-Fold', 'gi'),
      product_family = 'Z-Fold Case',
      status = 'archived',
      is_pos_visible = false,
      is_visible = false,
      updated_at = timezone('utc'::text, now())
  where code in (
    'TM8-GRP-IPAD-97-LEGACY-ZFL',
    'TM8-GRP-IPAD-109-PRO11-LEGACY-ZFL'
  );

  get diagnostics affected_rows = row_count;
  if affected_rows <> 2 then
    raise exception 'Expected to archive two incorrect Z-Flip groups, archived %', affected_rows;
  end if;
end
$$;

commit;
