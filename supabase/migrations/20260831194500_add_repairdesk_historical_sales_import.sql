alter table public.pos_sales_orders
  drop constraint if exists pos_sales_orders_after_test_data_reset_check;

alter table public.pos_sales_orders
  add constraint pos_sales_orders_after_test_data_reset_check
  check (
    created_at >= '2026-08-25 16:56:39+00'::timestamptz
    or (
      lower(coalesce(order_payload->>'legacy_import', 'false')) = 'true'
      and lower(coalesce(order_payload->>'source_system', '')) = 'repairdesk'
      and shift_id is null
    )
  );

comment on constraint pos_sales_orders_after_test_data_reset_check on public.pos_sales_orders is
  'Prevents cleared test transactions from returning while allowing shift-free RepairDesk history imports.';

alter table public.pos_sales_orders
  drop constraint if exists pos_sales_orders_total_check;
alter table public.pos_sales_orders
  add constraint pos_sales_orders_total_check
  check (
    total >= 0
    or (
      lower(coalesce(order_payload->>'legacy_import', 'false')) = 'true'
      and lower(coalesce(order_payload->>'source_system', '')) = 'repairdesk'
      and shift_id is null
    )
  );

alter table public.pos_sales_order_lines
  add column if not exists legacy_import boolean not null default false;
alter table public.pos_sales_order_lines
  drop constraint if exists pos_sales_order_lines_quantity_check;
alter table public.pos_sales_order_lines
  add constraint pos_sales_order_lines_quantity_check
  check (quantity <> 0 and (quantity > 0 or legacy_import));
alter table public.pos_sales_order_lines
  drop constraint if exists pos_sales_order_lines_line_total_check;
alter table public.pos_sales_order_lines
  add constraint pos_sales_order_lines_line_total_check
  check (line_total >= 0 or legacy_import);

alter table public.pos_sales_order_payments
  add column if not exists legacy_import boolean not null default false;
alter table public.pos_sales_order_payments
  drop constraint if exists pos_sales_order_payments_amount_check;
alter table public.pos_sales_order_payments
  add constraint pos_sales_order_payments_amount_check
  check (amount <> 0 and (amount > 0 or legacy_import));

create or replace function public.enforce_pos_sales_order_line_price_audit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  order_staff_name text;
  original_price numeric(12,2);
  price_was_overridden boolean;
  is_legacy_line boolean;
begin
  is_legacy_line := new.legacy_import
    and lower(coalesce(new.line_payload->>'legacy_import', 'false')) = 'true'
    and lower(coalesce(new.line_payload->>'source_system', '')) = 'repairdesk';

  if new.quantity = 0 or (new.quantity < 0 and not is_legacy_line) then
    raise exception 'Sale line quantity must be at least one';
  end if;
  if new.unit_price < 0 or new.unit_price > 1000000 then
    raise exception 'Sale line unit price is outside the allowed range';
  end if;
  if new.line_total <> round(new.unit_price * new.quantity, 2) then
    raise exception 'Sale line total does not match unit price and quantity';
  end if;

  price_was_overridden := lower(coalesce(new.line_payload->>'price_overridden', 'false')) = 'true';
  select sales_order.staff_name
  into order_staff_name
  from public.pos_sales_orders sales_order
  where sales_order.id = new.sales_order_id;

  if price_was_overridden and trim(coalesce(order_staff_name, '')) = '' then
    raise exception 'Order staff is required for a price override';
  end if;

  if price_was_overridden then
    begin
      original_price := round(nullif(new.line_payload->>'original_unit_price', '')::numeric, 2);
    exception when invalid_text_representation then
      original_price := null;
    end;
    if original_price is null or original_price < 0 or original_price > 1000000 then
      raise exception 'Original unit price is required for a price override';
    end if;
    new.line_payload := coalesce(new.line_payload, '{}'::jsonb) || jsonb_build_object(
      'price_overridden', true,
      'original_unit_price', original_price,
      'price_override_by', order_staff_name,
      'price_override_at', coalesce(new.created_at, now())
    );
  else
    new.line_payload := coalesce(new.line_payload, '{}'::jsonb) || jsonb_build_object(
      'price_overridden', false,
      'original_unit_price', new.unit_price,
      'price_override_by', '',
      'price_override_at', ''
    );
  end if;

  if new.repair_ticket_id is not null then
    update public.pos_repair_tickets repair_ticket
    set price = '$' || to_char(new.unit_price, 'FM999999990.00')
    where repair_ticket.id = new.repair_ticket_id;
  end if;

  return new;
end;
$$;

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

  select *
  into target_store
  from public.store_locations store_location
  where store_location.active = true
    and store_location.store_code = 'toowong'
  limit 1;

  if not found then
    raise exception 'The Toowong store is unavailable';
  end if;

  for invoice in
    select value from jsonb_array_elements(batch_payload)
  loop
    if jsonb_typeof(invoice) <> 'object'
      or lower(coalesce(invoice->>'source_system', '')) <> 'repairdesk'
      or lower(coalesce(invoice->>'source_store_name', '')) <> 'techm8 toowong'
    then
      raise exception 'Only TechM8 Toowong RepairDesk invoices can use this importer';
    end if;

    invoice_number_value := nullif(trim(invoice->>'invoice_number'), '')::bigint;
    if invoice_number_value < 1 or invoice_number_value > 3286 then
      raise exception 'RepairDesk invoice number % is outside the approved range', invoice_number_value;
    end if;
    if coalesce(trim(invoice->>'order_code'), '') <> 'RD-TW-INV-' || invoice_number_value::text then
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
      and coalesce(existing_order.order_payload->>'source_store_name', '') = 'TechM8 Toowong'
    ) then
      raise exception 'Invoice number % is already used by a non-legacy Toowong sale', invoice_number_value;
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
        'source_store_name', 'TechM8 Toowong',
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
  'Service-role-only, idempotent import for approved TechM8 Toowong RepairDesk invoices 1-3286. It does not attach shifts or update inventory.';
