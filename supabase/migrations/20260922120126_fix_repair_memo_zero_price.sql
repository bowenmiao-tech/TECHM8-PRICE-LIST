-- Memo cards are operational notes, not billable repairs. A later price
-- validation update replaced this trigger function and dropped the memo
-- exemption, which prevented new memo cards from being created.
create or replace function public.enforce_pos_repair_ticket_numeric_price()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  raw_price text := btrim(coalesce(new.price, ''));
  numeric_price numeric(12,2);
begin
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
$$;

comment on function public.enforce_pos_repair_ticket_numeric_price() is
  'Requires a positive repair price, except memo cards remain non-billable and special repairs may start at exactly zero.';
