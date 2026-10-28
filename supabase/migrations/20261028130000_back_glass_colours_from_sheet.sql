-- Redo back glass colours to match the owner's 后玻璃 sheet: the same 11
-- colour columns (labelled English + Chinese) and which models come in which
-- colour, plus the iPhone 17 range. The rows from
-- 20261028120000_add_iphone_back_glass_inventory were never counted or used,
-- so untouched ones are removed first.
delete from public.lcd_inventory_items items
where items.variant_name like 'Back Glass %'
  and items.current_qty = 0
  and not exists (select 1 from public.daily_report_lcd_lines l where l.lcd_inventory_item_id = items.id)
  and not exists (select 1 from public.lcd_inventory_count_lines l where l.lcd_inventory_item_id = items.id);

with colour(code, label, sort_order) as (
  values
    ('black',  'Black 黑',  1),
    ('white',  'White 白',  2),
    ('red',    'Red 红',    3),
    ('green',  'Green 绿',  4),
    ('blue',   'Blue 蓝',   5),
    ('purple', 'Purple 紫', 6),
    ('gold',   'Gold 金',   7),
    ('orange', 'Orange 橙', 8),
    ('yellow', 'Yellow 黄', 9),
    ('pink',   'Pink 粉',   10),
    ('grey',   'Grey 灰',   11)
),
-- Every model has black and white; the arrays list the extra colours.
spec(model_name, extra_colours) as (
  values
    ('iPhone 8',          array['red', 'gold']),
    ('iPhone 8 plus',     array['red', 'gold']),
    ('iPhone SE2',        array['red']),
    ('iPhone X',          array[]::text[]),
    ('iPhone XS',         array['gold']),
    ('iPhone Xs Max',     array['gold']),
    ('iPhone XR',         array['red', 'blue', 'orange', 'yellow']),
    ('Iphone 11',         array['red', 'green', 'purple', 'yellow']),
    ('Iphone 11 Pro',     array['green', 'gold']),
    ('Iphone 11 Pro Max', array['green', 'gold']),
    ('Iphone 12',         array['red', 'green', 'blue', 'purple']),
    ('Iphone 12 Pro',     array['blue', 'gold']),
    ('Iphone 12 Pro Max', array['blue', 'gold']),
    ('Iphone 12 Mini',    array['red', 'green', 'blue', 'purple']),
    ('Iphone 13 Mini',    array['red', 'blue', 'pink']),
    ('Iphone 13',         array['red', 'green', 'blue', 'pink']),
    ('Iphone 13 Pro',     array['green', 'blue', 'gold']),
    ('Iphone 13 Pro Max', array['green', 'blue', 'gold']),
    ('iPhone 14',         array['red', 'blue', 'purple', 'yellow']),
    ('iPhone 14 Pro',     array['purple', 'gold']),
    ('iPhone 14 Plus',    array['red', 'blue', 'purple', 'yellow']),
    ('iPhone 14 Pro Max', array['purple', 'gold']),
    ('iPhone 15',         array['green', 'blue', 'yellow', 'pink']),
    ('iPhone 15 Plus',    array['green', 'blue', 'yellow', 'pink']),
    ('iPhone 15 Pro',     array['blue', 'grey']),
    ('iPhone 15 Pro Max', array['blue', 'grey']),
    ('iPhone 16',         array['green', 'purple', 'pink']),
    ('iPhone 16 Plus',    array['green', 'purple', 'pink']),
    ('iPhone 16 Pro',     array['gold', 'grey']),
    ('iPhone 16 Pro Max', array['gold', 'grey']),
    ('iPhone 17',         array['green', 'purple', 'pink']),
    ('iPhone 17 Air',     array['green', 'purple', 'pink']),
    ('iPhone 17 Pro',     array['gold', 'grey']),
    ('iPhone 17 Pro Max', array['gold', 'grey'])
),
stores as (
  select id from public.store_locations
  where store_code in ('warehouse', 'parkridge', 'fairfield', 'northlakes', 'toowong')
),
resolved as (
  -- Reuse each store's existing spelling of the model so glass sits with its screens.
  select
    stores.id as store_id,
    coalesce(
      (select items.model_name
         from public.lcd_inventory_items items
        where items.store_id = stores.id
          and lower(items.model_name) = lower(spec.model_name)
        limit 1),
      spec.model_name
    ) as model_name,
    array['black', 'white'] || spec.extra_colours as colours
  from stores
  cross join spec
)
insert into public.lcd_inventory_items (store_id, model_name, variant_name, category_key, current_qty, active)
select resolved.store_id, resolved.model_name, 'Back Glass ' || colour.label, 'iphone', 0, true
from resolved
join colour on colour.code = any(resolved.colours)
on conflict (store_id, model_name, variant_name) do nothing;
