-- A photo taken by mistake can be removed, by staff or by the admin.
--
-- Evidence used to be strictly append-only, so a blurred shot, a photo of the
-- wrong device or a picture of the seller's kitchen stayed on the record, and
-- on the website if it was a listing photo, for good.
--
-- Removing takes a photo out of every view -- the POS, the admin portal and the
-- public listing -- but it is not destroyed. The row stays, marked with who
-- removed it and when; the file stays in its bucket; and the device history
-- says a photo was removed. What a device was bought with can still be shown to
-- an auditor, while nobody has to look at the mistake day to day.
--
-- Two rules keep a removal from breaking something else:
--   * a purchase keeps at least one intake photo, because it was only allowed
--     to be saved with one; and
--   * a device that is on sale keeps at least one listing photo, for the same
--     reason.
-- In both cases the answer is to add the right photo first.
--
-- Photos staged on the buy form before the purchase is saved are drafts, not
-- evidence yet. Removing one of those deletes it outright.
--
-- How: the table becomes `pos_used_device_update_records`, and
-- `pos_used_device_updates` becomes a view of the entries that have not been
-- removed. Every existing reader and writer -- thirteen functions -- goes
-- through the view unchanged, so a removed photo cannot leak back through a
-- count or a listing that was not individually patched.

-- 1. Keep every entry; show only the ones still standing.
alter table public.pos_used_device_updates rename to pos_used_device_update_records;

alter table public.pos_used_device_update_records
  add column removed_at timestamptz,
  add column removed_by text,
  add column removed_by_admin boolean not null default false;

comment on table public.pos_used_device_update_records is
  'Every device photo and note ever recorded, including removed ones. Read through the pos_used_device_updates view, which hides removed entries.';

create view public.pos_used_device_updates
with (security_invoker = true)
as
select id, device_id, kind, stage, body, storage_path, file_name, author, created_at
from public.pos_used_device_update_records
where removed_at is null;

revoke all on public.pos_used_device_updates from public, anon, authenticated;
grant select, insert on public.pos_used_device_updates to service_role;

comment on view public.pos_used_device_updates is
  'Device photos and notes that have not been removed. Inserts pass through to pos_used_device_update_records.';

-- A retried upload must find its own row even if that photo has since been
-- removed, rather than colliding with it.
do $migration$
declare
  definition text;
  patched text;
begin
  select replace(pg_get_functiondef('public.add_pos_used_device_update(text,text,text,jsonb)'::regprocedure), chr(13), '')
    into definition;
  patched := replace(
    definition,
    $anchor$  select * into existing from public.pos_used_device_updates where id = update_id;$anchor$,
    $replacement$  select id, device_id, kind, stage, body, storage_path, file_name, author, created_at
    into existing
  from public.pos_used_device_update_records
  where id = update_id;$replacement$
  );
  if patched = definition then
    raise exception 'photo removal patch: the idempotency anchor was not found';
  end if;
  execute patched;
end;
$migration$;

-- 2. The removal is on the device's history like everything else.
alter table public.pos_used_device_transactions
  drop constraint if exists pos_used_device_transactions_transaction_type_check;

alter table public.pos_used_device_transactions
  add constraint pos_used_device_transactions_transaction_type_check
  check (transaction_type in (
    'acquisition', 'status_change', 'price_change', 'sale', 'refund_return',
    'returned_to_seller', 'disposal', 'detail_change', 'transfer_out',
    'transfer_in', 'transfer_cancelled', 'sale_test', 'photo_removed'
  ));

-- 3. Removing a photo from a device.
create or replace function public.remove_pos_used_device_photo(
  session_token text,
  target_store_code text,
  target_device_code text,
  target_update_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  context jsonb;
  is_admin_value boolean;
  actor_name text;
  device_row public.pos_used_devices%rowtype;
  photo_row public.pos_used_device_update_records%rowtype;
  others_in_stage integer;
  stage_label text;
begin
  context := public.authorize_pos_used_device_evidence(session_token, target_store_code, target_device_code);
  if not coalesce((context->>'writable')::boolean, false) then
    raise exception 'Closed device records are read-only';
  end if;
  is_admin_value := coalesce((context->>'is_admin')::boolean, false);
  actor_name := coalesce(nullif(context->>'author', ''), 'Staff');

  -- Serialise against uploads and other removals on the same device, so two
  -- people cannot each remove "the other" last photo.
  select * into device_row from public.pos_used_devices
  where id = (context->>'device_id')::bigint
  for update;

  select * into photo_row from public.pos_used_device_update_records record
  where record.id = target_update_id
    and record.device_id = device_row.id
    and record.kind = 'photo'
    and record.removed_at is null
  for update;
  if not found then raise exception 'That photo is no longer on this device'; end if;

  -- Staff never see seller ID photos once a purchase is saved, so they cannot
  -- remove what they cannot see.
  if photo_row.stage = 'seller_id' and not is_admin_value then
    raise exception 'Only an administrator can remove a seller ID photo';
  end if;

  select count(*) into others_in_stage
  from public.pos_used_device_update_records record
  where record.device_id = device_row.id
    and record.kind = 'photo'
    and record.stage = photo_row.stage
    and record.removed_at is null
    and record.id <> photo_row.id;

  if photo_row.stage = 'intake' and device_row.evidence_required and others_in_stage = 0 then
    raise exception 'A purchase has to keep at least one intake photo. Add the right photo first, then remove this one';
  end if;
  if photo_row.stage = 'listing' and device_row.status = 'ready_for_sale'
    and device_row.evidence_required and others_in_stage = 0 then
    raise exception 'A device on sale needs at least one listing photo. Add the right photo first, then remove this one';
  end if;

  update public.pos_used_device_update_records
  set removed_at = now(), removed_by = actor_name, removed_by_admin = is_admin_value
  where id = photo_row.id;

  stage_label := case photo_row.stage
    when 'intake' then 'an intake photo'
    when 'refurb' then 'a refurbishment photo'
    when 'listing' then 'a listing photo'
    else 'a seller ID photo'
  end;

  insert into public.pos_used_device_transactions (
    transaction_code, device_id, store_id, transaction_type, from_status, to_status,
    amount, staff_name, notes, transaction_payload
  ) values (
    'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
    device_row.id, device_row.store_id, 'photo_removed', device_row.status, device_row.status,
    0, actor_name, 'Removed ' || stage_label,
    jsonb_build_object('update_id', photo_row.id, 'stage', photo_row.stage,
      'file_name', photo_row.file_name, 'taken_by', photo_row.author,
      'taken_at', photo_row.created_at, 'removed_by_admin', is_admin_value)
  );

  -- The website shows listing photos, so a listed device is sent again
  -- without the one that was removed.
  if photo_row.stage = 'listing' and device_row.status = 'ready_for_sale' then
    perform public.enqueue_pos_used_device_publish(device_row.id, device_row.device_code, 'publish', actor_name);
    update public.pos_used_devices set website_status = 'queued' where id = device_row.id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', photo_row.id,
    'stage', photo_row.stage,
    'republished', photo_row.stage = 'listing' and device_row.status = 'ready_for_sale'
  );
end;
$$;

-- 4. Removing a photo from the buy form before the purchase exists. These are
--    drafts: the row goes, and the caller deletes the file.
create or replace function public.remove_pos_used_device_intake_upload(
  session_token text,
  target_store_code text,
  target_intake_key uuid,
  target_upload_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor jsonb;
  removed public.pos_used_device_intake_uploads%rowtype;
begin
  actor := public.pos_authorized_actor(session_token, target_store_code, null);

  delete from public.pos_used_device_intake_uploads upload
  where upload.id = target_upload_id
    and upload.intake_key = target_intake_key
    and upload.store_id = (actor->>'store_id')::bigint
    and upload.claimed_device_id is null
  returning * into removed;
  if not found then
    raise exception 'That photo is already part of a saved purchase or no longer exists';
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', removed.id,
    'stage', removed.stage,
    'storage_path', removed.storage_path
  );
end;
$$;

revoke all on function public.remove_pos_used_device_photo(text, text, text, uuid) from public, anon, authenticated;
revoke all on function public.remove_pos_used_device_intake_upload(text, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.remove_pos_used_device_photo(text, text, text, uuid) to service_role;
grant execute on function public.remove_pos_used_device_intake_upload(text, text, uuid, uuid) to service_role;

comment on function public.remove_pos_used_device_photo(text, text, text, uuid) is
  'Takes a device photo out of every view. Staff for their own store, admin for any; seller ID photos admin only. The row and the file are kept, the removal is on the device history, and a listed device is republished without it.';
comment on function public.remove_pos_used_device_intake_upload(text, text, uuid, uuid) is
  'Deletes a draft photo from the buy form before the purchase is saved. Returns the storage path so the caller can delete the file.';
