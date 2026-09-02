-- Generalizes the protected RepairDesk historical importer so it can serve more
-- than one store, and approves TechM8 Fairfield invoices 1-11877.
--
-- Each approved store is pinned to its own store code, order-code prefix and
-- maximum invoice number, so a payload can never be imported into the wrong
-- store or beyond the range that was reconciled against the RepairDesk exports.

create or replace function public.import_repairdesk_sales_batch(batch_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invoice jsonb;
  item jsonb;
  payment jsonb;
  target_store public.store_locations%rowtype;
  existing_order public.pos_sales_orders%rowtype;
  saved_order public.pos_sales_orders%rowtype;
  distinct_store_count integer;
  batch_store_key text;
  store_display_name text;
  store_code_value text;
  order_prefix_value text;
  max_invoice_value bigint;
  invoice_number_value bigint;
  line_number_value integer;
  payment_number_value integer;
  invoice_total numeric(12,2);
  invoice_amount_paid numeric(12,2);
  calculated_line_total numeric(12,2);
  calculated_payment_total numeric(12,2);
  created_at_value timestamptz;
  imported_invoice_count integer := 0;
  imported_line_count integer := 0;
  imported_payment_count integer := 0;
begin
  if jsonb_typeof(batch_payload) <> 'array' then
    raise exception 'RepairDesk import payload must be an array';
  end if;
  if jsonb_array_length(batch_payload) = 0 or jsonb_array_length(batch_payload) > 100 then
    raise exception 'RepairDesk import batch must contain between 1 and 100 invoices';
  end if;

  select count(distinct lower(coalesce(entry->>'source_store_name', '')))
  into distinct_store_count
  from jsonb_array_elements(batch_payload) entry;

  if distinct_store_count <> 1 then
    raise exception 'A RepairDesk import batch must contain exactly one source store';
  end if;

  batch_store_key := lower(coalesce(batch_payload->0->>'source_store_name', ''));

  select rules.display_name, rules.store_code, rules.order_prefix, rules.max_invoice
  into store_display_name, store_code_value, order_prefix_value, max_invoice_value
  from (
    values
      ('techm8 toowong',   'TechM8 Toowong',   'toowong',   'RD-TW-INV-',  3848::bigint),
      ('techm8 fairfield', 'TechM8 Fairfield', 'fairfield', 'RD-FF-INV-', 11877::bigint)
  ) as rules(match_name, display_name, store_code, order_prefix, max_invoice)
  where rules.match_name = batch_store_key;

  if store_code_value is null then
    raise exception 'RepairDesk source store "%" is not approved for historical import', batch_store_key;
  end if;

  select *
  into target_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = store_code_value
  limit 1;

  if not found then
    raise exception 'The % store is unavailable', store_display_name;
  end if;

  for invoice in
    select value from jsonb_array_elements(batch_payload)
  loop
    if jsonb_typeof(invoice) <> 'object'
      or lower(coalesce(invoice->>'source_system', '')) <> 'repairdesk'
      or lower(coalesce(invoice->>'source_store_name', '')) <> batch_store_key
    then
      raise exception 'Only approved % RepairDesk invoices can use this importer', store_display_name;
    end if;

    invoice_number_value := nullif(trim(invoice->>'invoice_number'), '')::bigint;
    if invoice_number_value < 1 or invoice_number_value > max_invoice_value then
      raise exception 'RepairDesk invoice number % is outside the approved range', invoice_number_value;
    end if;
    if coalesce(trim(invoice->>'order_code'), '') <> order_prefix_value || invoice_number_value::text then
      raise exception 'RepairDesk invoice % has an invalid order code', invoice_number_value;
    end if;
    if jsonb_typeof(invoice->'items') <> 'array' or jsonb_array_length(invoice->'items') = 0 then
      raise exception 'RepairDesk invoice % has no sale lines', invoice_number_value;
    end if;
    if jsonb_typeof(invoice->'payments') <> 'array' then
      raise exception 'RepairDesk invoice % has invalid payments', invoice_number_value;
    end if;

    invoice_total := round(nullif(trim(invoice->>'total'), '')::numeric, 2);
    invoice_amount_paid := round(coalesce(nullif(trim(invoice->>'amount_paid'), '')::numeric, 0), 2);
    created_at_value := nullif(trim(invoice->>'created_at'), '')::timestamptz;
    if created_at_value is null then
      raise exception 'RepairDesk invoice % has invalid totals or date', invoice_number_value;
    end if;

    select round(coalesce(sum(round(
      nullif(trim(line->>'unit_price'), '')::numeric
      * nullif(trim(line->>'quantity'), '')::integer,
      2
    )), 0), 2)
    into calculated_line_total
    from jsonb_array_elements(invoice->'items') line;

    if calculated_line_total <> invoice_total then
      raise exception 'RepairDesk invoice % line total % does not match invoice total %',
        invoice_number_value, calculated_line_total, invoice_total;
    end if;

    select round(coalesce(sum(nullif(trim(entry->>'amount'), '')::numeric), 0), 2)
    into calculated_payment_total
    from jsonb_array_elements(invoice->'payments') entry;

    if calculated_payment_total <> invoice_amount_paid then
      raise exception 'RepairDesk invoice % payment total % does not match amount paid %',
        invoice_number_value, calculated_payment_total, invoice_amount_paid;
    end if;

    select *
    into existing_order
    from public.pos_sales_orders sales_order
    where sales_order.store_id = target_store.id
      and sales_order.invoice_number = invoice_number_value
    for update;

    if found and not (
      lower(coalesce(existing_order.order_payload->>'legacy_import', 'false')) = 'true'
      and lower(coalesce(existing_order.order_payload->>'source_system', '')) = 'repairdesk'
      and coalesce(existing_order.order_payload->>'source_store_name', '') = store_display_name
    ) then
      raise exception 'Invoice number % is already used by a non-legacy % sale',
        invoice_number_value, store_display_name;
    end if;

    insert into public.pos_sales_orders (
      order_code,
      invoice_number,
      store_id,
      business_date,
      staff_name,
      shift_id,
      customer_name,
      customer_phone,
      customer_email,
      payment_method,
      total,
      payment_status,
      amount_paid,
      order_payload,
      created_at
    )
    values (
      trim(invoice->>'order_code'),
      invoice_number_value,
      target_store.id,
      nullif(trim(invoice->>'business_date'), '')::date,
      coalesce(nullif(trim(invoice->>'staff_name'), ''), 'Unknown Staff'),
      null,
      coalesce(nullif(trim(invoice->>'customer_name'), ''), 'Walk-in Customer'),
      coalesce(trim(invoice->>'customer_phone'), ''),
      lower(coalesce(trim(invoice->>'customer_email'), '')),
      coalesce(nullif(trim(invoice->>'payment_method'), ''), 'Unknown'),
      invoice_total,
      case when lower(coalesce(invoice->>'payment_status', '')) = 'deposit' then 'deposit' else 'paid' end,
      invoice_amount_paid,
      coalesce(invoice->'order_payload', '{}'::jsonb) || jsonb_build_object(
        'legacy_import', true,
        'source_system', 'repairdesk',
        'source_store_name', store_display_name,
        'source_invoice_number', invoice_number_value,
        'source_imported_at', now(),
        'sync_pending', false
      ),
      created_at_value
    )
    on conflict (store_id, invoice_number) do update set
      order_code = excluded.order_code,
      business_date = excluded.business_date,
      staff_name = excluded.staff_name,
      shift_id = null,
      customer_name = excluded.customer_name,
      customer_phone = excluded.customer_phone,
      customer_email = excluded.customer_email,
      payment_method = excluded.payment_method,
      total = excluded.total,
      payment_status = excluded.payment_status,
      amount_paid = excluded.amount_paid,
      order_payload = excluded.order_payload,
      created_at = excluded.created_at,
      updated_at = now()
    returning * into saved_order;

    delete from public.pos_sales_order_payments
    where sales_order_id = saved_order.id;
    delete from public.pos_sales_order_lines
    where sales_order_id = saved_order.id;

    line_number_value := 0;
    for item in
      select value from jsonb_array_elements(invoice->'items')
    loop
      line_number_value := line_number_value + 1;
      if nullif(trim(item->>'line_number'), '')::integer <> line_number_value then
        raise exception 'RepairDesk invoice % has a non-sequential line number', invoice_number_value;
      end if;

      insert into public.pos_sales_order_lines (
        sales_order_id,
        line_number,
        line_type,
        product_id,
        sku,
        name,
        category,
        quantity,
        unit_price,
        line_total,
        line_payload,
        legacy_import,
        created_at
      )
      values (
        saved_order.id,
        line_number_value,
        'retail',
        coalesce(trim(item->>'product_id'), ''),
        coalesce(trim(item->>'sku'), ''),
        coalesce(nullif(trim(item->>'name'), ''), 'RepairDesk item'),
        coalesce(trim(item->>'category'), ''),
        nullif(trim(item->>'quantity'), '')::integer,
        nullif(trim(item->>'unit_price'), '')::numeric,
        nullif(trim(item->>'line_total'), '')::numeric,
        coalesce(item->'line_payload', '{}'::jsonb) || jsonb_build_object(
          'legacy_import', true,
          'source_system', 'repairdesk',
          'source_invoice_number', invoice_number_value
        ),
        true,
        created_at_value
      );
      imported_line_count := imported_line_count + 1;
    end loop;

    payment_number_value := 0;
    for payment in
      select value from jsonb_array_elements(invoice->'payments')
    loop
      if round(coalesce(nullif(trim(payment->>'amount'), '')::numeric, 0), 2) = 0 then
        continue;
      end if;
      payment_number_value := payment_number_value + 1;
      insert into public.pos_sales_order_payments (
        sales_order_id,
        payment_number,
        method,
        amount,
        shift_id,
        staff_name,
        business_date,
        taken_at,
        legacy_import,
        created_at
      )
      values (
        saved_order.id,
        payment_number_value,
        coalesce(nullif(trim(payment->>'method'), ''), 'Unknown'),
        round(nullif(trim(payment->>'amount'), '')::numeric, 2),
        null,
        saved_order.staff_name,
        saved_order.business_date,
        coalesce(nullif(trim(payment->>'taken_at'), '')::timestamptz, created_at_value),
        true,
        coalesce(nullif(trim(payment->>'taken_at'), '')::timestamptz, created_at_value)
      );
      imported_payment_count := imported_payment_count + 1;
    end loop;

    insert into public.pos_store_invoice_counters (store_id, last_number, updated_at)
    values (target_store.id, invoice_number_value, now())
    on conflict (store_id) do update set
      last_number = greatest(public.pos_store_invoice_counters.last_number, excluded.last_number),
      updated_at = now();

    imported_invoice_count := imported_invoice_count + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'store_code', store_code_value,
    'invoice_count', imported_invoice_count,
    'line_count', imported_line_count,
    'payment_count', imported_payment_count
  );
end;
$$;

revoke all on function public.import_repairdesk_sales_batch(jsonb) from public;
revoke all on function public.import_repairdesk_sales_batch(jsonb) from anon;
revoke all on function public.import_repairdesk_sales_batch(jsonb) from authenticated;
grant execute on function public.import_repairdesk_sales_batch(jsonb) to service_role;

comment on function public.import_repairdesk_sales_batch(jsonb) is
  'Idempotently imports approved RepairDesk invoice history (TechM8 Toowong 1-3848, TechM8 Fairfield 1-11877) without changing inventory or active shifts.';
