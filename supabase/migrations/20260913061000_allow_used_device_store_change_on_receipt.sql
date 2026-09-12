-- A used device may change store, but only by being received on a transfer.
--
-- pos_used_device_store_immutable existed to stop a device quietly moving
-- between stores: without it, any update could reassign stock, and the store
-- that paid for a phone could find it booked somewhere else with no trail.
-- That guard is worth keeping exactly as strict as it was for every path
-- except the one legitimate one this feature adds.
--
-- So the rule becomes: store_id may change only when, in this same
-- transaction, a transfer of THIS device, FROM the store it is leaving, TO the
-- store it is arriving at, has just been marked received. Anything else still
-- raises, including replaying an older transfer later -- the receipt has to
-- have happened moments ago, not at some point in the past.
--
-- The check reads the transfer table rather than trusting the caller, so it
-- holds for any route into the row, not just the RPC written alongside it.

create or replace function public.guard_pos_used_device_store_change()
returns trigger
language plpgsql
set search_path = ''
as $guard$
begin
  if new.store_id is distinct from old.store_id then
    if not exists (
      select 1
      from public.pos_used_device_transfers device_transfer
      where device_transfer.device_id = old.id
        and device_transfer.from_store_id = old.store_id
        and device_transfer.to_store_id = new.store_id
        and device_transfer.status = 'received'
        -- now() is the transaction clock, and the receipt sets received_at to
        -- it, so this means "settled in the transaction doing the moving".
        and device_transfer.received_at >= now() - interval '5 seconds'
    ) then
      raise exception 'A used device can only change store by being received on a transfer';
    end if;
  end if;
  return new;
end;
$guard$;

drop trigger if exists pos_used_device_store_immutable on public.pos_used_devices;

create trigger pos_used_device_store_immutable
before update of store_id on public.pos_used_devices
for each row execute function public.guard_pos_used_device_store_change();

comment on function public.guard_pos_used_device_store_change() is
  'Used devices stay with their store unless a transfer to the new store was received in the same transaction.';
