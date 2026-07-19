alter table public.pos_used_device_acquisitions
  alter column shift_id set not null,
  add constraint pos_used_device_acquisitions_shift_id_fkey
    foreign key (shift_id) references public.pos_store_shifts(shift_code) on delete restrict;

create or replace function public.validate_pos_used_device_acquisition_shift()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.pos_store_shifts shift_record
    where shift_record.shift_code = new.shift_id
      and shift_record.store_id = new.store_id
      and shift_record.status = 'open'
      and shift_record.closed_at is null
  ) then
    raise exception 'An open shift for this store is required before buying a device';
  end if;
  return new;
end;
$$;

drop trigger if exists pos_used_device_acquisitions_validate_shift on public.pos_used_device_acquisitions;
create trigger pos_used_device_acquisitions_validate_shift
before insert or update of shift_id, store_id on public.pos_used_device_acquisitions
for each row execute function public.validate_pos_used_device_acquisition_shift();

revoke execute on function public.validate_pos_used_device_acquisition_shift() from public, anon, authenticated;
