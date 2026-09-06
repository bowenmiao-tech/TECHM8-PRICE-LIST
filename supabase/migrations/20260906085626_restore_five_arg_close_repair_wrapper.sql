-- Repairs a replay hazard introduced earlier today.
--
-- fix_ambiguous_repair_close_overload replaced the six-argument function with a
-- version that has no default, and relies on a five-argument wrapper to supply
-- "false" for callers that do not care. A migration earlier today dropped that
-- wrapper as dead code, having read the schema before that change landed.
-- Production still has the wrapper, but replaying the migrations in order would
-- drop it and leave add_pos_sales_order_payment calling a function that no
-- longer exists.
--
-- Recreating it idempotently makes a fresh replay match production again.
create or replace function public.close_pos_repair_tickets_for_order(
  target_order_id bigint,
  acting_staff_name text,
  target_invoice_number bigint,
  target_customer_name text,
  target_customer_phone text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.close_pos_repair_tickets_for_order(
    target_order_id,
    acting_staff_name,
    target_invoice_number,
    target_customer_name,
    target_customer_phone,
    false
  );
end;
$$;

revoke all on function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text)
  from public, anon, authenticated;
