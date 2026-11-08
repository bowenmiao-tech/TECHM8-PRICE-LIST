-- Back glass is due once per calendar month per store, using Brisbane dates.
create or replace function public.get_lcd_inventory_count_form(
  session_token text,
  target_store_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_store public.store_locations%rowtype;
  items_payload jsonb;
  existing_submission jsonb;
  week_start_value date;
  today_value date := (now() at time zone 'Australia/Brisbane')::date;
  glass_counted_this_month boolean;
begin
  if not public.is_valid_staff_session(session_token) then
    raise exception 'Invalid session';
  end if;

  select *
  into selected_store
  from public.store_locations
  where active = true
    and store_code = coalesce(trim(target_store_code), '');

  if not found then
    raise exception 'Store not found';
  end if;


  select exists (
    select 1
    from public.lcd_inventory_count_submissions submission
    join public.lcd_inventory_count_lines line on line.submission_id = submission.id
    where submission.store_id = selected_store.id
      and submission.status in ('pending', 'approved')
      and submission.count_date >= date_trunc('month', today_value)::date
      and submission.count_date < (date_trunc('month', today_value) + interval '1 month')::date
      and line.variant_name ilike 'Back Glass %'
  ) into glass_counted_this_month;

  week_start_value := today_value - ((extract(dow from today_value)::integer + 1) % 7);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'inventory_item_id', lcd.id,
        'model_name', lcd.model_name,
        'variant_name', lcd.variant_name,
        'category_key', lcd.category_key,
        'current_qty', lcd.current_qty
      )
      order by lcd.category_key, lcd.model_name, lcd.variant_name
    ),
    '[]'::jsonb
  )
  into items_payload
  from public.lcd_inventory_items lcd
  where lcd.store_id = selected_store.id
    and lcd.active = true
    and (lcd.variant_name not ilike 'Back Glass %' or not glass_counted_this_month);

  select to_jsonb(submission_row)
  into existing_submission
  from (
    select
      submission.id,
      submission.status,
      submission.store_name,
      submission.staff_name,
      submission.week_start,
      submission.count_date,
      submission.notes,
      submission.review_note,
      submission.discrepancy_count,
      submission.submitted_at,
      submission.reviewed_at
    from public.lcd_inventory_count_submissions submission
    where submission.store_id = selected_store.id
      and submission.week_start = week_start_value
      and submission.status in ('pending', 'approved')
      and (glass_counted_this_month or submission.count_date >= date_trunc('month', today_value)::date)
    order by submission.id desc
    limit 1
  ) submission_row;

  return jsonb_build_object(
    'ok', true,
    'week_start', week_start_value,
    'items', items_payload,
    'current_week_submission', coalesce(existing_submission, 'null'::jsonb)
  );
end;
$$;

create or replace function public.submit_lcd_inventory_count(
  session_token text,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_store public.store_locations%rowtype;
  selected_staff public.staff_directory%rowtype;
  lines_payload jsonb;
  line_payload jsonb;
  count_date_value date;
  week_start_value date;
  today_value date := (now() at time zone 'Australia/Brisbane')::date;
  glass_counted_this_month boolean;
  notes_value text;
  confirmed_value boolean;
  inventory_row public.lcd_inventory_items%rowtype;
  created_submission_id bigint;
  discrepancy_payload jsonb := '[]'::jsonb;
  discrepancy_counter integer := 0;
  line_counter integer := 0;
  counted_qty_value integer;
  line_order_value integer := 0;
  missing_item_count integer;
begin
  if not public.is_valid_staff_session(session_token) then
    raise exception 'Invalid session';
  end if;

  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Payload must be a JSON object';
  end if;

  select *
  into selected_store
  from public.store_locations
  where active = true
    and store_code = coalesce(trim(payload->>'store_code'), '');

  if not found then
    raise exception 'Store not found';
  end if;

  select *
  into selected_staff
  from public.staff_directory
  where active = true
    and display_name = coalesce(trim(payload->>'staff_name'), '');

  if not found then
    raise exception 'Staff member not found';
  end if;

  -- Serialize store submissions, including concurrent monthly counts.
  perform 1 from public.store_locations where id = selected_store.id for update;

  select exists (
    select 1
    from public.lcd_inventory_count_submissions submission
    join public.lcd_inventory_count_lines line on line.submission_id = submission.id
    where submission.store_id = selected_store.id
      and submission.status in ('pending', 'approved')
      and submission.count_date >= date_trunc('month', today_value)::date
      and submission.count_date < (date_trunc('month', today_value) + interval '1 month')::date
      and line.variant_name ilike 'Back Glass %'
  ) into glass_counted_this_month;

  count_date_value := today_value;
  week_start_value := count_date_value - ((extract(dow from count_date_value)::integer + 1) % 7);
  notes_value := coalesce(trim(payload->>'notes'), '');
  confirmed_value := coalesce((payload->>'confirmed')::boolean, false);
  lines_payload := coalesce(payload->'lines', '[]'::jsonb);

  if jsonb_typeof(lines_payload) <> 'array' then
    raise exception 'Count lines must be an array';
  end if;

  if exists (
    select 1
    from public.lcd_inventory_count_submissions submission
    where submission.store_id = selected_store.id
      and submission.week_start = week_start_value
      and submission.status in ('pending', 'approved')
      and (glass_counted_this_month or submission.count_date >= date_trunc('month', today_value)::date)
  ) then
    raise exception 'This store already has a weekly screen and battery count submitted';
  end if;

  if jsonb_array_length(lines_payload) = 0 then
    raise exception 'At least one count row is required';
  end if;

  for line_payload in
    select value
    from jsonb_array_elements(lines_payload)
  loop
    if jsonb_typeof(line_payload) <> 'object' then
      continue;
    end if;

    if coalesce(trim(line_payload->>'inventory_item_id'), '') = '' then
      raise exception 'Each count row requires an inventory item';
    end if;

    counted_qty_value := coalesce(nullif(trim(line_payload->>'counted_qty'), ''), '0')::integer;
    if counted_qty_value < 0 then
      raise exception 'Counted quantity cannot be negative';
    end if;

    select *
    into inventory_row
    from public.lcd_inventory_items lcd
    where lcd.id = (line_payload->>'inventory_item_id')::bigint
      and lcd.store_id = selected_store.id
      and lcd.active = true
    and (lcd.variant_name not ilike 'Back Glass %' or not glass_counted_this_month);

    if not found then
      raise exception 'Inventory item not found for this store';
    end if;

    line_counter := line_counter + 1;

    if inventory_row.current_qty <> counted_qty_value then
      discrepancy_counter := discrepancy_counter + 1;
      discrepancy_payload := discrepancy_payload || jsonb_build_array(
        jsonb_build_object(
          'inventory_item_id', inventory_row.id,
          'model_name', inventory_row.model_name,
          'variant_name', inventory_row.variant_name,
          'system_qty', inventory_row.current_qty,
          'counted_qty', counted_qty_value,
          'delta_qty', counted_qty_value - inventory_row.current_qty
        )
      );
    end if;
  end loop;

  select count(*)
  into missing_item_count
  from public.lcd_inventory_items lcd
  where lcd.store_id = selected_store.id
    and lcd.active = true
    and (lcd.variant_name not ilike 'Back Glass %' or not glass_counted_this_month)
    and not exists (
      select 1
      from jsonb_array_elements(lines_payload) line_item
      where coalesce(trim(line_item->>'inventory_item_id'), '') <> ''
        and (line_item->>'inventory_item_id')::bigint = lcd.id
    );

  if missing_item_count > 0 then
    raise exception 'Every active screen and battery inventory row must be counted';
  end if;

  if discrepancy_counter > 0 and not confirmed_value then
    return jsonb_build_object(
      'ok', false,
      'confirm_required', true,
      'discrepancy_count', discrepancy_counter,
      'discrepancies', discrepancy_payload
    );
  end if;

  insert into public.lcd_inventory_count_submissions (
    store_id,
    staff_id,
    store_name,
    staff_name,
    week_start,
    count_date,
    notes,
    status,
    discrepancy_count,
    submission_source
  )
  values (
    selected_store.id,
    selected_staff.id,
    selected_store.store_name,
    selected_staff.display_name,
    week_start_value,
    count_date_value,
    notes_value,
    'pending',
    discrepancy_counter,
    'staff'
  )
  returning id into created_submission_id;

  line_order_value := 0;
  for line_payload in
    select value
    from jsonb_array_elements(lines_payload)
  loop
    if jsonb_typeof(line_payload) <> 'object' then
      continue;
    end if;

    counted_qty_value := coalesce(nullif(trim(line_payload->>'counted_qty'), ''), '0')::integer;

    select *
    into inventory_row
    from public.lcd_inventory_items lcd
    where lcd.id = (line_payload->>'inventory_item_id')::bigint
      and lcd.store_id = selected_store.id
      and lcd.active = true
    and (lcd.variant_name not ilike 'Back Glass %' or not glass_counted_this_month);

    if not found then
      continue;
    end if;

    line_order_value := line_order_value + 1;

    insert into public.lcd_inventory_count_lines (
      submission_id,
      lcd_inventory_item_id,
      line_order,
      model_name,
      variant_name,
      system_qty,
      counted_qty,
      delta_qty
    )
    values (
      created_submission_id,
      inventory_row.id,
      line_order_value,
      inventory_row.model_name,
      inventory_row.variant_name,
      inventory_row.current_qty,
      counted_qty_value,
      counted_qty_value - inventory_row.current_qty
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'submission_id', created_submission_id,
    'discrepancy_count', discrepancy_counter,
    'status', 'pending'
  );
end;
$$;

