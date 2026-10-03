-- Product project: an international tracking number means the forwarder has
-- already shipped the batch. 已出收据 is only for batches still waiting for one,
-- so saving a draft/declared batch with a number moves it to shipped.

create or replace function public.purchase_admin_save_shipment(payload jsonb, actor text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  actor_name text := public.purchase_actor(actor);
  target_id bigint := public.purchase_bigint(payload->'id');
  forwarder bigint := public.purchase_bigint(payload->'forwarder_id');
  receive_store bigint := public.purchase_bigint(payload->'received_store_id');
  next_status text := coalesce(public.purchase_text(payload->'status'), 'draft');
  today date := (timezone('Australia/Brisbane', now()))::date;
  numbers text[];
  parcel_ids bigint[];
  saved_id bigint;
begin
  if next_status not in ('draft', 'declared', 'shipped', 'arrived', 'received', 'stocked', 'closed') then
    raise exception 'Invalid shipment status.';
  end if;
  if forwarder is not null and not exists (select 1 from public.purchase_forwarders where id = forwarder) then
    raise exception 'Forwarder not found.';
  end if;
  if receive_store is not null and not exists (select 1 from public.stores where id = receive_store) then
    raise exception 'Receiving store not found.';
  end if;

  select coalesce(array_agg(entry.number order by entry.first_seen), '{}')
  into numbers
  from (
    select btrim(value) as number, min(ord) as first_seen
    from jsonb_array_elements_text(coalesce(payload->'tracking_numbers', '[]'::jsonb))
      with ordinality as element(value, ord)
    where btrim(value) <> ''
    group by btrim(value)
  ) entry;

  if cardinality(numbers) > 0 and next_status in ('draft', 'declared') then
    next_status := 'shipped';
  end if;

  if target_id is null then
    insert into public.purchase_shipments (forwarder_id, status, created_by)
    values (forwarder, next_status, actor_name)
    returning id into saved_id;
  else
    perform 1 from public.purchase_shipments where id = target_id for update;
    if not found then raise exception 'Shipment not found.'; end if;
    saved_id := target_id;
  end if;

  update public.purchase_shipments shipment
  set
    forwarder_id = forwarder,
    channel = public.purchase_text(payload->'channel'),
    tracking_numbers = numbers,
    status = next_status,
    declared_at = coalesce(public.purchase_date(payload->'declared_at'),
      case when next_status <> 'draft' then coalesce(shipment.declared_at, today) end),
    shipped_at = coalesce(public.purchase_date(payload->'shipped_at'),
      case when next_status in ('shipped', 'arrived', 'received', 'stocked') then coalesce(shipment.shipped_at, today) end),
    eta = public.purchase_date(payload->'eta'),
    arrived_at = coalesce(public.purchase_date(payload->'arrived_at'),
      case when next_status in ('arrived', 'received', 'stocked') then coalesce(shipment.arrived_at, today) end),
    received_at = case
      when next_status in ('received', 'stocked') then coalesce(
        (nullif(payload->>'received_at', ''))::timestamptz, shipment.received_at, now())
      else (nullif(payload->>'received_at', ''))::timestamptz
    end,
    received_by = public.purchase_text(payload->'received_by'),
    received_store_id = receive_store,
    received_cartons = public.purchase_bigint(payload->'received_cartons')::integer,
    stocked_at = case when next_status = 'stocked' then coalesce(shipment.stocked_at, now()) else shipment.stocked_at end,
    stocked_by = case when next_status = 'stocked' then coalesce(shipment.stocked_by, actor_name) else shipment.stocked_by end,
    freight_amount = public.purchase_numeric(payload->'freight_amount'),
    freight_currency = coalesce(public.purchase_text(payload->'freight_currency'), 'CNY'),
    weight_kg = public.purchase_numeric(payload->'weight_kg'),
    notes = public.purchase_text(payload->'notes')
  where shipment.id = saved_id;

  if payload ? 'parcel_ids' then
    select coalesce(array_agg(distinct (value)::bigint), '{}')
    into parcel_ids
    from jsonb_array_elements_text(coalesce(payload->'parcel_ids', '[]'::jsonb)) value;

    if exists (
      select 1 from public.purchase_parcels parcel
      where parcel.shipment_id = saved_id
        and not (parcel.id = any(parcel_ids))
        and exists (select 1 from public.purchase_receipt_lines line where line.parcel_id = parcel.id)
    ) then
      raise exception 'A parcel that has already been counted cannot be removed from its batch.';
    end if;
    if exists (
      select 1 from public.purchase_parcels parcel
      where parcel.id = any(parcel_ids)
        and parcel.shipment_id is distinct from saved_id
        and exists (select 1 from public.purchase_receipt_lines line where line.parcel_id = parcel.id)
    ) then
      raise exception 'A parcel that has already been counted cannot move to another batch.';
    end if;
    if (select count(*) from public.purchase_parcels where id = any(parcel_ids)) <> coalesce(cardinality(parcel_ids), 0) then
      raise exception 'Parcel not found.';
    end if;

    update public.purchase_parcels parcel
    set shipment_id = null
    where parcel.shipment_id = saved_id and not (parcel.id = any(parcel_ids));

    update public.purchase_parcels parcel
    set
      shipment_id = saved_id,
      forwarder_id = coalesce(parcel.forwarder_id, forwarder)
    where parcel.id = any(parcel_ids)
      and parcel.shipment_id is distinct from saved_id;
  end if;

  return jsonb_build_object('ok', true, 'id', saved_id);
end;
$$;

update public.purchase_shipments
set status = 'shipped'
where status in ('draft', 'declared')
  and cardinality(tracking_numbers) > 0;
