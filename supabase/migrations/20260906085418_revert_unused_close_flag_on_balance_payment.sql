-- Reverts a change made earlier today from a stale reading of this schema.
--
-- Closing a repair card no longer happens during checkout at all: the POS calls
-- finalize_pos_repair_ticket_after_checkout once payment has succeeded, and
-- close_pos_repair_tickets_for_order deliberately only records the billing and
-- leaves the card open. Passing a close_repair_tickets flag from the balance
-- payment payload therefore did nothing, while implying to the next reader that
-- it did. The call goes back to the plain form.
do $migration$
declare
  def text;
  patched text;
  anchor constant text :=
    E'      saved_order.customer_phone,\n'
    '      coalesce(nullif(lower(btrim(payload->>''close_repair_tickets'')), '''')::boolean, true)\n'
    '    );';
begin
  select pg_get_functiondef(oid) into def
  from pg_proc
  where proname = 'add_pos_sales_order_payment' and pronamespace = 'public'::regnamespace;
  if def is null then raise exception 'add_pos_sales_order_payment not found'; end if;

  if position(anchor in def) = 0 then
    raise notice 'flag already absent, nothing to revert';
    return;
  end if;

  patched := replace(def, anchor, E'      saved_order.customer_phone\n    );');
  execute patched;
end
$migration$;
