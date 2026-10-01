-- Preserve RepairDesk source tickets without inventing intake checks, contact details,
-- or a new billable POS sale. Only the database importer can create these records.
create or replace function public.guard_repairdesk_ticket_import()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  source_is_legacy boolean := coalesce(new.intake#>>'{legacy,sourceSystem}', '') = 'repairdesk';
begin
  if tg_op = 'INSERT' then
    if source_is_legacy and (
      session_user <> 'postgres'
      or new.ticket_code !~ '^T-[0-9]+$'
      or new.store_id <> (select id from public.store_locations where store_code = 'northlakes')
    ) then
      raise exception 'Invalid RepairDesk ticket import';
    end if;
  elsif source_is_legacy or coalesce(old.intake#>>'{legacy,sourceSystem}', '') = 'repairdesk' then
    if not source_is_legacy
      or new.ticket_code is distinct from old.ticket_code
      or new.intake->'legacy' is distinct from old.intake->'legacy' then
      raise exception 'RepairDesk source record cannot be changed';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists aa_guard_repairdesk_ticket_import on public.pos_repair_tickets;
create trigger aa_guard_repairdesk_ticket_import
before insert or update on public.pos_repair_tickets
for each row execute function public.guard_repairdesk_ticket_import();

CREATE OR REPLACE FUNCTION public.enforce_complete_new_pos_repair_ticket()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
  if coalesce(new.intake#>>'{legacy,sourceSystem}', '') = 'repairdesk' then
    return new;
  end if;
  if new.card_kind = 'memo' then
    if new.price <> '$0.00' then raise exception 'Memo cards cannot have a base charge'; end if;
    return new;
  end if;
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
  if numeric_price !~ '^[0-9]+(\.[0-9]{1,2})?$'
    or numeric_price::numeric < 0
    or (numeric_price::numeric = 0 and not coalesce(new.special_order, false)) then
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
    elsif test_profile in ('mobile', 'tablet') then
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
$function$;

CREATE OR REPLACE FUNCTION public.enforce_complete_updated_pos_repair_ticket()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if coalesce(old.intake#>>'{legacy,sourceSystem}', '') = 'repairdesk' then
    return new;
  end if;
  if new.card_kind = 'memo' then
    if new.price <> '$0.00' then raise exception 'Memo cards cannot have a base charge'; end if;
    return new;
  end if;
  if not public.pos_repair_intake_is_complete(
    new.title, new.issue, new.customer_name, new.customer_phone, new.price, new.intake
  ) then
    raise exception 'Repair ticket intake is incomplete';
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.enforce_pos_repair_ticket_numeric_price()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  raw_price text := btrim(coalesce(new.price, ''));
  numeric_price numeric(12,2);
begin
  if coalesce(new.intake#>>'{legacy,sourceSystem}', '') = 'repairdesk' then
    return new;
  end if;
  if new.card_kind = 'memo' then
    if raw_price <> '$0.00' then
      raise exception 'Memo cards cannot have a base charge';
    end if;
    return new;
  end if;

  if raw_price !~ '^[$]?[0-9]+([.][0-9]{1,2})?$' then
    raise exception 'Repair price must be one numeric amount, not a range';
  end if;

  numeric_price := replace(raw_price, '$', '')::numeric;
  if numeric_price < 0 or numeric_price > 1000000
    or (numeric_price = 0 and not coalesce(new.special_order, false)) then
    raise exception 'Ordinary repair price must be above zero; only a special repair may start at zero';
  end if;

  new.price := '$' || to_char(numeric_price, 'FM999999990.00');
  return new;
end;
$function$;
