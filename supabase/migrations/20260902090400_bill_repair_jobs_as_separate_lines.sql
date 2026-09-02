-- Lets one repair card be billed across several invoice lines, and more than
-- once over its life: an inspection today, the battery it uncovered next week.
--
-- Three changes to save_pos_sales_order:
--   1. The ticket count check compares DISTINCT tickets, not item count, so
--      three jobs on one card no longer look like two missing tickets.
--   2. The "already invoiced" guard moves from the ticket to the individual
--      job, so the same repair still cannot be billed twice while a second,
--      different repair on the same card can be.
--   3. Each line records which job it billed.
--
-- close_pos_repair_tickets_for_order also gains a flag, because paying is no
-- longer the same thing as finishing the card.
do $migration$
declare
  def text;
  patched text;
  before_len integer;

  declare_anchor constant text := E'  repair_ticket_count integer;';
  count_anchor constant text := E'  select count(*) into repair_item_count\n'
    '  from jsonb_array_elements(payload->''items'') item\n'
    '  where lower(coalesce(item->>''is_repair'', ''false'')) = ''true'';';
  ticket_check_anchor constant text := E'    if repair_ticket_count <> repair_item_count then';
  invoiced_guard_anchor constant text := E'    if exists (\n'
    '      select 1\n'
    '      from public.pos_sales_order_lines sales_line\n'
    '      join public.pos_repair_tickets repair_ticket on repair_ticket.id = sales_line.repair_ticket_id\n'
    '      where repair_ticket.ticket_code in (\n'
    '        select coalesce(\n'
    '          nullif(trim(item->>''ticket_id''), ''''),\n'
    '          nullif(regexp_replace(coalesce(item->>''product_id'', ''''), ''^repair-'', ''''), coalesce(item->>''product_id'', ''''))\n'
    '        )\n'
    '        from jsonb_array_elements(payload->''items'') item\n'
    '        where lower(coalesce(item->>''is_repair'', ''false'')) = ''true''\n'
    '      )\n'
    '    ) then\n'
    '      raise exception ''Repair ticket has already been invoiced'';\n'
    '    end if;';
  insert_cols_anchor constant text := E'    sku, name, category, quantity, unit_price, line_total, line_payload, created_at\n  )';
  insert_vals_anchor constant text := E'    repair_ticket.id,\n'
    '    coalesce(item.value->>''sku'', ''''),';
  join_anchor constant text := E'  from jsonb_array_elements(payload->''items'') with ordinality as item(value, ordinality)\n'
    '  left join public.pos_repair_tickets repair_ticket\n'
    '    on repair_ticket.ticket_code = coalesce(\n'
    '      nullif(trim(item.value->>''ticket_id''), ''''),\n'
    '      nullif(regexp_replace(coalesce(item.value->>''product_id'', ''''), ''^repair-'', ''''), coalesce(item.value->>''product_id'', ''''))\n'
    '    );';
  close_call_anchor constant text := E'      saved_order.customer_phone\n    );';

  procedure_check text;
begin
  select pg_get_functiondef(oid) into def
  from pg_proc where proname = 'save_pos_sales_order' and pronamespace = 'public'::regnamespace;
  if def is null then raise exception 'save_pos_sales_order not found'; end if;
  if position('repair_job_id' in def) > 0 then raise exception 'save_pos_sales_order is already job aware'; end if;

  foreach procedure_check in array array[
    declare_anchor, count_anchor, ticket_check_anchor, invoiced_guard_anchor,
    insert_cols_anchor, insert_vals_anchor, join_anchor, close_call_anchor
  ] loop
    if position(procedure_check in def) = 0 then
      raise exception 'anchor not found: %', left(procedure_check, 60);
    end if;
  end loop;

  patched := def;

  patched := replace(patched, declare_anchor,
    E'  repair_ticket_count integer;\n  repair_distinct_ticket_count integer;');

  -- Count the distinct cards being billed, so several jobs on one card
  -- validate against one ticket rather than looking like missing ones.
  patched := replace(patched, count_anchor, count_anchor || E'\n\n'
    '  select count(distinct coalesce(\n'
    '    nullif(trim(item->>''ticket_id''), ''''),\n'
    '    nullif(regexp_replace(coalesce(item->>''product_id'', ''''), ''^repair-'', ''''), coalesce(item->>''product_id'', ''''))\n'
    '  ))\n'
    '  into repair_distinct_ticket_count\n'
    '  from jsonb_array_elements(payload->''items'') item\n'
    '  where lower(coalesce(item->>''is_repair'', ''false'')) = ''true'';');

  patched := replace(patched, ticket_check_anchor,
    E'    if repair_ticket_count <> repair_distinct_ticket_count then');

  patched := replace(patched, invoiced_guard_anchor,
    E'    if exists (\n'
    '      select 1\n'
    '      from jsonb_array_elements(payload->''items'') item\n'
    '      where lower(coalesce(item->>''is_repair'', ''false'')) = ''true''\n'
    '        and nullif(btrim(coalesce(item->>''repair_job_id'', '''')), '''') is not null\n'
    '        and not exists (\n'
    '          select 1\n'
    '          from public.pos_repair_ticket_jobs job\n'
    '          join public.pos_repair_tickets owner_ticket on owner_ticket.id = job.repair_ticket_id\n'
    '          where job.job_code = btrim(item->>''repair_job_id'')\n'
    '            and owner_ticket.ticket_code = coalesce(\n'
    '              nullif(trim(item->>''ticket_id''), ''''),\n'
    '              nullif(regexp_replace(coalesce(item->>''product_id'', ''''), ''^repair-'', ''''), coalesce(item->>''product_id'', ''''))\n'
    '            )\n'
    '        )\n'
    '    ) then\n'
    '      raise exception ''Repair job does not belong to this ticket'';\n'
    '    end if;\n'
    '\n'
    '    -- Guard the individual job, not the whole card: the same repair can\n'
    '    -- never be billed twice, but another repair on the card still can be.\n'
    '    if exists (\n'
    '      select 1\n'
    '      from jsonb_array_elements(payload->''items'') item\n'
    '      join public.pos_repair_tickets repair_ticket\n'
    '        on repair_ticket.ticket_code = coalesce(\n'
    '          nullif(trim(item->>''ticket_id''), ''''),\n'
    '          nullif(regexp_replace(coalesce(item->>''product_id'', ''''), ''^repair-'', ''''), coalesce(item->>''product_id'', ''''))\n'
    '        )\n'
    '      left join public.pos_repair_ticket_jobs job\n'
    '        on job.job_code = nullif(btrim(coalesce(item->>''repair_job_id'', '''')), '''')\n'
    '       and job.repair_ticket_id = repair_ticket.id\n'
    '      join public.pos_sales_order_lines sales_line\n'
    '        on sales_line.repair_ticket_id = repair_ticket.id\n'
    '       and sales_line.repair_job_id is not distinct from job.id\n'
    '      where lower(coalesce(item->>''is_repair'', ''false'')) = ''true''\n'
    '    ) then\n'
    '      raise exception ''This repair has already been invoiced'';\n'
    '    end if;');

  patched := replace(patched, insert_cols_anchor,
    E'    sku, name, category, quantity, unit_price, line_total, line_payload, created_at,\n'
    '    repair_job_id\n  )');

  patched := replace(patched, join_anchor,
    E'  from jsonb_array_elements(payload->''items'') with ordinality as item(value, ordinality)\n'
    '  left join public.pos_repair_tickets repair_ticket\n'
    '    on repair_ticket.ticket_code = coalesce(\n'
    '      nullif(trim(item.value->>''ticket_id''), ''''),\n'
    '      nullif(regexp_replace(coalesce(item.value->>''product_id'', ''''), ''^repair-'', ''''), coalesce(item.value->>''product_id'', ''''))\n'
    '    )\n'
    '  left join public.pos_repair_ticket_jobs repair_job\n'
    '    on repair_job.job_code = nullif(btrim(coalesce(item.value->>''repair_job_id'', '''')), '''')\n'
    '   and repair_job.repair_ticket_id = repair_ticket.id;');

  -- created_at is the last value in the select list; append the job id after it.
  before_len := length(patched);
  patched := replace(patched,
    E'    item.value,\n    created_at_value\n  from jsonb_array_elements(payload->''items'') with ordinality',
    E'    item.value,\n    created_at_value,\n    repair_job.id\n  from jsonb_array_elements(payload->''items'') with ordinality');
  if length(patched) = before_len then raise exception 'insert value list anchor not found'; end if;

  patched := replace(patched, close_call_anchor,
    E'      saved_order.customer_phone,\n'
    '      coalesce(nullif(lower(btrim(payload->>''close_repair_tickets'')), '''')::boolean, true)\n    );');

  execute patched;
end
$migration$;

-- Paying no longer always finishes the card. When the customer is told the
-- inspection found a battery fault, staff keep the card open and the device
-- stays on the board.
create or replace function public.close_pos_repair_tickets_for_order(
  target_order_id bigint,
  acting_staff_name text,
  target_invoice_number bigint,
  target_customer_name text,
  target_customer_phone text,
  should_close boolean default true
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
    status = case when should_close then 'waiting_pickup' else repair_ticket.status end,
    resolution = case when should_close then coalesce(repair_ticket.resolution, 'repaired') else repair_ticket.resolution end,
    ready_for_pickup_at = case when should_close then coalesce(repair_ticket.ready_for_pickup_at, now()) else repair_ticket.ready_for_pickup_at end,
    closed_at = case when should_close then now() else null end,
    updated_by = acting_staff_name,
    status_updated_at = case when should_close then now() else repair_ticket.status_updated_at end,
    updated_at = now(),
    activity = jsonb_build_array(jsonb_build_object(
      'id', 'ACT-' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'type', 'paid',
      'text', case when should_close
        then 'checked out this repair on invoice #' || target_invoice_number
        else 'billed work on invoice #' || target_invoice_number || ' and kept the card open'
      end,
      'staffName', acting_staff_name,
      'at', now()
    )) || coalesce(repair_ticket.activity, '[]'::jsonb)
  where repair_ticket.id in (
    select sales_line.repair_ticket_id
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
