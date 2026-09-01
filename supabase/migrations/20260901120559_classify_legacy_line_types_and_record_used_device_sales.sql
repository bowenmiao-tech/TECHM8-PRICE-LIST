-- Split sales into the three categories the store actually reports on:
-- repair, product (retail), and used device.
--
-- Two things were stopping that:
--   1. Every imported RepairDesk line landed as 'retail', so historical repairs
--      were counted as products. RepairDesk's own item type was preserved in
--      line_payload->>'source_type' during the import, so the split is recovered
--      from that rather than guessed from product names.
--   2. save_pos_sales_order had no branch for used devices, so a device sale was
--      recorded as a product. The check constraint already allowed 'used_device'.
--
-- source_type is left untouched in line_payload, so this backfill is reversible.

update public.pos_sales_order_lines
set line_type = case
  when line_payload->>'source_type' = 'Repair' then 'repair'
  when line_payload->>'source_type' = 'Accessories' then 'retail'
  when line_payload->>'source_type' = 'Casual'
    then case when lower(trim(name)) = 'device' then 'used_device' else 'retail' end
  -- A handful of lines carry no type. Those attached to a RepairDesk ticket are
  -- merged multi-repair lines; the two without a ticket are accessories.
  when coalesce(line_payload->>'source_type', '') = ''
    then case when nullif(line_payload->>'source_ticket_id', '') is not null then 'repair' else 'retail' end
  else 'retail'
end
where legacy_import = true;

-- Record future used-device sales under their own type. Patching the stored
-- definition keeps every other line of the function byte-identical.
do $migration$
declare
  existing_definition text;
  patched_definition text;
  anchor constant text := E'      when lower(coalesce(item.value->>''is_special'', ''false'')) = ''true''';
begin
  select pg_get_functiondef(oid) into existing_definition
  from pg_proc
  where proname = 'save_pos_sales_order' and pronamespace = 'public'::regnamespace;

  if existing_definition is null then
    raise exception 'save_pos_sales_order was not found';
  end if;

  patched_definition := replace(
    existing_definition,
    anchor,
    E'      when lower(coalesce(item.value->>''is_used_device'', ''false'')) = ''true'' then ''used_device''\n' || anchor
  );

  if patched_definition = existing_definition then
    raise exception 'save_pos_sales_order: the used_device anchor was not found';
  end if;

  execute patched_definition;
end
$migration$;
