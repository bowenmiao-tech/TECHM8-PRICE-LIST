-- A sale finished by payment link is saved owing the link amount, the paid
-- link lands on that invoice once (Stripe retries are no-ops), a newer link
-- replaces the old one, and a link paid after the invoice was settled another
-- way is kept aside for a refund instead of overpaying the invoice.
-- Every fixture write is rolled back.
begin;
do $test$
declare
  token text := gen_random_uuid()::text;
  store_row public.store_locations%rowtype;
  shift_row public.pos_store_shifts%rowtype;
  staff_row public.staff_directory%rowtype;
  link_sale_code text := 'TEST-LINK-SALE-' || gen_random_uuid()::text;
  split_sale_code text := 'TEST-LINK-SPLIT-' || gen_random_uuid()::text;
  result jsonb;
  link jsonb;
  second_link jsonb;
  saved_order public.pos_sales_orders%rowtype;
  payment_count integer;
  failed boolean;
  sale jsonb;
begin
  select shift_record.* into shift_row
  from public.pos_store_shifts shift_record
  where shift_record.status = 'open'
    and shift_record.business_date = (now() at time zone 'Australia/Brisbane')::date
    and shift_record.opening_confirmed_at is not null
    and exists (
      select 1 from public.staff_directory staff
      where staff.active
        and lower(staff.display_name) = lower(shift_record.current_staff_name)
        and public.staff_has_store_access(staff.id, shift_record.store_id)
    )
  order by shift_record.id desc
  limit 1;
  if shift_row.id is null then raise exception 'No open shift available for payment link test'; end if;
  select * into store_row from public.store_locations where id = shift_row.store_id;
  select staff.* into staff_row
  from public.staff_directory staff
  where staff.active
    and lower(staff.display_name) = lower(shift_row.current_staff_name)
    and public.staff_has_store_access(staff.id, store_row.id)
  limit 1;

  insert into public.staff_sessions(staff_id, session_hash, token_digest, expires_at)
  values (
    staff_row.id,
    extensions.crypt(token, extensions.gen_salt('bf')),
    encode(extensions.digest(token, 'sha256'), 'hex'),
    now() + interval '5 minutes'
  );

  sale := jsonb_build_object(
    'id', link_sale_code,
    'store_code', store_row.store_code,
    'staff_name', staff_row.display_name,
    'shift_id', shift_row.shift_code,
    'customer_name', 'Link Test',
    'customer_phone', '0499000003',
    'payment_method', 'Online Payment',
    'payments', '[]'::jsonb,
    'total', 80,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', 'special-link-test', 'sku', 'SPECIAL', 'name', 'Link test item',
      'category', 'Special Products', 'qty', 1, 'unit_price', 80, 'line_total', 80, 'is_special', true
    )),
    'payment_link', jsonb_build_object('email', 'Link.Test@Example.com', 'amount', 80)
  );

  -- More than the sale is refused and nothing is saved.
  failed := false;
  begin
    perform public.save_pos_sales_order_with_payment_link_for_store(token,
      sale || jsonb_build_object('payment_link', jsonb_build_object('email', 'a@b.co', 'amount', 81)));
  exception when others then
    failed := sqlerrm like '%more than the balance due%';
  end;
  assert failed, 'An oversized link was not refused';
  assert not exists (select 1 from public.pos_sales_orders where order_code = link_sale_code),
    'A refused link still saved the sale';

  -- Whole sale by link: saved owing $80, no payment rows, link pending.
  result := public.save_pos_sales_order_with_payment_link_for_store(token, sale);
  assert (result->>'ok')::boolean, 'Link checkout failed';
  link := result->'payment_link';
  assert result #>> '{order,payment_status}' = 'deposit', 'Link sale should be owing';
  assert (result #>> '{order,amount_paid}')::numeric = 0, 'Placeholder payment was not removed';
  assert (result #>> '{order,balance_due}')::numeric = 80, 'Balance due is wrong';
  assert jsonb_array_length(result #> '{order,payments}') = 0, 'Placeholder payment row is visible';
  assert result #>> '{order,customer_email}' = 'link.test@example.com', 'Customer email not kept on the invoice';
  assert link->>'status' = 'pending' and (link->>'amount')::numeric = 80, 'Link not opened';

  -- A retried save neither duplicates the sale nor opens another link.
  result := public.save_pos_sales_order_with_payment_link_for_store(token, sale);
  assert result->'payment_link' = 'null'::jsonb, 'A retried save opened a second link';
  assert (select count(*) from public.pos_payment_links pl
    join public.pos_sales_orders so on so.id = pl.sales_order_id where so.order_code = link_sale_code) = 1,
    'Retry created another link row';

  perform public.attach_pos_payment_link(jsonb_build_object(
    'link_code', link->>'link_code', 'stripe_checkout_session_id', 'cs_test_first',
    'checkout_url', 'https://checkout.stripe.com/test', 'expires_at', now() + interval '1 day', 'email_sent', true));

  -- Resending replaces the first link and hands back its session to close.
  second_link := public.create_pos_payment_link_for_store(token, jsonb_build_object(
    'store_code', store_row.store_code, 'staff_name', staff_row.display_name, 'shift_id', shift_row.shift_code,
    'order_id', link_sale_code, 'email', 'link.test@example.com', 'amount', 80))->'payment_link';
  assert second_link->'replaced_session_ids' = '["cs_test_first"]'::jsonb, 'Old session was not handed back';
  assert (select status from public.pos_payment_links where link_code = link->>'link_code') = 'replaced',
    'Old link was not replaced';
  perform public.attach_pos_payment_link(jsonb_build_object(
    'link_code', second_link->>'link_code', 'stripe_checkout_session_id', 'cs_test_second', 'email_sent', true));

  -- Wrong session or amount is refused.
  failed := false;
  begin
    perform public.complete_pos_payment_link(jsonb_build_object(
      'link_code', second_link->>'link_code', 'stripe_checkout_session_id', 'cs_test_first', 'amount', 80));
  exception when others then failed := sqlerrm like '%does not belong%'; end;
  assert failed, 'A foreign session was accepted';
  failed := false;
  begin
    perform public.complete_pos_payment_link(jsonb_build_object(
      'link_code', second_link->>'link_code', 'stripe_checkout_session_id', 'cs_test_second', 'amount', 79));
  exception when others then failed := sqlerrm like '%does not match%'; end;
  assert failed, 'A short payment was accepted';

  -- Paid: one Online Payment row, no shift, invoice paid. A retry changes nothing.
  result := public.complete_pos_payment_link(jsonb_build_object(
    'link_code', second_link->>'link_code', 'stripe_checkout_session_id', 'cs_test_second',
    'stripe_payment_intent_id', 'pi_test', 'amount', 80));
  assert (result->>'applied')::boolean and not (result->>'already_recorded')::boolean, 'Payment not applied';
  assert result #>> '{order,payment_status}' = 'paid', 'Invoice not marked paid';
  assert result #>> '{order,payment_method}' = 'Online Payment', 'Payment method not recorded';
  select * into saved_order from public.pos_sales_orders where order_code = link_sale_code;
  assert saved_order.amount_paid = 80, 'Amount paid is wrong';
  select count(*) into payment_count from public.pos_sales_order_payments
  where sales_order_id = saved_order.id and method = 'Online Payment' and shift_id is null;
  assert payment_count = 1, 'Online payment row missing or attached to a shift';

  result := public.complete_pos_payment_link(jsonb_build_object(
    'link_code', second_link->>'link_code', 'stripe_checkout_session_id', 'cs_test_second', 'amount', 80));
  assert (result->>'already_recorded')::boolean, 'Retry was not recognised';
  select count(*) into payment_count from public.pos_sales_order_payments where sales_order_id = saved_order.id;
  assert payment_count = 1, 'A Stripe retry paid the invoice twice';

  -- The old link paid anyway after the invoice was settled: kept aside, not applied.
  result := public.complete_pos_payment_link(jsonb_build_object(
    'link_code', link->>'link_code', 'stripe_checkout_session_id', 'cs_test_first', 'amount', 80));
  assert not (result->>'applied')::boolean, 'An overpayment was applied';
  assert result #>> '{payment_link,status}' = 'paid_unapplied', 'Overpayment not flagged for refund';
  select count(*) into payment_count from public.pos_sales_order_payments where sales_order_id = saved_order.id;
  assert payment_count = 1, 'An overpayment reached the invoice';

  -- Split: $30 cash now, $50 by link. Cash stays on the shift; the link owes the rest.
  result := public.save_pos_sales_order_with_payment_link_for_store(token, sale || jsonb_build_object(
    'id', split_sale_code,
    'payment_method', 'Cash',
    'payments', jsonb_build_array(jsonb_build_object('method', 'Cash', 'amount', 30)),
    'payment_link', jsonb_build_object('email', 'split@example.com', 'amount', 50)
  ));
  assert (result #>> '{order,amount_paid}')::numeric = 30, 'Counter payment lost';
  assert (result #>> '{order,balance_due}')::numeric = 50, 'Split balance is wrong';
  assert result #>> '{order,payments,0,method}' = 'Cash', 'Cash payment missing';
  assert result #>> '{order,payments,0,shift_id}' = shift_row.shift_code, 'Cash payment lost its shift';

  result := public.list_pos_payment_links_for_store(token, store_row.store_code, split_sale_code, null);
  assert jsonb_array_length(result->'payment_links') = 1, 'Listing by invoice failed';
end;
$test$;
rollback;
