-- Balance payments call the five-argument repair billing helper. The separate
-- six-argument overload previously gave its boolean a default, so PostgreSQL
-- could not choose between the two overloads for a five-argument call.

drop function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text, boolean);

create function public.close_pos_repair_tickets_for_order(
  target_order_id bigint,
  acting_staff_name text,
  target_invoice_number bigint,
  target_customer_name text,
  target_customer_phone text,
  should_close boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.pos_repair_tickets repair_ticket
  set
    customer_name = target_customer_name,
    customer_phone = target_customer_phone,
    customer_contact = target_customer_phone,
    updated_by = acting_staff_name,
    updated_at = now(),
    activity = jsonb_build_array(jsonb_build_object(
      'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'type', 'paid',
      'text', 'billed work on invoice #' || target_invoice_number || ' and left the repair card open',
      'staffName', acting_staff_name,
      'at', now()
    )) || coalesce(repair_ticket.activity, '[]'::jsonb)
  where repair_ticket.id in (
    select distinct sales_line.repair_ticket_id
    from public.pos_sales_order_lines sales_line
    where sales_line.sales_order_id = target_order_id
      and sales_line.repair_ticket_id is not null
  )
    and repair_ticket.closed_at is null;
end;
$$;

revoke all on function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text, boolean)
  to service_role;

comment on function public.close_pos_repair_tickets_for_order(bigint, text, bigint, text, text, boolean) is
  'Records repair billing activity. The sixth argument has no default so five-argument balance payments resolve unambiguously.';
