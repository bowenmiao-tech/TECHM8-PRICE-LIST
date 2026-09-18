-- `array || 'literal'` asks Postgres to read the literal as an array, so the
-- blocker list failed on the first plain sentence it tried to add. Appending is
-- said explicitly instead. Same definition as the corrected
-- 20260918140000 migration, repeated here so an already-migrated database
-- picks up the fix.
create or replace function public.pos_used_device_listing_blockers(target_device_id bigint)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  device_row public.pos_used_devices%rowtype;
  blockers text[] := array[]::text[];
  outstanding integer;
begin
  select * into device_row from public.pos_used_devices where id = target_device_id;
  if not found then return array['This device no longer exists']; end if;
  if device_row.status = 'sold' then return array['This device has been sold']; end if;
  if device_row.status in ('returned_to_seller', 'disposed') then
    return array['This device is closed and no longer in stock'];
  end if;

  if device_row.clean_check_status not in ('Clean', 'Not Applicable') then
    blockers := array_append(blockers, format('The lost or stolen check is still %s', lower(device_row.clean_check_status)));
  end if;
  if not device_row.activation_lock_removed then
    blockers := array_append(blockers, 'Activation locks are not confirmed removed');
  end if;
  if not device_row.data_erased_confirmed then
    blockers := array_append(blockers, 'Customer data is not confirmed erased');
  end if;

  select count(*) into outstanding
  from public.pos_used_device_inspection_items item
  where item.active
    and item.category = device_row.category
    and lower(coalesce(device_row.inspection->>item.item_key, '')) not in ('pass', 'na');
  if outstanding > 0 then
    blockers := array_append(blockers, format('%s inspection check%s still to pass', outstanding,
      case when outstanding = 1 then '' else 's' end));
  end if;

  if device_row.evidence_required and not exists (
    select 1 from public.pos_used_device_updates entry
    where entry.device_id = device_row.id and entry.kind = 'photo' and entry.stage = 'listing'
  ) then
    blockers := array_append(blockers, 'No listing photo has been added');
  end if;

  return blockers;
end;
$$;
