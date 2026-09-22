-- Hard deletion is an explicit administrator operation. Sales invoices retain
-- their original line descriptions and amounts; only their device link is removed.
alter table public.pos_used_device_buyback_documents
  drop constraint pos_used_device_buyback_documents_device_id_fkey,
  add constraint pos_used_device_buyback_documents_device_id_fkey
    foreign key (device_id) references public.pos_used_devices(id) on delete cascade;

create or replace function public.reject_pos_used_device_document_change()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  -- A signed document remains immutable while its device exists. A deliberate
  -- deletion of the parent removes the attached document through its FK.
  if tg_op = 'DELETE' and not exists (
    select 1 from public.pos_used_devices where id = old.device_id
  ) then return old; end if;
  raise exception 'Signed buyback documents are immutable';
end;
$$;

create or replace function public.delete_admin_used_device(
  session_token text, target_device_code text, confirmation_code text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  device public.pos_used_devices%rowtype;
  invoice_lines integer;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Administrator access is required to delete a device';
  end if;
  if nullif(btrim(target_device_code), '') is null
    or confirmation_code is distinct from target_device_code then
    raise exception 'Confirm the exact device code before deleting';
  end if;
  select * into device from public.pos_used_devices
    where device_code = target_device_code for update;
  if not found then return jsonb_build_object('ok', true, 'already_deleted', true); end if;
  if public.pos_used_device_online_hold_active(device) then
    raise exception 'This device has an active website order. Complete or cancel that order first';
  end if;
  if device.website_status in ('published', 'queued', 'failed') or exists (
    select 1 from public.pos_used_device_publish_queue
    where device_id = device.id and completed_at is null
  ) then
    raise exception 'Withdraw the website listing and wait for it to finish before deleting';
  end if;

  update public.pos_sales_order_lines set used_device_id = null where used_device_id = device.id;
  get diagnostics invoice_lines = row_count;
  delete from public.pos_used_device_id_photo_views where update_id in (
    select id from public.pos_used_device_update_records where device_id = device.id);
  delete from public.pos_used_device_document_access_log where device_id = device.id;
  delete from public.pos_used_device_intake_uploads where claimed_device_id = device.id;
  delete from public.pos_used_device_update_records where device_id = device.id;
  delete from public.pos_used_device_costs where device_id = device.id;
  delete from public.pos_used_device_publish_queue where device_id = device.id;
  delete from public.pos_used_device_transfers where device_id = device.id;
  delete from public.pos_used_device_sale_tests where device_id = device.id;
  delete from public.pos_used_device_transactions where device_id = device.id;
  delete from public.pos_used_devices where id = device.id;
  delete from public.pos_used_device_acquisitions where id = device.acquisition_id
    and not exists (select 1 from public.pos_used_devices where acquisition_id = device.acquisition_id);
  return jsonb_build_object('ok', true, 'device_code', target_device_code,
    'preserved_invoice_lines', invoice_lines);
end;
$$;
revoke all on function public.delete_admin_used_device(text,text,text) from public;
grant execute on function public.delete_admin_used_device(text,text,text) to anon, authenticated, service_role;
