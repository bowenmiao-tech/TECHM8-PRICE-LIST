-- New repair tickets must contain the full intake snapshot. Existing tickets
-- remain editable so older incomplete records can still be corrected.
create or replace function public.enforce_complete_new_pos_repair_ticket()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  intake_value jsonb := coalesce(new.intake, '{}'::jsonb);
  device_id_type text;
  password_type text;
  testable_value text;
  test_profile text;
  required_tests text[];
  required_test text;
  test_result text;
  numeric_price text;
begin
  if exists (
    select 1
    from public.pos_repair_tickets existing_ticket
    where existing_ticket.ticket_code = new.ticket_code
  ) then
    return new;
  end if;

  if trim(coalesce(new.title, '')) = '' then
    raise exception 'Repair device or service name is required';
  end if;
  if trim(coalesce(new.issue, '')) = '' then
    raise exception 'Repair issue is required';
  end if;
  if trim(coalesce(new.customer_name, '')) = ''
    or lower(trim(new.customer_name)) = 'walk-in customer' then
    raise exception 'Customer name is required for repair tickets';
  end if;
  if regexp_replace(coalesce(new.customer_phone, ''), '[^0-9]', '', 'g') !~ '^[0-9]{8,12}$' then
    raise exception 'A valid customer phone is required for repair tickets';
  end if;

  numeric_price := regexp_replace(coalesce(new.price, ''), '[^0-9.-]', '', 'g');
  if numeric_price !~ '^[0-9]+(\.[0-9]{1,2})?$' or numeric_price::numeric <= 0 then
    raise exception 'A valid repair price is required';
  end if;

  if coalesce(jsonb_typeof(intake_value->'quote'), '') <> 'object'
    or trim(coalesce(intake_value#>>'{quote,brand}', '')) = ''
    or trim(coalesce(intake_value#>>'{quote,model}', '')) = ''
    or trim(coalesce(intake_value#>>'{quote,issue}', '')) = '' then
    raise exception 'Repair quote selection is incomplete';
  end if;

  device_id_type := coalesce(intake_value->>'deviceIdType', '');
  if device_id_type = 'imei' then
    if regexp_replace(coalesce(intake_value->>'deviceImei', ''), '[^0-9]', '', 'g') !~ '^[0-9]{15}$' then
      raise exception 'A 15-digit IMEI is required';
    end if;
  elsif device_id_type = 'sn' then
    if trim(coalesce(intake_value->>'deviceSerial', '')) = '' then
      raise exception 'Device serial number is required';
    end if;
  elsif device_id_type = 'none' then
    if trim(coalesce(intake_value->>'deviceIdUnavailable', '')) = '' then
      raise exception 'Device ID unavailable reason is required';
    end if;
  else
    raise exception 'Device ID type is required';
  end if;

  password_type := coalesce(intake_value->>'passwordType', '');
  if password_type = 'text' then
    if trim(coalesce(intake_value->>'password', '')) = '' then
      raise exception 'Device password is required';
    end if;
  elsif password_type = 'pattern' then
    if trim(coalesce(intake_value->>'patternValue', '')) = '' then
      raise exception 'Device pattern lock is required';
    end if;
  elsif password_type = 'none' then
    if trim(coalesce(intake_value->>'passwordNoneReason', '')) = '' then
      raise exception 'Password not provided reason is required';
    end if;
  else
    raise exception 'Password type is required';
  end if;

  testable_value := coalesce(intake_value->>'testable', '');
  if testable_value = 'no' then
    if trim(coalesce(intake_value->>'cannotTestReason', '')) = '' then
      raise exception 'Cannot test reason is required';
    end if;
  elsif testable_value = 'yes' then
    test_profile := coalesce(intake_value->>'testProfile', '');
    if test_profile = 'computer' then
      required_tests := array[
        'Screen / Display Condition', 'Keyboard', 'Trackpad / Mouse',
        'Touchscreen', 'Camera', 'Microphone', 'Speakers',
        'Wi-Fi / Bluetooth', 'USB / I/O Ports',
        'Charging Port / Charger Detection', 'Battery Health / Charging',
        'Power Button', 'Boot / Operating System', 'Storage Check',
        'Fan / Thermal Condition', 'Hinges / Housing Condition',
        'Liquid Damage Indicators'
      ];
    elsif test_profile = 'mobile' then
      required_tests := array[
        'Touch glass intact', 'Touch response working', 'Back glass intact',
        'Display / LCD working', 'Housing and frame intact',
        'Power button working', 'Volume buttons working',
        'Fingerprint scanner working', 'Home button working',
        'Face ID working', 'Earpiece speaker working',
        'Proximity sensor working', 'Charging port working',
        'Loudspeaker working', 'Microphone working',
        'Rear camera and lens working', 'Front camera working',
        'Torch / flash working', 'SIM card reader working',
        'Bluetooth / Wi-Fi working', 'Vibrate switch / haptics working',
        'Case and accessories present', 'Battery working',
        'Water damage indicators'
      ];
    else
      raise exception 'Function test profile is required';
    end if;

    if coalesce(jsonb_typeof(intake_value->'tests'), '') <> 'object' then
      raise exception 'Function tests are required';
    end if;

    foreach required_test in array required_tests loop
      test_result := coalesce(intake_value->'tests'->>required_test, '');
      if required_test = 'Case and accessories present' then
        if test_result not in ('Yes', 'No') then
          raise exception 'Function test is incomplete: %', required_test;
        end if;
      elsif test_result not in ('Pass', 'Fail', 'N/A') then
        raise exception 'Function test is incomplete: %', required_test;
      end if;
    end loop;
  else
    raise exception 'Function test choice is required';
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_complete_new_pos_repair_ticket_trigger
  on public.pos_repair_tickets;
create trigger enforce_complete_new_pos_repair_ticket_trigger
before insert on public.pos_repair_tickets
for each row
execute function public.enforce_complete_new_pos_repair_ticket();

revoke all on function public.enforce_complete_new_pos_repair_ticket()
  from public, anon, authenticated;

-- Validate the final employee-entered unit price and write the authenticated
-- order staff name into the immutable line payload audit fields.
create or replace function public.enforce_pos_sales_order_line_price_audit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  order_staff_name text;
  original_price numeric(12,2);
  price_was_overridden boolean;
begin
  if new.quantity < 1 then
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

drop trigger if exists enforce_pos_sales_order_line_price_audit_trigger
  on public.pos_sales_order_lines;
create trigger enforce_pos_sales_order_line_price_audit_trigger
before insert on public.pos_sales_order_lines
for each row
execute function public.enforce_pos_sales_order_line_price_audit();

revoke all on function public.enforce_pos_sales_order_line_price_audit()
  from public, anon, authenticated;

comment on function public.enforce_complete_new_pos_repair_ticket() is
  'Rejects creation of repair tickets until customer, quote, device ID, unlock, and function-test intake details are complete.';

comment on function public.enforce_pos_sales_order_line_price_audit() is
  'Validates employee-entered unit prices and records the actual order staff member in price override audit metadata.';
