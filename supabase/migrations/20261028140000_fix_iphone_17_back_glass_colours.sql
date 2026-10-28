-- Correct iPhone 17 Air / 17 Pro / 17 Pro Max back glass colours.
-- 17 Air: Space Black, Cloud White, Sky Blue, Light Gold -> 黑 白 蓝 金.
-- 17 Pro / Pro Max: Silver, Deep Blue, Cosmic Orange -> 白 蓝 橙
-- (silver is listed as White 白, as on the older silver models).
with wanted(model_name, labels) as (
  values
    ('iphone 17 air',     array['Black 黑', 'White 白', 'Blue 蓝', 'Gold 金']),
    ('iphone 17 pro',     array['White 白', 'Blue 蓝', 'Orange 橙']),
    ('iphone 17 pro max', array['White 白', 'Blue 蓝', 'Orange 橙'])
)
delete from public.lcd_inventory_items items
using wanted
where lower(items.model_name) = wanted.model_name
  and items.variant_name like 'Back Glass %'
  and not (substr(items.variant_name, length('Back Glass ') + 1) = any(wanted.labels))
  and items.current_qty = 0
  and not exists (select 1 from public.daily_report_lcd_lines l where l.lcd_inventory_item_id = items.id)
  and not exists (select 1 from public.lcd_inventory_count_lines l where l.lcd_inventory_item_id = items.id);

with wanted(model_name, labels) as (
  values
    ('iphone 17 air',     array['Black 黑', 'White 白', 'Blue 蓝', 'Gold 金']),
    ('iphone 17 pro',     array['White 白', 'Blue 蓝', 'Orange 橙']),
    ('iphone 17 pro max', array['White 白', 'Blue 蓝', 'Orange 橙'])
),
models as (
  -- One row per store per model, using that store's spelling of the name.
  select distinct on (items.store_id, wanted.model_name)
    items.store_id, items.model_name, wanted.labels
  from public.lcd_inventory_items items
  join wanted on lower(items.model_name) = wanted.model_name
  join public.store_locations stores on stores.id = items.store_id
  where stores.store_code in ('warehouse', 'parkridge', 'fairfield', 'northlakes', 'toowong')
  order by items.store_id, wanted.model_name, items.id
)
insert into public.lcd_inventory_items (store_id, model_name, variant_name, category_key, current_qty, active)
select models.store_id, models.model_name, 'Back Glass ' || label, 'iphone', 0, true
from models
cross join lateral unnest(models.labels) as label
on conflict (store_id, model_name, variant_name) do nothing;
