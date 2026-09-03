-- Buyback intake refinements, matched to the paper second-hand dealer register.
--
--   1. "How the seller obtained the device" becomes an optional note. It is not
--      part of the mandatory register fields, and forcing it made staff invent
--      text when the seller simply upgraded.
--   2. Storage is now required for every category except Other, and a phone no
--      longer has to carry an IMEI: one of IMEI or serial number is enough. The
--      15-digit format check still applies whenever an IMEI is supplied.
--   3. The ready-for-sale gate counted a fixed 12 inspection answers. The POS
--      now sends a per-category checklist (phone/tablet, laptop, watch, console,
--      other) of differing lengths, so the floor drops to 8 while still refusing
--      any answer that is not pass or N/A.
--   4. The seller declaration confirms identity was sighted rather than an age
--      of 18 or over.
--
-- Both functions are patched in place from their stored definitions so every
-- other line stays byte-identical.

do $migration$
declare
  definition text;
  patched text;
  previous text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'create_pos_used_device_acquisition'
    and pronamespace = 'public'::regnamespace;

  if definition is null then
    raise exception 'create_pos_used_device_acquisition was not found';
  end if;

  patched := definition;

  previous := patched;
  patched := replace(
    patched,
    $anchor$if trim(coalesce(payload->>'acquisition_statement', '')) = '' then raise exception 'How the seller obtained the device is required'; end if;$anchor$,
    $replacement$-- The acquisition note is optional; it is recorded when the seller offers it.$replacement$
  );
  if patched = previous then
    raise exception 'buyback patch: the acquisition_statement anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$if trim(coalesce(payload->>'category', '')) = 'Phone' and normalized_imei_value = '' then raise exception 'IMEI is required for phones'; end if;$anchor$,
    $replacement$-- One identifier is enough; the IMEI-or-serial rule below still applies.$replacement$
  );
  if patched = previous then
    raise exception 'buyback patch: the phone IMEI anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$raise exception 'Seller age must be confirmed'$anchor$,
    $replacement$raise exception 'Seller identity must be confirmed'$replacement$
  );
  if patched = previous then
    raise exception 'buyback patch: the seller age anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  if trim(coalesce(payload->>'condition_grade', '')) not in ('As New', 'Good', 'Fair', 'Poor', 'Faulty') then$anchor$,
    $replacement$  if trim(coalesce(payload->>'category', '')) <> 'Other' and trim(coalesce(payload->>'storage', '')) = '' then
    raise exception 'Device storage is required';
  end if;
  if trim(coalesce(payload->>'condition_grade', '')) not in ('As New', 'Good', 'Fair', 'Poor', 'Faulty') then$replacement$
  );
  if patched = previous then
    raise exception 'buyback patch: the condition anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$in ('pass', 'na')) < 12$anchor$,
    $replacement$in ('pass', 'na')) < 8$replacement$
  );
  if patched = previous then
    raise exception 'buyback patch: the acquisition inspection count anchor was not found';
  end if;

  execute patched;
end;
$migration$;

do $migration$
declare
  definition text;
  patched text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'update_pos_used_device'
    and pronamespace = 'public'::regnamespace;

  if definition is null then
    raise exception 'update_pos_used_device was not found';
  end if;

  patched := replace(
    definition,
    $anchor$in ('pass', 'na')) < 12$anchor$,
    $replacement$in ('pass', 'na')) < 8$replacement$
  );
  if patched = definition then
    raise exception 'buyback patch: the update inspection count anchor was not found';
  end if;

  execute patched;
end;
$migration$;

comment on function public.create_pos_used_device_acquisition(text, jsonb) is
  'Internal POS buyback intake. Records the second-hand dealer register fields, requires storage outside the Other category, accepts either an IMEI or a serial number, and treats the acquisition note as optional.';
