-- Prevent offline browser caches from recreating the test transactions removed
-- on 2026-08-26 (Australia/Brisbane). New transactions are unaffected.

delete from public.pos_sales_refund_lines refund_line
using public.pos_sales_refunds refund, public.pos_sales_orders sales_order
where refund_line.refund_id = refund.id
  and refund.sales_order_id = sales_order.id
  and sales_order.created_at < timestamptz '2026-08-25 16:56:39+00';

delete from public.pos_sales_refunds refund
using public.pos_sales_orders sales_order
where refund.sales_order_id = sales_order.id
  and sales_order.created_at < timestamptz '2026-08-25 16:56:39+00';

delete from public.pos_sales_orders
where created_at < timestamptz '2026-08-25 16:56:39+00';

delete from public.pos_repair_tickets
where created_at < timestamptz '2026-08-25 16:56:39+00';

delete from public.repair_intakes
where created_at < timestamptz '2026-08-25 16:56:39+00';

delete from public.pos_store_invoice_counters counter
where not exists (
  select 1
  from public.pos_sales_orders sales_order
  where sales_order.store_id = counter.store_id
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'pos_sales_orders_after_test_data_reset_check'
      and conrelid = 'public.pos_sales_orders'::regclass
  ) then
    alter table public.pos_sales_orders
      add constraint pos_sales_orders_after_test_data_reset_check
      check (created_at >= timestamptz '2026-08-25 16:56:39+00') not valid;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'pos_repair_tickets_after_test_data_reset_check'
      and conrelid = 'public.pos_repair_tickets'::regclass
  ) then
    alter table public.pos_repair_tickets
      add constraint pos_repair_tickets_after_test_data_reset_check
      check (created_at >= timestamptz '2026-08-25 16:56:39+00') not valid;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'repair_intakes_after_test_data_reset_check'
      and conrelid = 'public.repair_intakes'::regclass
  ) then
    alter table public.repair_intakes
      add constraint repair_intakes_after_test_data_reset_check
      check (created_at >= timestamptz '2026-08-25 16:56:39+00') not valid;
  end if;
end;
$$;

alter table public.pos_sales_orders
  validate constraint pos_sales_orders_after_test_data_reset_check;

alter table public.pos_repair_tickets
  validate constraint pos_repair_tickets_after_test_data_reset_check;

alter table public.repair_intakes
  validate constraint repair_intakes_after_test_data_reset_check;

do $$
begin
  if exists (
    select 1 from public.pos_sales_orders
    where created_at < timestamptz '2026-08-25 16:56:39+00'
  ) or exists (
    select 1 from public.pos_repair_tickets
    where created_at < timestamptz '2026-08-25 16:56:39+00'
  ) or exists (
    select 1 from public.repair_intakes
    where created_at < timestamptz '2026-08-25 16:56:39+00'
  ) then
    raise exception 'Pre-reset test transactions remain after cleanup';
  end if;
end;
$$;
