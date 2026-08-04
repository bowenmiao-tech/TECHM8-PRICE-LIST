alter table public.nl_monthly_charges
  add column if not exists payment_status text not null default 'unpaid',
  add column if not exists payment_amount_inc_gst numeric(12,2),
  add column if not exists payment_proof_path text,
  add column if not exists paid_at timestamptz;

alter table public.nl_monthly_charges
  drop constraint if exists nl_monthly_charges_payment_status_check,
  drop constraint if exists nl_monthly_charges_payment_record_check;

alter table public.nl_monthly_charges
  add constraint nl_monthly_charges_payment_status_check
    check (payment_status in ('unpaid', 'paid')),
  add constraint nl_monthly_charges_payment_record_check
    check (
      (
        payment_status = 'unpaid'
        and payment_amount_inc_gst is null
        and payment_proof_path is null
        and paid_at is null
      )
      or
      (
        payment_status = 'paid'
        and payment_amount_inc_gst > 0
        and nullif(btrim(payment_proof_path), '') is not null
        and paid_at is not null
      )
    );

comment on column public.nl_monthly_charges.payment_amount_inc_gst
  is 'GST-inclusive amount TECHM8 confirmed as paid to NL for the uploaded monthly settlement.';
comment on column public.nl_monthly_charges.payment_proof_path
  is 'Object path in the nl-settlement-payment-proofs storage bucket.';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'nl-settlement-payment-proofs',
  'nl-settlement-payment-proofs',
  true,
  8388608,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists nl_settlement_payment_proofs_insert on storage.objects;
create policy nl_settlement_payment_proofs_insert
on storage.objects
for insert
to anon, authenticated
with check (
  bucket_id = 'nl-settlement-payment-proofs'
  and (storage.foldername(name))[1] = 'northlakes'
  and name ~ '^northlakes/[0-9]{4}-[0-9]{2}/[A-Za-z0-9._-]+$'
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
    'payment_status', charge.payment_status,
    'payment_amount_inc_gst', charge.payment_amount_inc_gst,
    'payment_proof_path', charge.payment_proof_path,
    'paid_at', charge.paid_at,
    'updated_at', charge.updated_at
  )
  from public.nl_monthly_charges charge
  where charge.id = target_charge_id;
$$;

create or replace function public.confirm_nl_monthly_settlement_paid(
  session_token text,
  target_month text,
  target_payment_proof_path text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  month_value date;
  selected_store_id bigint;
  selected_charge public.nl_monthly_charges%rowtype;
  product_payable_total numeric(12,2);
  settlement_deductions_total numeric(12,2);
  techm8_received_total numeric(12,2);
  net_settlement numeric(12,2);
  proof_path text;
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
  proof_path := btrim(coalesce(target_payment_proof_path, ''));

  if proof_path !~ '^northlakes/[0-9]{4}-[0-9]{2}/[A-Za-z0-9._-]+$'
    or split_part(proof_path, '/', 2) <> to_char(month_value, 'YYYY-MM') then
    raise exception 'Invalid payment screenshot path';
  end if;

  select store.id into selected_store_id
  from public.store_locations store
  where store.store_code = 'northlakes'
  limit 1;

  if selected_store_id is null then
    raise exception 'North Lakes store not found';
  end if;

  select charge.* into selected_charge
  from public.nl_monthly_charges charge
  where charge.store_id = selected_store_id
    and charge.charge_month = month_value
  for update;

  if selected_charge.id is null then
    raise exception 'Monthly settlement not found';
  end if;
  if selected_charge.status <> 'uploaded' then
    raise exception 'Upload the monthly settlement before confirming payment';
  end if;
  if selected_charge.payment_status = 'paid' then
    raise exception 'This monthly settlement has already been marked as paid';
  end if;

  select coalesce(sum(
    (public.get_nl_sales_report_json(report.id)->>'payable_total_inc_gst')::numeric
  ), 0)
  into product_payable_total
  from public.nl_sales_reports report
  where report.store_id = selected_store_id
    and report.report_date >= month_value
    and report.report_date < month_value + interval '1 month';

  settlement_deductions_total := round(
    product_payable_total
    + selected_charge.rent_inc_gst
    + selected_charge.internet_inc_gst
    + selected_charge.mobile_inc_gst
    + selected_charge.pos_inc_gst
    + selected_charge.franchise_fee_inc_gst
    + selected_charge.cash_retained_inc_gst,
    2
  );
  techm8_received_total := round(
    selected_charge.tyro_received_inc_gst
    + selected_charge.bank_transfer_received_inc_gst
    + selected_charge.after_zip_received_inc_gst,
    2
  );
  net_settlement := round(techm8_received_total - settlement_deductions_total, 2);

  if net_settlement <= 0 then
    raise exception 'TECHM8 does not have a payment due to NL for this month';
  end if;

  update public.nl_monthly_charges
  set payment_status = 'paid',
      payment_amount_inc_gst = net_settlement,
      payment_proof_path = proof_path,
      paid_at = now()
  where id = selected_charge.id;

  return jsonb_build_object(
    'ok', true,
    'charge', public.get_nl_monthly_charge_json(selected_charge.id)
  );
end;
$$;

revoke all on function public.confirm_nl_monthly_settlement_paid(text, text, text) from public;
grant execute on function public.confirm_nl_monthly_settlement_paid(text, text, text) to anon, authenticated;
