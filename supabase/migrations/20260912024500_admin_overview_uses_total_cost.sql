-- The admin overview was still costing stock at the payout alone.
--
-- 20260911001000 moved the device payload and the POS stock summary onto
-- purchase price plus refurbishment, but the admin overview kept its own older
-- definition. That left the owner's screen disagreeing with the shop floor's:
-- Fairfield's six imported devices showed $2,176.20 of stock where the POS said
-- $2,375.20, and realised margin was overstated by whatever had been spent
-- making each device sellable.

do $migration$
declare
  definition text;
  patched text;
  previous text;
begin
  select pg_get_functiondef(oid) into definition
  from pg_proc
  where proname = 'get_admin_used_device_overview' and pronamespace = 'public'::regnamespace;
  if definition is null then raise exception 'get_admin_used_device_overview was not found'; end if;

  patched := definition;

  previous := patched;
  patched := replace(
    patched,
    $anchor$      round(sum(device.purchase_cost), 2) as stock_cost,$anchor$,
    $replacement$      round(sum(device.purchase_cost + public.pos_used_device_refurb_cost(device.id)), 2) as stock_cost,$replacement$
  );
  if patched = previous then
    raise exception 'admin total cost patch: the stock cost anchor was not found';
  end if;

  previous := patched;
  patched := replace(
    patched,
    $anchor$      round(sum(ledger.amount - device.purchase_cost), 2) as realized_margin$anchor$,
    $replacement$      round(sum(ledger.amount - device.purchase_cost - public.pos_used_device_refurb_cost(device.id)), 2) as realized_margin$replacement$
  );
  if patched = previous then
    raise exception 'admin total cost patch: the realized margin anchor was not found';
  end if;

  execute patched;
end;
$migration$;
