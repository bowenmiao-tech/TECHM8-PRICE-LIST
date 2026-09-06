-- Checkout learned to keep a repair card open, but the balance-payment path
-- did not, so it always closed the card. That dead-ended the exact flow the
-- feature exists for:
--
--   deposit on an inspection -> card stays open -> battery fault found and
--   added -> battery cannot be billed while a deposit is owing -> take the
--   balance -> card closes -> the battery job can never be billed, and a
--   closed card refuses new jobs either.
--
-- The flag now comes from the payload here too, defaulting to closing so the
-- ordinary "pay the rest and collect the device" case is unchanged.
do $migration$
declare
  def text;
  patched text;
  anchor constant text :=
    E'    perform public.close_pos_repair_tickets_for_order(\n'
    '      saved_order.id,\n'
    '      selected_staff.display_name,\n'
    '      saved_order.invoice_number,\n'
    '      saved_order.customer_name,\n'
    '      saved_order.customer_phone\n'
    '    );';
begin
  select pg_get_functiondef(oid) into def
  from pg_proc
  where proname = 'add_pos_sales_order_payment' and pronamespace = 'public'::regnamespace;
  if def is null then raise exception 'add_pos_sales_order_payment not found'; end if;
  if position('close_repair_tickets' in def) > 0 then
    raise exception 'add_pos_sales_order_payment already honours the flag';
  end if;
  if (length(def) - length(replace(def, anchor, ''))) / length(anchor) <> 1 then
    raise exception 'expected exactly one close_pos_repair_tickets_for_order call';
  end if;

  patched := replace(def, anchor,
    E'    perform public.close_pos_repair_tickets_for_order(\n'
    '      saved_order.id,\n'
    '      selected_staff.display_name,\n'
    '      saved_order.invoice_number,\n'
    '      saved_order.customer_name,\n'
    '      saved_order.customer_phone,\n'
    '      coalesce(nullif(lower(btrim(payload->>''close_repair_tickets'')), '''')::boolean, true)\n'
    '    );');

  execute patched;
end
$migration$;
