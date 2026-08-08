begin;

with confirmed_costs(source_external_id, cost_price) as (
  values
    ('8866'::text, 5::numeric),
    ('6671'::text, 5::numeric),
    ('6659'::text, 20::numeric)
)
update public.products as product
set cost_price = confirmed_costs.cost_price,
    import_status = 'active',
    is_pos_visible = true,
    source_metadata = coalesce(product.source_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'cost_source', 'owner_override',
        'owner_confirmed_cost', confirmed_costs.cost_price
      ),
    updated_at = timezone('utc'::text, now())
from confirmed_costs
where product.source_system = 'repairdesk_car_mounts'
  and product.source_external_id = confirmed_costs.source_external_id;

delete from public.products
where source_system = 'repairdesk_car_mounts'
  and source_external_id in ('9253', '9104', '7816', '7583');

commit;
