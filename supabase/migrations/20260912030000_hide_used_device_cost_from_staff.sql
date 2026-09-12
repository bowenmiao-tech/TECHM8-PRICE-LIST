-- What a device cost the business is management information, not counter
-- information.
--
-- Staff need the sale price to sell, and they enter a purchase price while they
-- are paying a seller. They do not need to see, afterwards, what the shop paid
-- for a device, what it has cost in total, or what it will make. That figure
-- was showing up in five places on the POS: the inventory card, the device
-- detail tiles, the transaction register, the store summary, and inside the
-- error message that refuses a below-cost price.
--
-- All five are closed here at the source rather than hidden in the page, so a
-- staff session cannot obtain the number by reading the API response either.
-- The admin portal reads the tables directly and is unaffected: the register,
-- the overview and the margin columns all still show everything.
--
-- Definitions are normalised to LF before patching because these bodies carry
-- a mix of CRLF and LF from earlier edits.

do $migration$
declare
  definition text;
  patched text;
  previous text;
begin
  -- 1. The device payload the POS renders.
  select replace(pg_get_functiondef(oid), chr(13), '') into definition
  from pg_proc where proname = 'pos_used_device_payload' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'pos_used_device_payload was not found'; end if;

  patched := definition;

  previous := patched;
  patched := replace(
    patched,
    $anchor$    'purchase_cost', device_row.purchase_cost,
    'refurb_cost', public.pos_used_device_refurb_cost(device_row.id),
    'total_cost', round(device_row.purchase_cost + public.pos_used_device_refurb_cost(device_row.id), 2),
    'sale_price', device_row.sale_price,$anchor$,
    $replacement$    'sale_price', device_row.sale_price,$replacement$
  );
  if patched = previous then
    raise exception 'staff cost patch: the payload cost anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$      'payout_amount', acquisition.payout_amount,
$anchor$,
    ''
  );
  if patched = previous then
    raise exception 'staff cost patch: the payout anchor was not found';
  end if;

  execute patched;
end;
$migration$;

do $migration$
declare
  definition text;
  patched text;
begin
  -- 2. The store summary on the used-device workspace.
  select replace(pg_get_functiondef(oid), chr(13), '') into definition
  from pg_proc where proname = 'search_pos_used_devices' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'search_pos_used_devices was not found'; end if;

  patched := replace(
    definition,
    $anchor$        'stock_cost', coalesce(sum(purchase_cost + public.pos_used_device_refurb_cost(used_device.id)) filter (where status in ('inspection', 'ready_for_sale')), 0),
        'stock_retail', coalesce(sum(sale_price) filter (where status in ('inspection', 'ready_for_sale')), 0),
        'realized_margin', coalesce(sum(sale_transaction.amount - used_device.purchase_cost - public.pos_used_device_refurb_cost(used_device.id)) filter (where used_device.status = 'sold'), 0)$anchor$,
    $replacement$        'stock_retail', coalesce(sum(sale_price) filter (where status in ('inspection', 'ready_for_sale')), 0)$replacement$
  );
  if patched = definition then
    raise exception 'staff cost patch: the summary anchor was not found';
  end if;

  execute patched;
end;
$migration$;

do $migration$
declare
  definition text;
  patched text;
begin
  -- 3. The transaction register. An acquisition row's amount is the payout.
  select replace(pg_get_functiondef(oid), chr(13), '') into definition
  from pg_proc where proname = 'get_pos_used_device_transactions' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'get_pos_used_device_transactions was not found'; end if;

  patched := replace(
    definition,
    $anchor$      ledger.amount,
$anchor$,
    $replacement$      case when ledger.transaction_type = 'acquisition' then null else ledger.amount end as amount,
$replacement$
  );
  if patched = definition then
    raise exception 'staff cost patch: the ledger amount anchor was not found';
  end if;

  execute patched;
end;
$migration$;

do $migration$
declare
  definition text;
  patched text;
begin
  -- 4. The refusal itself used to quote the number it was protecting.
  select replace(pg_get_functiondef(oid), chr(13), '') into definition
  from pg_proc where proname = 'update_pos_used_device' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'update_pos_used_device was not found'; end if;

  patched := replace(
    definition,
    $anchor$    raise exception 'This price is below the % this device has cost. Record a reason to price it there', total_cost_value;$anchor$,
    $replacement$    raise exception 'This price is below what this device has cost. Record a reason before pricing it there';$replacement$
  );
  if patched = definition then
    raise exception 'staff cost patch: the below-cost message anchor was not found';
  end if;

  execute patched;
end;
$migration$;

comment on function public.pos_used_device_payload(public.pos_used_devices) is
  'The used-device record as the POS sees it. Deliberately carries no purchase price, refurbishment cost, total cost or payout: what a device cost the business is admin-only, and the admin portal reads the tables directly.';
