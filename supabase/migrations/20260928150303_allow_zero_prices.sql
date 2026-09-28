-- Zero is a valid entered price. Missing, malformed and negative values remain invalid.
alter table public.pos_repair_ticket_jobs
  drop constraint pos_repair_ticket_jobs_price_check,
  add constraint pos_repair_ticket_jobs_price_check check (price >= 0 and price <= 1000000);

alter table public.pos_used_devices
  drop constraint pos_used_devices_purchase_cost_check,
  add constraint pos_used_devices_purchase_cost_check check (purchase_cost >= 0);

alter table public.pos_used_device_acquisitions
  drop constraint pos_used_device_acquisitions_payout_amount_check,
  add constraint pos_used_device_acquisitions_payout_amount_check check (payout_amount >= 0);

alter table public.pos_used_device_costs
  drop constraint pos_used_device_costs_amount_check,
  add constraint pos_used_device_costs_amount_check check (amount is null or amount >= 0);

-- Keep the existing authorization, audit and intake checks in these functions.
-- Each replacement is checked so a changed upstream function cannot be patched silently.
do $migration$
declare
  patch jsonb;
  definition text;
  original_text text;
  replacement_text text;
begin
  for patch in select value from jsonb_array_elements(jsonb_build_array(
    jsonb_build_object('fn', 'public.pos_repair_intake_is_complete(text,text,text,text,text,jsonb)', 'from', '::numeric > 0', 'to', '::numeric >= 0'),
    jsonb_build_object('fn', 'public.enforce_complete_new_pos_repair_ticket()', 'from', 'or (numeric_price::numeric = 0 and not coalesce(new.special_order, false))', 'to', ''),
    jsonb_build_object('fn', 'public.enforce_pos_repair_ticket_numeric_price()', 'from', 'or (numeric_price = 0 and not coalesce(new.special_order, false))', 'to', ''),
    jsonb_build_object('fn', 'public.enforce_pos_repair_ticket_numeric_price()', 'from', 'Ordinary repair price must be above zero; only a special repair may start at zero', 'to', 'Repair price must be between 0.00 and 1000000.00'),
    jsonb_build_object('fn', 'public.enforce_repair_intake_numeric_price()', 'from', 'numeric_price <= 0', 'to', 'numeric_price < 0'),
    jsonb_build_object('fn', 'public.enforce_repair_intake_numeric_price()', 'from', 'Repair price must be between 0.01 and 1000000.00', 'to', 'Repair price must be between 0.00 and 1000000.00'),
    jsonb_build_object('fn', 'public.add_pos_repair_ticket_job(text,jsonb)', 'from', 'price_value <= 0', 'to', 'price_value < 0'),
    jsonb_build_object('fn', 'public.add_pos_repair_ticket_job(text,jsonb)', 'from', 'Repair price must be between 0.01 and 1000000.00', 'to', 'Repair price must be between 0.00 and 1000000.00'),
    jsonb_build_object('fn', 'public.update_pos_repair_ticket_job(text,jsonb)', 'from', 'price_value <= 0', 'to', 'price_value < 0'),
    jsonb_build_object('fn', 'public.update_pos_repair_ticket_job(text,jsonb)', 'from', 'Repair price must be between 0.01 and 1000000.00', 'to', 'Repair price must be between 0.00 and 1000000.00'),
    jsonb_build_object('fn', 'public.create_pos_used_device_acquisition(text,jsonb)', 'from', 'purchase_cost_value <= 0', 'to', 'purchase_cost_value < 0'),
    jsonb_build_object('fn', 'public.create_pos_used_device_acquisition(text,jsonb)', 'from', 'Purchase price must be above zero', 'to', 'Purchase price cannot be negative'),
    jsonb_build_object('fn', 'public.update_pos_used_device(text,jsonb)', 'from', 'price_value <= 0', 'to', 'price_value < 0'),
    jsonb_build_object('fn', 'public.set_admin_used_device_listing(text,jsonb)', 'from', 'if price_value = 0 and should_publish then raise exception ''A device cannot go online at zero''; end if;', 'to', ''),
    jsonb_build_object('fn', 'public.get_pos_used_device_website_status(text,text,text)', 'from', 'device_row.sale_price <= 0', 'to', 'device_row.sale_price < 0'),
    jsonb_build_object('fn', 'public.request_pos_used_device_publish(text,jsonb)', 'from', 'device_row.sale_price <= 0', 'to', 'device_row.sale_price < 0'),
    jsonb_build_object('fn', 'public.prepare_pos_used_device_sale_line()', 'from', 'round(new.unit_price, 2) <= 0', 'to', 'round(new.unit_price, 2) < 0'),
    jsonb_build_object('fn', 'public.prepare_pos_used_device_sale_line()', 'from', 'Used device sale price must be above zero', 'to', 'Used device sale price cannot be negative'),
    jsonb_build_object('fn', 'public.add_pos_used_device_cost(text,text,text,jsonb)', 'from', 'amount_value <= 0', 'to', 'amount_value < 0'),
    jsonb_build_object('fn', 'public.add_pos_used_device_cost(text,text,text,jsonb)', 'from', 'An amount must be above zero', 'to', 'An amount cannot be negative'),
    jsonb_build_object('fn', 'public.save_admin_used_device_cost(text,jsonb)', 'from', 'amount_value <= 0', 'to', 'amount_value < 0'),
    jsonb_build_object('fn', 'public.save_admin_used_device_cost(text,jsonb)', 'from', 'An amount must be above zero', 'to', 'An amount cannot be negative'),
    jsonb_build_object('fn', 'public.get_admin_used_device_stock(text,jsonb)', 'from', 'device.sale_price <= 0', 'to', 'device.sale_price < 0')
  )) loop
    original_text := patch->>'from';
    replacement_text := patch->>'to';
    definition := pg_get_functiondef((patch->>'fn')::regprocedure);
    if strpos(definition, original_text) = 0 then
      raise exception 'Zero-price migration anchor missing in %: %', patch->>'fn', original_text;
    end if;
    execute replace(definition, original_text, replacement_text);
  end loop;
end;
$migration$;
