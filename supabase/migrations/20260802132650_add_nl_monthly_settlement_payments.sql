alter table public.nl_monthly_charges
  add column if not exists tyro_received_inc_gst numeric(12,2) not null default 0,
  add column if not exists bank_transfer_received_inc_gst numeric(12,2) not null default 0,
  add column if not exists after_zip_received_inc_gst numeric(12,2) not null default 0,
  add column if not exists cash_retained_inc_gst numeric(12,2) not null default 0;

alter table public.nl_monthly_charges
  drop constraint if exists nl_monthly_charges_amounts_check;

alter table public.nl_monthly_charges
  add constraint nl_monthly_charges_amounts_check check (
    rent_inc_gst >= 0
    and internet_inc_gst >= 0
    and mobile_inc_gst >= 0
    and pos_inc_gst >= 0
    and franchise_fee_inc_gst >= 0
    and tyro_received_inc_gst >= 0
    and bank_transfer_received_inc_gst >= 0
    and after_zip_received_inc_gst >= 0
    and cash_retained_inc_gst >= 0
  );

create or replace function public.get_nl_monthly_charge_json(target_charge_id bigint)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', charge.id,
    'charge_month', charge.charge_month,
    'store_id', charge.store_id,
    'rent_inc_gst', charge.rent_inc_gst,
    'internet_inc_gst', charge.internet_inc_gst,
    'mobile_inc_gst', charge.mobile_inc_gst,
    'pos_inc_gst', charge.pos_inc_gst,
    'franchise_fee_inc_gst', charge.franchise_fee_inc_gst,
    'monthly_charge_total_inc_gst', round(
      charge.rent_inc_gst
      + charge.internet_inc_gst
      + charge.mobile_inc_gst
      + charge.pos_inc_gst
      + charge.franchise_fee_inc_gst,
      2
    ),
    'tyro_received_inc_gst', charge.tyro_received_inc_gst,
    'bank_transfer_received_inc_gst', charge.bank_transfer_received_inc_gst,
    'after_zip_received_inc_gst', charge.after_zip_received_inc_gst,
    'cash_retained_inc_gst', charge.cash_retained_inc_gst,
    'techm8_received_total_inc_gst', round(
      charge.tyro_received_inc_gst
      + charge.bank_transfer_received_inc_gst
      + charge.after_zip_received_inc_gst,
      2
    ),
    'recorded_payments_total_inc_gst', round(
      charge.tyro_received_inc_gst
      + charge.bank_transfer_received_inc_gst
      + charge.after_zip_received_inc_gst
      + charge.cash_retained_inc_gst,
      2
    ),
    'notes', charge.notes,
    'status', charge.status,
    'uploaded_at', charge.uploaded_at,
    'updated_at', charge.updated_at
  )
  from public.nl_monthly_charges charge
  where charge.id = target_charge_id;
$$;

create or replace function public.get_nl_monthly_charge_admin(
  session_token text,
  target_month text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  month_value date;
  month_end date;
  selected_store_id bigint;
  selected_charge_id bigint;
  charge_payload jsonb;
  sales_total numeric(12,2);
  product_payable_total numeric(12,2);
  uploaded_product_payable_total numeric(12,2);
  payable_by_nl_total numeric;
  techm8_received_total numeric;
  net_settlement numeric;
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;

  month_value := date_trunc(
    'month',
    coalesce(
      nullif(target_month, '')::date,
      (now() at time zone 'Australia/Brisbane')::date
    )
  )::date;
  month_end := (month_value + interval '1 month - 1 day')::date;

  select store.id into selected_store_id
  from public.store_locations store
  where store.store_code = 'northlakes'
  limit 1;

  if selected_store_id is null then
    raise exception 'North Lakes store not found';
  end if;

  select charge.id into selected_charge_id
  from public.nl_monthly_charges charge
  where charge.store_id = selected_store_id
    and charge.charge_month = month_value;

  charge_payload := case
    when selected_charge_id is null then jsonb_build_object(
      'id', null,
      'charge_month', month_value,
      'store_id', selected_store_id,
      'rent_inc_gst', 0,
      'internet_inc_gst', 0,
      'mobile_inc_gst', 0,
      'pos_inc_gst', 0,
      'franchise_fee_inc_gst', 0,
      'monthly_charge_total_inc_gst', 0,
      'tyro_received_inc_gst', 0,
      'bank_transfer_received_inc_gst', 0,
      'after_zip_received_inc_gst', 0,
      'cash_retained_inc_gst', 0,
      'techm8_received_total_inc_gst', 0,
      'recorded_payments_total_inc_gst', 0,
      'notes', '',
      'status', 'draft',
      'uploaded_at', null,
      'updated_at', null
    )
    else public.get_nl_monthly_charge_json(selected_charge_id)
  end;

  select
    coalesce(sum((report_json->>'sales_total_inc_gst')::numeric), 0),
    coalesce(sum((report_json->>'payable_total_inc_gst')::numeric), 0),
    coalesce(sum(
      case when report_status in ('confirmed', 'settled')
        then (report_json->>'payable_total_inc_gst')::numeric
        else 0
      end
    ), 0)
  into sales_total, product_payable_total, uploaded_product_payable_total
  from (
    select
      report.status as report_status,
      public.get_nl_sales_report_json(report.id) as report_json
    from public.nl_sales_reports report
    where report.store_id = selected_store_id
      and report.report_date between month_value and month_end
  ) report_totals;

  payable_by_nl_total := round(
    product_payable_total
    + (charge_payload->>'monthly_charge_total_inc_gst')::numeric,
    2
  );
  techm8_received_total := round(
    (charge_payload->>'techm8_received_total_inc_gst')::numeric,
    2
  );
  net_settlement := round(payable_by_nl_total - techm8_received_total, 2);

  return jsonb_build_object(
    'ok', true,
    'charge', charge_payload,
    'sales_total_inc_gst', round(sales_total, 2),
    'product_payable_total_inc_gst', round(product_payable_total, 2),
    'uploaded_product_payable_total_inc_gst', round(uploaded_product_payable_total, 2),
    'grand_payable_total_inc_gst', payable_by_nl_total,
    'settlement_payable_by_nl_inc_gst', payable_by_nl_total,
    'techm8_received_total_inc_gst', techm8_received_total,
    'net_settlement_inc_gst', net_settlement,
    'settlement_direction', case
      when net_settlement > 0 then 'nl_pays_techm8'
      when net_settlement < 0 then 'techm8_pays_nl'
      else 'no_payment_due'
    end
  );
end;
$$;

create or replace function public.save_nl_monthly_charge(
  session_token text,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  month_value date;
  selected_store_id bigint;
  existing_charge public.nl_monthly_charges%rowtype;
  saved_charge public.nl_monthly_charges%rowtype;
  rent_value numeric(12,2);
  internet_value numeric(12,2);
  mobile_value numeric(12,2);
  pos_value numeric(12,2);
  franchise_value numeric(12,2);
  tyro_value numeric(12,2);
  bank_transfer_value numeric(12,2);
  after_zip_value numeric(12,2);
  cash_value numeric(12,2);
begin
  if not public.is_valid_admin_session(session_token) then
    raise exception 'Invalid admin session';
  end if;
  if jsonb_typeof(payload) <> 'object' then
    raise exception 'Payload must be an object';
  end if;

  month_value := date_trunc(
    'month',
    coalesce(
      nullif(payload->>'charge_month', '')::date,
      (now() at time zone 'Australia/Brisbane')::date
    )
  )::date;

  begin
    rent_value := coalesce(nullif(payload->>'rent_inc_gst', '')::numeric(12,2), 0);
    internet_value := coalesce(nullif(payload->>'internet_inc_gst', '')::numeric(12,2), 0);
    mobile_value := coalesce(nullif(payload->>'mobile_inc_gst', '')::numeric(12,2), 0);
    pos_value := coalesce(nullif(payload->>'pos_inc_gst', '')::numeric(12,2), 0);
    franchise_value := coalesce(nullif(payload->>'franchise_fee_inc_gst', '')::numeric(12,2), 0);
    tyro_value := coalesce(nullif(payload->>'tyro_received_inc_gst', '')::numeric(12,2), 0);
    bank_transfer_value := coalesce(nullif(payload->>'bank_transfer_received_inc_gst', '')::numeric(12,2), 0);
    after_zip_value := coalesce(nullif(payload->>'after_zip_received_inc_gst', '')::numeric(12,2), 0);
    cash_value := coalesce(nullif(payload->>'cash_retained_inc_gst', '')::numeric(12,2), 0);
  exception when others then
    raise exception 'Monthly settlement amounts must be valid numbers';
  end;

  if rent_value < 0 or internet_value < 0 or mobile_value < 0
    or pos_value < 0 or franchise_value < 0 or tyro_value < 0
    or bank_transfer_value < 0 or after_zip_value < 0 or cash_value < 0 then
    raise exception 'Monthly settlement amounts cannot be negative';
  end if;

  select store.id into selected_store_id
  from public.store_locations store
  where store.store_code = 'northlakes'
  limit 1;

  if selected_store_id is null then
    raise exception 'North Lakes store not found';
  end if;

  select * into existing_charge
  from public.nl_monthly_charges charge
  where charge.store_id = selected_store_id
    and charge.charge_month = month_value
  for update;

  if found and existing_charge.status = 'uploaded' then
    raise exception 'This month has already been uploaded and is read-only';
  end if;

  insert into public.nl_monthly_charges (
    store_id,
    charge_month,
    rent_inc_gst,
    internet_inc_gst,
    mobile_inc_gst,
    pos_inc_gst,
    franchise_fee_inc_gst,
    tyro_received_inc_gst,
    bank_transfer_received_inc_gst,
    after_zip_received_inc_gst,
    cash_retained_inc_gst,
    notes,
    status
  )
  values (
    selected_store_id,
    month_value,
    rent_value,
    internet_value,
    mobile_value,
    pos_value,
    franchise_value,
    tyro_value,
    bank_transfer_value,
    after_zip_value,
    cash_value,
    coalesce(trim(payload->>'notes'), ''),
    'draft'
  )
  on conflict (store_id, charge_month) do update set
    rent_inc_gst = excluded.rent_inc_gst,
    internet_inc_gst = excluded.internet_inc_gst,
    mobile_inc_gst = excluded.mobile_inc_gst,
    pos_inc_gst = excluded.pos_inc_gst,
    franchise_fee_inc_gst = excluded.franchise_fee_inc_gst,
    tyro_received_inc_gst = excluded.tyro_received_inc_gst,
    bank_transfer_received_inc_gst = excluded.bank_transfer_received_inc_gst,
    after_zip_received_inc_gst = excluded.after_zip_received_inc_gst,
    cash_retained_inc_gst = excluded.cash_retained_inc_gst,
    notes = excluded.notes
  returning * into saved_charge;

  return jsonb_build_object(
    'ok', true,
    'charge', public.get_nl_monthly_charge_json(saved_charge.id)
  );
end;
$$;

create or replace function public.list_nl_monthly_charges(
  session_token text,
  date_from text default null,
  date_to text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  session_row public.nl_report_sessions%rowtype;
  from_date_value date;
  to_date_value date;
  charges_json jsonb;
begin
  if not public.is_valid_nl_report_session(session_token) then
    raise exception 'Invalid NL report session';
  end if;

  select * into session_row
  from public.nl_report_sessions
  where session_hash = encode(extensions.digest(session_token, 'sha256'), 'hex')
    and expires_at > now();

  to_date_value := coalesce(
    nullif(date_to, '')::date,
    (now() at time zone 'Australia/Brisbane')::date
  );
  from_date_value := coalesce(
    nullif(date_from, '')::date,
    date_trunc('month', to_date_value)::date
  );

  if from_date_value > to_date_value then
    raise exception 'From date cannot be after to date';
  end if;
  if to_date_value - from_date_value > 366 then
    raise exception 'Date range cannot exceed 366 days';
  end if;

  select coalesce(jsonb_agg(
    public.get_nl_monthly_charge_json(charge.id)
    || jsonb_build_object(
      'uploaded_product_payable_inc_gst', report_totals.product_payable,
      'product_payable_total_inc_gst', report_totals.product_payable,
      'settlement_payable_by_nl_inc_gst', round(
        report_totals.product_payable + charge_totals.monthly_charge_total,
        2
      ),
      'grand_payable_total_inc_gst', round(
        report_totals.product_payable + charge_totals.monthly_charge_total,
        2
      ),
      'net_settlement_inc_gst', round(
        report_totals.product_payable
        + charge_totals.monthly_charge_total
        - charge_totals.techm8_received_total,
        2
      ),
      'settlement_direction', case
        when report_totals.product_payable + charge_totals.monthly_charge_total - charge_totals.techm8_received_total > 0
          then 'nl_pays_techm8'
        when report_totals.product_payable + charge_totals.monthly_charge_total - charge_totals.techm8_received_total < 0
          then 'techm8_pays_nl'
        else 'no_payment_due'
      end
    )
    order by charge.charge_month desc
  ), '[]'::jsonb)
  into charges_json
  from public.nl_monthly_charges charge
  cross join lateral (
    select coalesce(sum(
      (public.get_nl_sales_report_partner_json(report.id)->>'payable_total_inc_gst')::numeric
    ), 0) as product_payable
    from public.nl_sales_reports report
    where report.store_id = charge.store_id
      and report.report_date >= charge.charge_month
      and report.report_date < charge.charge_month + interval '1 month'
  ) report_totals
  cross join lateral (
    select
      charge.rent_inc_gst
      + charge.internet_inc_gst
      + charge.mobile_inc_gst
      + charge.pos_inc_gst
      + charge.franchise_fee_inc_gst as monthly_charge_total,
      charge.tyro_received_inc_gst
      + charge.bank_transfer_received_inc_gst
      + charge.after_zip_received_inc_gst as techm8_received_total
  ) charge_totals
  where charge.store_id = session_row.store_id
    and charge.status = 'uploaded'
    and charge.charge_month between from_date_value and to_date_value;

  return jsonb_build_object('ok', true, 'charges', charges_json);
end;
$$;

revoke all on function public.get_nl_monthly_charge_json(bigint) from public, anon, authenticated;

revoke all on function public.get_nl_monthly_charge_admin(text, text) from public;
revoke all on function public.save_nl_monthly_charge(text, jsonb) from public;
revoke all on function public.list_nl_monthly_charges(text, text, text) from public;

grant execute on function public.get_nl_monthly_charge_admin(text, text) to anon, authenticated;
grant execute on function public.save_nl_monthly_charge(text, jsonb) to anon, authenticated;
grant execute on function public.list_nl_monthly_charges(text, text, text) to anon, authenticated;
