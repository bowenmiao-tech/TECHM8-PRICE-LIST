-- Track iPhone back glass in parts inventory, one row per colour, so stores
-- count it in the weekly stocktake and the stock overview page can total it.
-- Rows start at 0; the next weekly count fills in real quantities.
with spec(model_name, colours) as (
  values
    ('iPhone 8',          array['Black', 'Silver', 'Gold', 'Red']),
    ('iPhone 8 plus',     array['Black', 'Silver', 'Gold', 'Red']),
    ('iPhone SE2',        array['Black', 'White', 'Red']),
    ('iPhone X',          array['Black', 'Silver']),
    ('iPhone XS',         array['Black', 'Silver', 'Gold']),
    ('iPhone Xs Max',     array['Black', 'Silver', 'Gold']),
    ('iPhone XR',         array['Black', 'White', 'Red', 'Yellow', 'Blue', 'Coral']),
    ('Iphone 11',         array['Black', 'White', 'Red', 'Yellow', 'Purple', 'Green']),
    ('Iphone 11 Pro',     array['Black', 'Silver', 'Gold', 'Green']),
    ('Iphone 11 Pro Max', array['Black', 'Silver', 'Gold', 'Green']),
    ('Iphone 12 Mini',    array['Black', 'White', 'Red', 'Blue', 'Green', 'Purple']),
    ('Iphone 12',         array['Black', 'White', 'Red', 'Blue', 'Green', 'Purple']),
    ('Iphone 12 Pro',     array['Graphite', 'Silver', 'Gold', 'Blue']),
    ('Iphone 12 Pro Max', array['Graphite', 'Silver', 'Gold', 'Blue']),
    ('Iphone 13 Mini',    array['Black', 'White', 'Red', 'Blue', 'Pink', 'Green']),
    ('Iphone 13',         array['Black', 'White', 'Red', 'Blue', 'Pink', 'Green']),
    ('Iphone 13 Pro',     array['Graphite', 'Silver', 'Gold', 'Blue', 'Green']),
    ('Iphone 13 Pro Max', array['Graphite', 'Silver', 'Gold', 'Blue', 'Green']),
    ('iPhone 14',         array['Black', 'White', 'Red', 'Blue', 'Purple', 'Yellow']),
    ('iPhone 14 Plus',    array['Black', 'White', 'Red', 'Blue', 'Purple', 'Yellow']),
    ('iPhone 14 Pro',     array['Black', 'Silver', 'Gold', 'Purple']),
    ('iPhone 14 Pro Max', array['Black', 'Silver', 'Gold', 'Purple']),
    ('iPhone 15',         array['Black', 'Blue', 'Green', 'Yellow', 'Pink']),
    ('iPhone 15 Plus',    array['Black', 'Blue', 'Green', 'Yellow', 'Pink']),
    ('iPhone 15 Pro',     array['Black', 'White', 'Blue', 'Natural']),
    ('iPhone 15 Pro Max', array['Black', 'White', 'Blue', 'Natural']),
    ('iPhone 16',         array['Black', 'White', 'Pink', 'Teal', 'Ultramarine']),
    ('iPhone 16 Plus',    array['Black', 'White', 'Pink', 'Teal', 'Ultramarine']),
    ('iPhone 16 Pro',     array['Black', 'White', 'Natural', 'Desert']),
    ('iPhone 16 Pro Max', array['Black', 'White', 'Natural', 'Desert'])
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
    spec.colours
  from stores
  cross join spec
)
insert into public.lcd_inventory_items (store_id, model_name, variant_name, category_key, current_qty, active)
select resolved.store_id, resolved.model_name, 'Back Glass ' || colour, 'iphone', 0, true
from resolved
cross join lateral unnest(resolved.colours) as colour
on conflict (store_id, model_name, variant_name) do nothing;
