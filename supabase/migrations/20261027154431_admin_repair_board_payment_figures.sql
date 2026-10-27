-- Add payment figures to the admin's existing, authenticated repair report.
do $migration$
declare
  definition text := pg_get_functiondef('public.get_admin_repair_follow_up(text)'::regprocedure);
  patched text;
begin
  if position('payment_details' in definition) > 0 then
    raise exception 'Admin repair payment figures already installed';
  end if;
  patched := replace(definition, '      ticket.price,',
    '      ticket.price,
      public.pos_repair_ticket_payload(ticket) as payment_details,');
  if patched = definition then raise exception 'Repair row anchor missing'; end if;
  definition := patched;
  patched := replace(definition, '''price'', ticket.price,',
    $projection$'price', ticket.price,
        'payment_total', round(case when ticket.payment_details->>'legacySource' = 'RepairDesk'
          and ticket.payment_details->>'orderTotal' is not null
          then (ticket.payment_details->>'orderTotal')::numeric
          else coalesce((select sum((entry->>'total')::numeric)
            from jsonb_array_elements(coalesce(ticket.payment_details->'invoiceHistory', '[]'::jsonb)) entry), 0)
            + coalesce((ticket.payment_details->>'unbilledTotal')::numeric, 0) end, 2),
        'amount_paid', round(case when ticket.payment_details->>'legacySource' = 'RepairDesk'
          and ticket.payment_details->>'depositPaid' is not null
          then (ticket.payment_details->>'depositPaid')::numeric
          else coalesce((select sum((entry->>'amountPaid')::numeric)
            from jsonb_array_elements(coalesce(ticket.payment_details->'invoiceHistory', '[]'::jsonb)) entry), 0) end, 2),
        'outstanding_total', coalesce((ticket.payment_details->>'outstandingTotal')::numeric, 0),$projection$);
  if patched = definition then raise exception 'Repair JSON anchor missing'; end if;
  execute patched;
end;
$migration$;
