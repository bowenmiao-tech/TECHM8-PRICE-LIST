-- Price-list rows may contain a range, but a repair ticket must contain one
-- exact agreed amount. Validate and canonicalize both POS tickets and legacy
-- intake submissions at the database boundary.
create or replace function public.enforce_pos_repair_ticket_numeric_price()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  raw_price text := btrim(coalesce(new.price, ''));
  numeric_price numeric(12,2);
begin
  if raw_price !~ '^[$]?[0-9]+([.][0-9]{1,2})?$' then
    raise exception 'Repair price must be one numeric amount, not a range';
  end if;

  numeric_price := replace(raw_price, '$', '')::numeric;
  if numeric_price <= 0 or numeric_price > 1000000 then
    raise exception 'Repair price must be between 0.01 and 1000000.00';
  end if;

  new.price := '$' || to_char(numeric_price, 'FM999999990.00');
  return new;
end;
$$;

drop trigger if exists enforce_pos_repair_ticket_numeric_price_trigger
  on public.pos_repair_tickets;
create trigger enforce_pos_repair_ticket_numeric_price_trigger
before insert or update of price on public.pos_repair_tickets
for each row
execute function public.enforce_pos_repair_ticket_numeric_price();

create or replace function public.enforce_repair_intake_numeric_price()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  raw_price text := btrim(coalesce(new.quoted_price, ''));
  numeric_price numeric(12,2);
  normalized_price text;
begin
  if raw_price !~ '^[$]?[0-9]+([.][0-9]{1,2})?$' then
    raise exception 'Repair price must be one numeric amount, not a range';
  end if;

  numeric_price := replace(raw_price, '$', '')::numeric;
  if numeric_price <= 0 or numeric_price > 1000000 then
    raise exception 'Repair price must be between 0.01 and 1000000.00';
  end if;

  normalized_price := to_char(numeric_price, 'FM999999990.00');
  new.quoted_price := normalized_price;
  new.quote_data_json := jsonb_set(
    coalesce(new.quote_data_json, '{}'::jsonb),
    '{price}',
    to_jsonb(normalized_price),
    true
  );
  new.intake_json := jsonb_set(
    coalesce(new.intake_json, '{}'::jsonb),
    '{quotedPrice}',
    to_jsonb(normalized_price),
    true
  );
  return new;
end;
$$;

drop trigger if exists enforce_repair_intake_numeric_price_trigger
  on public.repair_intakes;
create trigger enforce_repair_intake_numeric_price_trigger
before insert or update of quoted_price on public.repair_intakes
for each row
execute function public.enforce_repair_intake_numeric_price();

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint constraint_record
    where constraint_record.conrelid = 'public.pos_repair_tickets'::regclass
      and constraint_record.conname = 'pos_repair_tickets_price_numeric_check'
  ) then
    alter table public.pos_repair_tickets
      add constraint pos_repair_tickets_price_numeric_check
      check (btrim(price) ~ '^[$][0-9]+[.][0-9]{2}$');
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint constraint_record
    where constraint_record.conrelid = 'public.repair_intakes'::regclass
      and constraint_record.conname = 'repair_intakes_quoted_price_numeric_check'
  ) then
    alter table public.repair_intakes
      add constraint repair_intakes_quoted_price_numeric_check
      check (btrim(quoted_price) ~ '^[0-9]+[.][0-9]{2}$');
  end if;
end;
$$;

revoke all on function public.enforce_pos_repair_ticket_numeric_price()
  from public, anon, authenticated;
revoke all on function public.enforce_repair_intake_numeric_price()
  from public, anon, authenticated;

comment on function public.enforce_pos_repair_ticket_numeric_price() is
  'Requires one positive numeric repair price and stores it as canonical currency text.';
comment on function public.enforce_repair_intake_numeric_price() is
  'Requires one positive numeric intake price and synchronizes its JSON snapshots.';
