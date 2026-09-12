-- Condition, battery health and colour become correctable.
--
-- These three were fixed at purchase and could never be changed again, which
-- was wrong twice over. A refurbished device legitimately changes grade -- you
-- replace the screen and Fair becomes Good -- and all three appear on the
-- public listing, so a typo at intake was permanently visible to customers and
-- could only be fixed by disposing of the record and buying the device again.
--
-- Each correction appends its own ledger row, because these fields describe
-- what the customer is told they are buying.

alter table public.pos_used_device_transactions
  drop constraint if exists pos_used_device_transactions_transaction_type_check;

alter table public.pos_used_device_transactions
  add constraint pos_used_device_transactions_transaction_type_check
  check (transaction_type in (
    'acquisition', 'status_change', 'price_change', 'sale', 'refund_return',
    'returned_to_seller', 'disposal', 'detail_change'
  ));

do $migration$
declare
  definition text;
  patched text;
  previous text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'update_pos_used_device' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'update_pos_used_device was not found'; end if;

  patched := definition;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  below_cost_reason_value text := trim(coalesce(payload->>'below_cost_reason', ''));$anchor$,
    $replacement$  below_cost_reason_value text := trim(coalesce(payload->>'below_cost_reason', ''));
  condition_grade_value text;
  battery_health_value integer;
  color_value text;
  detail_changes jsonb := '{}'::jsonb;$replacement$
  );
  if patched = previous then
    raise exception 'detail correction patch: the declaration anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  if length(change_note_value) > 500 then raise exception 'Change note is too long'; end if;$anchor$,
    $replacement$  if length(change_note_value) > 500 then raise exception 'Change note is too long'; end if;
  condition_grade_value := coalesce(nullif(trim(payload->>'condition_grade'), ''), device_row.condition_grade);
  color_value := case when payload ? 'color' then trim(payload->>'color') else device_row.color end;
  battery_health_value := case
    when payload ? 'battery_health' then nullif(trim(payload->>'battery_health'), '')::integer
    else device_row.battery_health
  end;
  if condition_grade_value not in ('As New', 'Good', 'Fair', 'Poor', 'Faulty') then
    raise exception 'Device condition is required';
  end if;
  if battery_health_value is not null and (battery_health_value < 0 or battery_health_value > 100) then
    raise exception 'Battery health must be between 0 and 100';
  end if;$replacement$
  );
  if patched = previous then
    raise exception 'detail correction patch: the validation anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$      notes = coalesce(payload->>'notes', notes),$anchor$,
    $replacement$      notes = coalesce(payload->>'notes', notes),
      condition_grade = condition_grade_value,
      battery_health = battery_health_value,
      color = color_value,$replacement$
  );
  if patched = previous then
    raise exception 'detail correction patch: the update anchor was not found';
  end if;

  -- The ledger row goes in beside the price one, so a correction is as
  -- traceable as a reprice.
  previous := patched;
  patched := replace(
    patched,
    $anchor$  if previous_status <> device_row.status then$anchor$,
    $replacement$  if device_row.condition_grade is distinct from previous_condition
    or device_row.battery_health is distinct from previous_battery
    or device_row.color is distinct from previous_color then
    detail_changes := jsonb_strip_nulls(jsonb_build_object(
      'previous_condition_grade', case when device_row.condition_grade is distinct from previous_condition then previous_condition end,
      'condition_grade', case when device_row.condition_grade is distinct from previous_condition then device_row.condition_grade end,
      'previous_battery_health', case when device_row.battery_health is distinct from previous_battery then previous_battery end,
      'battery_health', case when device_row.battery_health is distinct from previous_battery then device_row.battery_health end,
      'previous_color', case when device_row.color is distinct from previous_color then previous_color end,
      'color', case when device_row.color is distinct from previous_color then device_row.color end
    ));
    insert into public.pos_used_device_transactions (
      transaction_code, device_id, store_id, transaction_type, from_status,
      to_status, amount, staff_name, notes, transaction_payload
    ) values (
      'UDTX-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
      device_row.id, device_row.store_id, 'detail_change', previous_status,
      device_row.status, 0, selected_staff.display_name,
      coalesce(nullif(change_note_value, ''), 'Device details corrected'),
      detail_changes
    );
  end if;

  if previous_status <> device_row.status then$replacement$
  );
  if patched = previous then
    raise exception 'detail correction patch: the status ledger anchor was not found';
  end if;

  -- Remember what the values were before the update overwrote the row.
  previous := patched;
  patched := replace(
    patched,
    $anchor$  previous_status := device_row.status;
  previous_price := device_row.sale_price;$anchor$,
    $replacement$  previous_status := device_row.status;
  previous_price := device_row.sale_price;
  previous_condition := device_row.condition_grade;
  previous_battery := device_row.battery_health;
  previous_color := device_row.color;$replacement$
  );
  if patched = previous then
    raise exception 'detail correction patch: the previous-value anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$  previous_price numeric(12,2);$anchor$,
    $replacement$  previous_price numeric(12,2);
  previous_condition text;
  previous_battery integer;
  previous_color text;$replacement$
  );
  if patched = previous then
    raise exception 'detail correction patch: the previous-value declaration anchor was not found';
  end if;

  execute patched;
end;
$migration$;

comment on function public.update_pos_used_device(text, jsonb) is
  'Internal POS used-device update. Status, price, compliance, inspection and the customer-facing details (condition, battery health, colour) each append their own ledger row; `change_note` explains the change without overwriting the device memo.';
