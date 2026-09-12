-- The POS needs to say which payment line it is correcting, and the payload
-- did not carry the line number. Correcting by position in the array would
-- break the moment a payment is added or the order is re-read.
do $migration$
declare
  def text;
  patched text;
  anchor constant text := E'          ''method'', payment.method,';
begin
  select pg_get_functiondef(oid) into def
  from pg_proc where proname = 'pos_sales_order_payload' and pronamespace = 'public'::regnamespace;
  if def is null then raise exception 'pos_sales_order_payload not found'; end if;
  if position('''payment_number''' in def) > 0 then
    raise notice 'payment_number already exposed';
    return;
  end if;
  if (length(def) - length(replace(def, anchor, ''))) / length(anchor) <> 1 then
    raise exception 'expected exactly one payment method key';
  end if;

  patched := replace(def, anchor,
    E'          ''payment_number'', payment.payment_number,\n' || anchor);
  execute patched;
end
$migration$;
