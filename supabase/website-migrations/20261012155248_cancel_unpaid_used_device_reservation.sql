-- Let the POS release a single, unpaid pay-in-store used device order.
-- The website order is the source of truth; cancelling it fires the existing
-- orders_refresh_used_devices trigger before the POS clears its mirror hold.
create or replace function public.cancel_unpaid_used_device_reservation(
  target_device_code text,
  target_order_code text,
  target_store_code text,
  target_actor text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  order_row public.orders%rowtype;
  listing_row public.used_device_listings%rowtype;
  order_code_value text := btrim(coalesce(target_order_code, ''));
  device_code_value text := btrim(coalesce(target_device_code, ''));
  store_code_value text := btrim(coalesce(target_store_code, ''));
  actor_value text := left(btrim(coalesce(target_actor, '')), 120);
  reason_value text;
begin
  if order_code_value = '' or device_code_value = '' or store_code_value = '' or actor_value = '' then
    raise exception 'Order, device, store and staff are required';
  end if;

  select * into order_row
  from public.orders
  where order_code = order_code_value
  for update;
  if not found then raise exception 'Website order not found'; end if;

  select listing.* into listing_row
  from public.used_device_order_claims claim
  join public.used_device_listings listing on listing.id = claim.listing_id
  where claim.order_id = order_row.id
    and listing.device_code = device_code_value
  for update of listing;
  if not found or listing_row.store_code <> store_code_value then
    raise exception 'This website order does not reserve a device at your store';
  end if;
  if listing_row.status <> 'published' then
    raise exception 'This device is no longer published. Review it in the website admin';
  end if;

  if (select count(*) from public.used_device_order_claims where order_id = order_row.id) <> 1
    or (select count(*) from public.order_items where order_id = order_row.id) <> 1
    or not exists (
      select 1 from public.order_items item
      where item.order_id = order_row.id and item.product_id = listing_row.product_id and item.quantity = 1
    ) then
    raise exception 'This order contains other items. Cancel it in the website admin';
  end if;

  if order_row.source is distinct from 'website'
    or order_row.fulfillment_method is distinct from 'pickup'
    or order_row.payment_method_code is distinct from 'pay_in_store'
    or order_row.payment_status is distinct from 'unpaid'
    or order_row.amount_paid is distinct from 0
    or order_row.amount_refunded is distinct from 0
    or order_row.paid_at is not null
    or order_row.stripe_checkout_session_id is not null
    or order_row.stripe_payment_intent_id is not null
    or order_row.zip_checkout_id is not null
    or order_row.zip_charge_id is not null
    or order_row.paypal_order_id is not null
    or order_row.paypal_capture_id is not null then
    raise exception 'This order may have a payment. Review it in the website admin';
  end if;

  if order_row.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'already_cancelled', true,
      'order_code', order_code_value, 'device_code', device_code_value);
  end if;
  if order_row.status is distinct from 'submitted'
    or order_row.fulfillment_status is null
    or order_row.fulfillment_status not in ('new', 'not_started')
    or order_row.cancelled_at is not null then
    raise exception 'This order has progressed. Review it in the website admin';
  end if;

  reason_value := format('Customer did not pay or collect. Restored by %s at %s.', actor_value, store_code_value);
  update public.orders
  set status = 'cancelled',
      fulfillment_status = 'cancelled',
      cancelled_at = now(),
      cancel_reason = reason_value
  where id = order_row.id;

  insert into public.order_events (
    order_id, event_key, event_type, title, description, actor_type, actor_identifier, event_data
  ) values (
    order_row.id, 'used_device_restored:' || device_code_value, 'order_cancelled', 'Order cancelled',
    reason_value, 'admin', actor_value,
    jsonb_build_object('source', 'POS used-device restore', 'device_code', device_code_value,
      'store_code', store_code_value)
  );

  return jsonb_build_object('ok', true, 'order_code', order_code_value,
    'device_code', device_code_value, 'cancelled', true);
end;
$$;

revoke all on function public.cancel_unpaid_used_device_reservation(text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.cancel_unpaid_used_device_reservation(text, text, text, text)
  to service_role;
