-- Preserve persisted activity across stale client saves and record server-side changes.
create or replace function public.preserve_pos_repair_activity()
returns trigger language plpgsql set search_path = '' as $$
declare
  existing jsonb := '[]'::jsonb;
  incoming jsonb := '[]'::jsonb;
  generated jsonb := '[]'::jsonb;
  entry jsonb;
  event_type text;
  event_text text;
  details text;
  stamp timestamptz := clock_timestamp();
  actor text := coalesce(nullif(new.updated_by,''),nullif(new.created_by,''),'Unknown staff');
begin
  if tg_op = 'UPDATE' then
    existing := coalesce(old.activity,'[]'::jsonb);
    if old.active = false and new.active = true then
      raise exception 'Deleted repair tickets cannot be reopened by saving an old page';
    end if;
  end if;
  for entry in select value from jsonb_array_elements(coalesce(new.activity,'[]'::jsonb)) loop
    -- Invoice/signature events are derived from their source records, never copied from browser payloads.
    if entry->>'source' in ('invoice','signature','derived') then continue; end if;
    if not exists(select 1 from jsonb_array_elements(existing || incoming) e
      where (e->>'id') is not distinct from (entry->>'id') and (e->>'type') is not distinct from (entry->>'type')) then
      incoming := incoming || jsonb_build_array(entry || jsonb_build_object('staffName',actor,'at',stamp));
    end if;
  end loop;
  if tg_op = 'INSERT' then
    if not exists(select 1 from jsonb_array_elements(incoming) e where e->>'type'='created') then
      event_type:='created'; event_text:='created this repair ticket';
    end if;
  else
    if old.active and not new.active then
      event_type:='deleted'; event_text:='deleted this repair ticket; invoices and payments retained';
    elsif old.closed_at is null and new.closed_at is not null
      and not exists(select 1 from jsonb_array_elements(incoming) e where e->>'type'='finished') then
      event_type:='finished'; event_text:='marked this repair card Done' ||
        case when new.resolution is null then '' else ' — ' || replace(new.resolution,'_',' ') end;
    elsif old.status is distinct from new.status
      and not exists(select 1 from jsonb_array_elements(incoming) e where e->>'type'='status') then
      event_type:='status'; event_text:='moved this ticket from ' || replace(old.status,'_',' ') || ' to ' || replace(new.status,'_',' ');
    end if;
    select string_agg(label, ', ' order by label) into details from (values
      ('title','device / title'),('issue','repair issue'),('price','price'),
      ('customer_name','customer name'),('customer_phone','customer phone'),
      ('intake','inspection / device details / photos'),('display_label','board label'),
      ('device_in_store','device location'),('motherboard_repair','motherboard repair'),
      ('special_order','special order'),('resolution','repair outcome')
    ) fields(key,label) where (to_jsonb(old)->key) is distinct from (to_jsonb(new)->key);
    if details is not null then
      generated := generated || jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,
        'type','details','text','updated ' || details ||
          case when old.price is distinct from new.price then ' (price: ' || old.price || ' → ' || new.price || ')' else '' end,
        'staffName',actor,'at',stamp));
    end if;
    if old.board_position is distinct from new.board_position then
      generated := generated || jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,
        'type','reorder','text','changed this card position on the repair board','staffName',actor,'at',stamp));
    end if;
  end if;
  if event_type is not null then
    generated := generated || jsonb_build_array(jsonb_build_object('id',gen_random_uuid()::text,
      'type',event_type,'text',event_text,'staffName',actor,'at',stamp));
  end if;
  new.activity := generated || incoming || existing;
  return new;
end;
$$;
revoke all on function public.preserve_pos_repair_activity() from public,anon,authenticated;
create trigger zz_preserve_pos_repair_activity before insert or update on public.pos_repair_tickets
for each row execute function public.preserve_pos_repair_activity();

create or replace function public.pos_repair_ticket_activity(ticket_row public.pos_repair_tickets)
returns jsonb language sql stable set search_path = '' as $$
  with orders as (
    select distinct o.id,o.invoice_number from public.pos_sales_orders o
    join public.pos_sales_order_lines l on l.sales_order_id=o.id where l.repair_ticket_id=ticket_row.id
  ), events as (
    select e.value as event from jsonb_array_elements(coalesce(ticket_row.activity,'[]'::jsonb)) e
      where coalesce(e.value->>'source','') not in ('invoice','signature','derived')
    union all
    select jsonb_build_object('id','PAY-'||p.id,'type','paid','source','invoice',
      'staffName',coalesce(nullif(p.staff_name,''),'Unknown staff'),'at',coalesce(p.taken_at,p.created_at),
      'text','received $'||p.amount::text||' via '||p.method||' on invoice #'||o.invoice_number)
    from orders o join public.pos_sales_order_payments p on p.sales_order_id=o.id
    union all
    select jsonb_build_object('id','REFUND-'||r.id,'type','refund','source','invoice',
      'staffName',r.staff_name,'at',r.created_at,
      'text','refunded $'||r.amount::text||' via '||r.method||' on invoice #'||o.invoice_number||
        case when coalesce(r.reason,'')='' then '' else ' — '||r.reason end)
    from orders o join public.pos_sales_refunds r on r.sales_order_id=o.id
    union all
    select jsonb_build_object('id','SIGN-'||s.id,'type','signature','source','signature',
      'staffName',s.witnessed_by,'at',s.signed_at,'text','witnessed the customer signing repair terms '||s.terms_version)
    from public.pos_repair_card_signatures s where s.repair_ticket_id=ticket_row.id
    union all
    select jsonb_build_object('id','DELETE-'||ticket_row.id,'type','deleted','source','derived',
      'staffName',coalesce(nullif(ticket_row.updated_by,''),'Unknown staff'),'at',ticket_row.updated_at,
      'text','deleted this repair ticket; invoices and payments retained')
    where ticket_row.active=false and not exists(
      select 1 from jsonb_array_elements(coalesce(ticket_row.activity,'[]'::jsonb)) e where e->>'type'='deleted'
    )
  )
  select coalesce(jsonb_agg(event order by event->>'at' desc,event->>'id' desc),'[]'::jsonb) from events;
$$;
revoke all on function public.pos_repair_ticket_activity(public.pos_repair_tickets) from public,anon,authenticated;
grant execute on function public.pos_repair_ticket_activity(public.pos_repair_tickets) to service_role;

CREATE OR REPLACE FUNCTION public.pos_repair_ticket_payload(ticket_row pos_repair_tickets)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'id', ticket_row.ticket_code,
    'ticket_code', ticket_row.ticket_code,
    'store_id', stores.store_code,
    'storeId', stores.store_code,
    'store_code', stores.store_code,
    'storeCode', stores.store_code,
    'store_name', stores.store_name,
    'title', ticket_row.title,
    'displayLabel', coalesce(ticket_row.display_label, ''),
    'issue', ticket_row.issue,
    'price', ticket_row.price,
    'status', ticket_row.status,
    'boardPosition', coalesce(ticket_row.board_position, 0),
    'deviceInStore', ticket_row.device_in_store,
    'motherboardRepair', ticket_row.motherboard_repair,
    'specialOrder', ticket_row.special_order,
    'customerName', ticket_row.customer_name,
    'customerPhone', ticket_row.customer_phone,
    'customerContact', ticket_row.customer_phone,
    'resolution', ticket_row.resolution,
    'readyForPickupAt', ticket_row.ready_for_pickup_at,
    'closedAt', ticket_row.closed_at,
    'paymentStatus', case
      when invoice_summary.balance_due > 0 then 'deposit'
      when invoice_summary.invoice_count > 0 then 'paid'
      else 'unpaid'
    end,
    'invoiceOrderId', base_invoice.order_code,
    'invoiceNumber', base_invoice.invoice_number,
    'salesOrderLineId', base_invoice.sales_order_line_id,
    'orderTotal', base_invoice.order_total,
    'depositPaid', base_invoice.amount_paid,
    'balanceDue', invoice_summary.balance_due,
    'baseInvoiced', base_invoice.sales_order_line_id is not null,
    'basePrice', base_price.amount,
    'baseJobName', coalesce(nullif(btrim(ticket_row.issue), ''), 'Repair service'),
    'jobs', jobs.rows,
    'invoiceHistory', invoice_summary.rows,
    'unbilledTotal', round(
      case when base_invoice.sales_order_line_id is null then base_price.amount else 0 end
      + jobs.unbilled_total, 2),
    'outstandingTotal', round(
      invoice_summary.balance_due
      + case when base_invoice.sales_order_line_id is null then base_price.amount else 0 end
      + jobs.unbilled_total, 2),
    'hasUnfinishedJobs', jobs.unfinished_count > 0,
    'canClose', base_invoice.sales_order_line_id is not null
      and jobs.unbilled_count = 0
      and jobs.unfinished_count = 0
      and invoice_summary.balance_due = 0,
    'createdBy', ticket_row.created_by,
    'updatedBy', ticket_row.updated_by,
    'createdAt', ticket_row.created_at,
    'updatedAt', ticket_row.updated_at,
    'statusUpdatedAt', ticket_row.status_updated_at,
    'intake', ticket_row.intake,
    'activity', public.pos_repair_ticket_activity(ticket_row),
    'active', ticket_row.active,
    'comments', ticket_row.comments
  )
  from public.store_locations stores
  cross join lateral (
    select case
      when btrim(coalesce(ticket_row.price, '')) ~ '^[$]?[0-9]+([.][0-9]{1,2})?$'
        then replace(btrim(ticket_row.price), '$', '')::numeric
      else 0
    end as amount
  ) base_price
  left join lateral (
    select
      sales_line.id as sales_order_line_id,
      sales_order.order_code,
      sales_order.invoice_number,
      sales_order.total as order_total,
      sales_order.amount_paid
    from public.pos_sales_order_lines sales_line
    join public.pos_sales_orders sales_order on sales_order.id = sales_line.sales_order_id
    where sales_line.repair_ticket_id = ticket_row.id
      and sales_line.repair_job_id is null
    order by sales_order.created_at
    limit 1
  ) base_invoice on true
  cross join lateral (
    select
      coalesce(jsonb_agg(jsonb_build_object(
        'id', job.job_code,
        'jobCode', job.job_code,
        'name', job.name,
        'price', job.price,
        'note', job.note,
        'status', job.status,
        'approvalMethod', job.approval_method,
        'approvedByCustomer', job.approved_by_customer,
        'approvedByStaff', job.approved_by_staff,
        'approvedAt', job.approved_at,
        'completedBy', job.completed_by,
        'completedAt', job.completed_at,
        'invoiced', billed.sales_order_line_id is not null,
        'invoiceOrderId', billed.order_code,
        'invoiceNumber', billed.invoice_number,
        'createdBy', job.created_by,
        'createdAt', job.created_at,
        'updatedBy', job.updated_by,
        'updatedAt', job.updated_at
      ) order by job.sort_order, job.created_at, job.id), '[]'::jsonb) as rows,
      coalesce(sum(job.price) filter (
        where job.status <> 'cancelled' and billed.sales_order_line_id is null
      ), 0) as unbilled_total,
      count(*) filter (
        where job.status <> 'cancelled' and billed.sales_order_line_id is null
      ) as unbilled_count,
      count(*) filter (where job.status not in ('completed', 'cancelled')) as unfinished_count
    from public.pos_repair_ticket_jobs job
    left join lateral (
      select sales_line.id as sales_order_line_id, sales_order.order_code, sales_order.invoice_number
      from public.pos_sales_order_lines sales_line
      join public.pos_sales_orders sales_order on sales_order.id = sales_line.sales_order_id
      where sales_line.repair_job_id = job.id
      limit 1
    ) billed on true
    where job.repair_ticket_id = ticket_row.id
  ) jobs
  cross join lateral (
    select
      coalesce(jsonb_agg(jsonb_build_object(
        'orderId', linked.order_code,
        'invoiceNumber', linked.invoice_number,
        'paymentStatus', linked.payment_status,
        'total', linked.total,
        'amountPaid', linked.amount_paid,
        'balanceDue', linked.balance_due,
        'createdAt', linked.created_at,
        'lines', linked.lines
      ) order by linked.created_at desc), '[]'::jsonb) as rows,
      coalesce(sum(linked.balance_due), 0) as balance_due,
      count(*) as invoice_count
    from (
      select
        sales_order.id,
        sales_order.order_code,
        sales_order.invoice_number,
        sales_order.payment_status,
        sales_order.total,
        sales_order.amount_paid,
        round(greatest(sales_order.total - sales_order.amount_paid, 0), 2) as balance_due,
        sales_order.created_at,
        (
          select coalesce(jsonb_agg(jsonb_build_object(
            'name', ticket_line.name,
            'amount', ticket_line.line_total,
            'repairJobId', repair_job.job_code
          ) order by ticket_line.line_number), '[]'::jsonb)
          from public.pos_sales_order_lines ticket_line
          left join public.pos_repair_ticket_jobs repair_job on repair_job.id = ticket_line.repair_job_id
          where ticket_line.sales_order_id = sales_order.id
            and ticket_line.repair_ticket_id = ticket_row.id
        ) as lines
      from public.pos_sales_orders sales_order
      where exists (
        select 1
        from public.pos_sales_order_lines sales_line
        where sales_line.sales_order_id = sales_order.id
          and sales_line.repair_ticket_id = ticket_row.id
      )
    ) linked
  ) invoice_summary
  where stores.id = ticket_row.store_id;
$function$;
CREATE OR REPLACE FUNCTION public.search_pos_repair_tickets(session_token text, target_store_code text, search_query text DEFAULT ''::text, result_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  selected_store public.store_locations%rowtype;
  tickets_payload jsonb;
  query_value text := trim(coalesce(search_query, ''));
  phone_query text := regexp_replace(coalesce(search_query, ''), '[^0-9]', '', 'g');
  safe_limit integer := least(greatest(coalesce(result_limit, 200), 1), 500);
begin
  if not public.is_valid_staff_session(session_token) then
    raise exception 'Invalid session';
  end if;

  select * into selected_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = coalesce(trim(target_store_code), '')
    and store_location.store_code <> 'warehouse';

  if not found then
    raise exception 'Store not found';
  end if;

  select coalesce(
    jsonb_agg(public.pos_repair_ticket_payload(ticket) order by ticket.board_position, ticket.status_updated_at desc, ticket.created_at desc),
    '[]'::jsonb
  )
  into tickets_payload
  from (
    select repair_ticket.*
    from public.pos_repair_tickets repair_ticket
    where repair_ticket.store_id = selected_store.id
      and (query_value <> '' or (repair_ticket.active = true and repair_ticket.closed_at is null))
      and (
        query_value = ''
        or repair_ticket.ticket_code ilike '%' || query_value || '%'
        or repair_ticket.display_label ilike '%' || query_value || '%'
        or repair_ticket.customer_name ilike '%' || query_value || '%'
        or repair_ticket.customer_phone ilike '%' || query_value || '%'
        or (phone_query <> '' and regexp_replace(repair_ticket.customer_phone, '[^0-9]', '', 'g') like '%' || phone_query || '%')
        or repair_ticket.title ilike '%' || query_value || '%'
        or repair_ticket.issue ilike '%' || query_value || '%'
        or repair_ticket.intake::text ilike '%' || query_value || '%'
      )
    order by repair_ticket.board_position, repair_ticket.status_updated_at desc, repair_ticket.created_at desc
    limit safe_limit
  ) ticket;

  return jsonb_build_object(
    'ok', true,
    'store_code', selected_store.store_code,
    'store_name', selected_store.store_name,
    'tickets', tickets_payload
  );
end;
$function$;
CREATE OR REPLACE FUNCTION public.move_pos_repair_ticket(session_token text, payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  actor jsonb;
  target_status text := lower(btrim(coalesce(payload->>'status', '')));
  ordered_codes jsonb := coalesce(payload->'ordered_codes', '[]'::jsonb);
  moved_count integer := 0;
begin
  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Move payload must be an object';
  end if;
  if jsonb_typeof(ordered_codes) <> 'array' then
    raise exception 'ordered_codes must be an array';
  end if;
  if jsonb_array_length(ordered_codes) > 300 then
    raise exception 'Too many cards in one reorder';
  end if;
  if target_status not in (
    'need_to_order', 'waiting_shipping', 'repairing',
    'waiting_pickup', 'waiting_customer_confirmation', 'over_3_months_uncollected'
  ) then
    raise exception 'Invalid board column';
  end if;

  actor := public.pos_authorized_actor(
    session_token,
    coalesce(payload->>'store_code', payload->>'store_id'),
    payload->>'staff_name'
  );

  with requested as (
    select entry.value #>> '{}' as ticket_code,
           entry.ordinality * 10 as position
    from jsonb_array_elements(ordered_codes) with ordinality as entry(value, ordinality)
  ), applied as (
    update public.pos_repair_tickets ticket
    set board_position = requested.position,
        updated_by = actor->>'staff_name',
        updated_at = now()
    from requested
    where ticket.ticket_code = requested.ticket_code
      and ticket.store_id = nullif(actor->>'store_id', '')::bigint
      and ticket.status = target_status
      and ticket.closed_at is null
      and ticket.active = true
    returning 1
  )
  select count(*) into moved_count from applied;

  return jsonb_build_object('ok', true, 'reordered', moved_count);
end;
$function$;
