-- Allow North Lakes staff to review admin cost and settlement drafts without
-- granting any write access. Staff access remains scoped to the store stored
-- in the validated NL report session.

create or replace function public.get_nl_sales_report_partner_json(target_report_id bigint)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  with base as (
    select public.get_nl_sales_report_json(target_report_id) as payload
  ), redacted_items as (
    select coalesce(jsonb_agg(
      (item.value
        - 'cost_unit_price_ex_gst'
        - 'cost_unit_price_inc_gst'
        - 'cost_total_inc_gst'
        - 'cost_notes'
        - 'cost_updated_at')
      || jsonb_build_object(
        'cost_unit_price_ex_gst', null,
        'cost_unit_price_inc_gst', null,
        'cost_total_inc_gst', null,
        'cost_notes', '',
        'cost_updated_at', null
      )
      order by (item.value->>'line_order')::integer
    ), '[]'::jsonb) as payload
    from base
    cross join lateral jsonb_array_elements(coalesce(base.payload->'items', '[]'::jsonb)) item
  )
  select case
    -- A store-entry draft has not been submitted to admin yet, so it has no
    -- admin cost draft to expose. Once submitted, saved admin costs are
    -- visible immediately, while all write RPCs remain admin-only.
    when base.payload->>'status' = 'draft' then base.payload || jsonb_build_object(
      'payable_total_inc_gst', 0,
      'payable_cost_ex_gst', 0,
      'payable_gst', 0,
      'items', redacted_items.payload
    )
    else base.payload
  end
  from base
  cross join redacted_items;
$$;

create or replace function public.list_nl_monthly_charges(
  session_token text,
  date_from text default null,
  date_to text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
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
      'read_only', true,
      'uploaded_product_payable_inc_gst', report_totals.product_payable,
      'product_payable_total_inc_gst', report_totals.product_payable,
      'settlement_payable_by_nl_inc_gst', charge_totals.payable_to_techm8_total,
      'grand_payable_total_inc_gst', charge_totals.payable_to_techm8_total,
      'cash_received_by_nl_inc_gst', charge.cash_retained_inc_gst,
      'settlement_deductions_total_inc_gst', charge_totals.settlement_deductions_total,
      'net_settlement_inc_gst', round(
        charge_totals.techm8_received_total
        - charge_totals.settlement_deductions_total,
        2
      ),
      'settlement_direction', case
        when charge_totals.techm8_received_total - charge_totals.settlement_deductions_total > 0
          then 'techm8_pays_nl'
        when charge_totals.techm8_received_total - charge_totals.settlement_deductions_total < 0
          then 'nl_pays_techm8'
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
      round(
        report_totals.product_payable
        + charge.rent_inc_gst
        + charge.internet_inc_gst
        + charge.mobile_inc_gst
        + charge.pos_inc_gst
        + charge.franchise_fee_inc_gst,
        2
      ) as payable_to_techm8_total,
      round(
        report_totals.product_payable
        + charge.rent_inc_gst
        + charge.internet_inc_gst
        + charge.mobile_inc_gst
        + charge.pos_inc_gst
        + charge.franchise_fee_inc_gst
        + charge.cash_retained_inc_gst,
        2
      ) as settlement_deductions_total,
      round(
        charge.tyro_received_inc_gst
        + charge.bank_transfer_received_inc_gst
        + charge.after_zip_received_inc_gst,
        2
      ) as techm8_received_total
  ) charge_totals
  where charge.store_id = session_row.store_id
    and charge.status in ('draft', 'uploaded')
    and charge.charge_month between from_date_value and to_date_value;

  return jsonb_build_object('ok', true, 'charges', charges_json);
end;
$$;

revoke all on function public.get_nl_sales_report_partner_json(bigint)
from public, anon, authenticated;

revoke all on function public.list_nl_monthly_charges(text, text, text)
from public, anon, authenticated;

grant execute on function public.list_nl_monthly_charges(text, text, text)
to anon, authenticated;
