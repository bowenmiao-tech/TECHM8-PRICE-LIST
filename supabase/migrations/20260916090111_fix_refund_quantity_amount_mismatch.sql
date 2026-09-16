create or replace function public.enforce_pos_refund_line_return_amount()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  sales_line public.pos_sales_order_lines%rowtype;
  maximum_amount numeric(12,2);
begin
  select * into sales_line
  from public.pos_sales_order_lines line
  where line.id = new.sales_order_line_id;

  if not found then
    raise exception 'Refund sale line was not found';
  end if;

  if new.returned_quantity > 0
    and sales_line.line_type in ('product', 'retail', 'used_device') then
    maximum_amount := round(
      (sales_line.line_total / nullif(sales_line.quantity, 0)) * new.returned_quantity,
      2
    );
    if new.amount > maximum_amount then
      raise exception 'Refund amount cannot exceed % for % returned item(s)',
        maximum_amount, new.returned_quantity;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_pos_refund_line_return_amount_trigger
  on public.pos_sales_refund_lines;
create trigger enforce_pos_refund_line_return_amount_trigger
before insert or update of amount, returned_quantity, sales_order_line_id
on public.pos_sales_refund_lines
for each row execute function public.enforce_pos_refund_line_return_amount();

revoke all on function public.enforce_pos_refund_line_return_amount()
  from public, anon, authenticated;
grant execute on function public.enforce_pos_refund_line_return_amount()
  to service_role;

do $correction$
declare
  target_refund_id bigint;
  current_refund_amount numeric(12,2);
  current_line_amount numeric(12,2);
begin
  select refund.id, refund.amount, refund_line.amount
  into target_refund_id, current_refund_amount, current_line_amount
  from public.pos_sales_refunds refund
  join public.pos_sales_orders sales_order on sales_order.id = refund.sales_order_id
  join public.pos_sales_refund_lines refund_line on refund_line.refund_id = refund.id
  join public.pos_sales_order_lines sales_line on sales_line.id = refund_line.sales_order_line_id
  where sales_order.order_code = 'POS-1789527066615'
    and refund.refund_code = 'RFD-A9E25514BF2F4D2185'
    and sales_line.sku = '8830389'
    and refund_line.returned_quantity = 1
  for update of refund, refund_line;

  if target_refund_id is null then
    raise notice 'Invoice #4000 refund is not present; no data correction was needed.';
  elsif current_refund_amount = 99.00 and current_line_amount = 70.00 then
    update public.pos_sales_refund_lines refund_line
    set amount = 35.00
    from public.pos_sales_order_lines sales_line
    where refund_line.refund_id = target_refund_id
      and sales_line.id = refund_line.sales_order_line_id
      and sales_line.sku = '8830389'
      and refund_line.returned_quantity = 1;

    update public.pos_sales_refunds
    set amount = 64.00,
        refund_payload = coalesce(refund_payload, '{}'::jsonb) || jsonb_build_object(
          'system_correction', jsonb_build_object(
            'corrected_at', now(),
            'reason', 'Corrected refund amount to match the recorded returned quantities',
            'original_refund_amount', 99.00,
            'corrected_refund_amount', 64.00,
            'original_line_amount', 70.00,
            'corrected_line_amount', 35.00
          )
        )
    where id = target_refund_id;
  elsif current_refund_amount <> 64.00 or current_line_amount <> 35.00 then
    raise exception 'Invoice #4000 refund data no longer matches the expected correction scope';
  end if;
end;
$correction$;

comment on function public.enforce_pos_refund_line_return_amount() is
  'Prevents a returned quantity from refunding more than the proportional paid line amount. Quantity zero remains available for financial-only adjustments.';
