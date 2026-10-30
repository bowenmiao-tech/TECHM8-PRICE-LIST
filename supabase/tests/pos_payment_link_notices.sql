-- A paid link shows on the store's tills until a staff member there
-- acknowledges it, with enough of the order to say deposit or paid in full.
-- Every fixture write is rolled back.
begin;
do $test$
declare
  token text := gen_random_uuid()::text;
  store_row public.store_locations%rowtype;
  shift_row public.pos_store_shifts%rowtype;
  staff_row public.staff_directory%rowtype;
  sale_code text := 'TEST-LINK-NOTICE-' || gen_random_uuid()::text;
  result jsonb;
  link jsonb;
  notice jsonb;
  failed boolean;
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
  if shift_row.id is null then raise exception 'No open shift available for payment notice test'; end if;
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

  -- $189 repair, $20 deposit by link.
  result := public.save_pos_sales_order_with_payment_link_for_store(token, jsonb_build_object(
    'id', sale_code,
    'store_code', store_row.store_code,
    'staff_name', staff_row.display_name,
    'shift_id', shift_row.shift_code,
    'customer_name', 'Notice Test',
    'customer_phone', '0499000004',
    'payment_method', 'Online Payment',
    'payments', '[]'::jsonb,
    'total', 189,
    'items', jsonb_build_array(jsonb_build_object(
      'product_id', 'special-notice-test', 'sku', 'SPECIAL', 'name', 'Notice test item',
      'category', 'Special Products', 'qty', 1, 'unit_price', 189, 'line_total', 189, 'is_special', true)),
    'payment_link', jsonb_build_object('email', 'notice@example.com', 'amount', 20)
  ));
  link := result->'payment_link';
  perform public.attach_pos_payment_link(jsonb_build_object(
    'link_code', link->>'link_code', 'stripe_checkout_session_id', 'cs_test_notice', 'email_sent', true));

  -- Not paid yet: nothing to announce.
  result := public.list_pos_payment_links_for_store(token, store_row.store_code, null, null, true);
  assert not exists (select 1 from jsonb_array_elements(result->'payment_links') item
    where item->>'link_code' = link->>'link_code'), 'An unpaid link was announced';

  perform public.complete_pos_payment_link(jsonb_build_object(
    'link_code', link->>'link_code', 'stripe_checkout_session_id', 'cs_test_notice', 'amount', 20));

  result := public.list_pos_payment_links_for_store(token, store_row.store_code, null, null, true);
  select item into notice from jsonb_array_elements(result->'payment_links') item
  where item->>'link_code' = link->>'link_code';
  assert notice is not null, 'The paid link was not announced';
  assert (notice->>'paid_amount')::numeric = 20, 'Notice paid amount is wrong';
  assert (notice->>'order_total')::numeric = 189, 'Notice order total is wrong';
  assert (notice->>'order_balance_due')::numeric = 169, 'Notice balance is wrong';
  assert notice->>'order_items' = 'Notice test item', 'Notice items are wrong';
  assert notice->>'customer_phone' = '0499000004', 'Notice customer phone is missing';

  -- Another store cannot clear it.
  failed := false;
  begin
    perform public.acknowledge_pos_payment_link_for_store(token, 'no-such-store', link->>'link_code', staff_row.display_name);
  exception when others then failed := true; end;
  assert failed, 'A notice was cleared from the wrong store';

  result := public.acknowledge_pos_payment_link_for_store(token, store_row.store_code, link->>'link_code', staff_row.display_name);
  assert result #>> '{payment_link,acknowledged_by}' = staff_row.display_name, 'Acknowledgement not recorded';
  result := public.list_pos_payment_links_for_store(token, store_row.store_code, null, null, true);
  assert not exists (select 1 from jsonb_array_elements(result->'payment_links') item
    where item->>'link_code' = link->>'link_code'), 'An acknowledged notice came back';
end;
$test$;
select 'reached end' as status;
rollback;
