-- POS staff authentication uses the custom x-staff-session token while the
-- browser calls PostgREST as anon. Authenticated Supabase users do not need
-- direct access to these security-definer RPCs.

revoke execute on function public.search_pos_sales_orders(text, text, text, integer, integer, date, date) from authenticated;
revoke execute on function public.get_pos_sales_order_for_store(text, text, text) from authenticated;
revoke execute on function public.add_pos_sales_order_payment_for_store(text, jsonb) from authenticated;
revoke execute on function public.refund_pos_sales_order_for_store(text, jsonb) from authenticated;
