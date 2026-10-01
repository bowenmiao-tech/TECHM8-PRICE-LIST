-- Update item metadata for already imported RepairDesk North Lakes invoices.
-- This does not replace invoices, payments, or sale line IDs.
create or replace function public.backfill_repairdesk_north_lakes_sales_items(batch_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  matched_line public.pos_sales_order_lines%rowtype;
  updated_count integer := 0;
  source_type_value text;
  source_cogs_value numeric;
  source_discount_value numeric;
  source_total_value numeric;
begin
  if jsonb_typeof(batch_payload) <> 'array' or jsonb_array_length(batch_payload) not between 1 and 100 then
    raise exception 'The batch must contain 1 to 100 sale lines';
  end if;

  for item in select value from jsonb_array_elements(batch_payload) loop
    if jsonb_typeof(item) <> 'object'
      or coalesce(item->>'invoice_number','') !~ '^[0-9]+$'
      or coalesce(item->>'line_number','') !~ '^[0-9]+$'
      or coalesce(item->>'quantity','') !~ '^[-]?[0-9]+$'
      or coalesce(item->>'line_total','') !~ '^[-]?[0-9]+([.][0-9]+)?$'
      or coalesce(item->>'source_cogs','') !~ '^[-]?[0-9]+([.][0-9]+)?$'
      or coalesce(item->>'source_discount','') !~ '^[-]?[0-9]+([.][0-9]+)?$'
      or coalesce(item->>'source_total_sales_ex_gst','') !~ '^[-]?[0-9]+([.][0-9]+)?$'
    then raise exception 'Invalid RepairDesk item payload'; end if;

    source_type_value := coalesce(item->>'source_type', '');
    if source_type_value not in ('Accessories','Repair','Casual','') then
      raise exception 'Unsupported RepairDesk item type %', source_type_value;
    end if;
    source_cogs_value := (item->>'source_cogs')::numeric;
    source_discount_value := (item->>'source_discount')::numeric;
    source_total_value := (item->>'source_total_sales_ex_gst')::numeric;

    select line.* into matched_line
    from public.pos_sales_order_lines line
    join public.pos_sales_orders sales_order on sales_order.id = line.sales_order_id
    join public.store_locations store on store.id = sales_order.store_id
    where store.store_code = 'northlakes'
      and sales_order.invoice_number = (item->>'invoice_number')::bigint
      and sales_order.order_code = 'RD-NL-INV-' || item->>'invoice_number'
      and sales_order.order_payload->>'source_system' = 'repairdesk'
      and sales_order.order_payload->>'source_store_name' = 'TechM8 North Lakes'
      and line.legacy_import
      and line.line_number = (item->>'line_number')::integer
    for update of line;

    if not found
      or coalesce(matched_line.line_payload->>'source_item_id','') <> coalesce(item->>'item_id','')
      or coalesce(matched_line.sku,'') <> coalesce(item->>'sku','')
      or matched_line.quantity <> (item->>'quantity')::integer
      or round(matched_line.line_total,2) <> round((item->>'line_total')::numeric,2)
    then
      raise exception 'North Lakes invoice % line % no longer matches source', item->>'invoice_number', item->>'line_number';
    end if;

    update public.pos_sales_order_lines line
    set line_type = case source_type_value
      when 'Repair' then 'repair'
      when '' then 'repair'
      when 'Casual' then 'special'
      else 'retail' end,
      line_payload = line.line_payload || jsonb_build_object(
        'source_type', source_type_value,
        'source_manufacturer', coalesce(item->>'source_manufacturer',''),
        'source_device', coalesce(item->>'source_device',''),
        'source_cogs', source_cogs_value,
        'source_discount', source_discount_value,
        'source_total_sales_ex_gst', source_total_value,
        'source_report_item_id', coalesce(item->>'source_report_item_id',''),
        'source_item_report_file', 'Item Wise Sales Report.xlsx'
      )
    where line.id = matched_line.id;
    updated_count := updated_count + 1;
  end loop;

  return jsonb_build_object('ok',true,'updated_lines',updated_count);
end;
$$;

revoke all on function public.backfill_repairdesk_north_lakes_sales_items(jsonb) from public, anon, authenticated;
grant execute on function public.backfill_repairdesk_north_lakes_sales_items(jsonb) to service_role;

comment on function public.backfill_repairdesk_north_lakes_sales_items(jsonb) is
  'Service-role-only, source-checked metadata and cost backfill for existing North Lakes RepairDesk sale lines.';
