-- Four photo-identified additions. Existing DVD-RW SKU 1010943 is retained.
-- Source: RepairDesk exports products (18), (19), (21).xlsx.
-- RP-W70 cost and USB/VGA pricing confirmed by the owner on 2026-09-09.
begin;
with incoming(sku,slug,name,brand,model,cost,retail,upc,external_id,category,pos_main,pos_sub,image,metadata) as (values
('109081522','dudao-v101-128gb-usb-c-flash-drive','DUDAO V101 128GB USB 3.2 + Type-C Flash Drive','DUDAO','V101',13::numeric,42::numeric,'6976625334636','10908','gaming-essentials','Computer & Gaming','Storage','dudao-v101-128gb.jpeg','{"source_file":"products (18).xlsx","source_row":125,"original_sku":"109081522","warranty_months":6}'::jsonb),
('TM8-WALL-9551','45w-dual-type-c-fast-wall-charger-9551','45W Dual Type C Fast Wall Charger','Generic','45W Dual Type-C',5,39,null,'9551','wall-chargers','Charging & Power','Wall Chargers','45w-dual-usbc.png','{"source_file":"products (19).xlsx","source_row":195,"original_sku":"425222609228","sku_note":"Original SKU is assigned to a distinct 30W charger in the current system","warranty_months":6}'::jsonb),
('6954851202745','remax-rp-w70-3-in-1-wireless-charger','REMAX RP-W70 22W 3-in-1 Foldable Wireless Charger','REMAX','RP-W70',15,99,null,'7383','wireless-charger','Charging & Power','Wireless Chargers','remax-rp-w70.jpeg','{"source_file":"products (21).xlsx","source_row":304,"original_sku":"6954851202745","source_cost":0,"cost_source":"Owner confirmed 15 AUD on 2026-09-09","warranty_months":6}'::jsonb),
('TM8-USB-VGA','usb-to-vga-display-adapter','USB to VGA Display Adapter','Generic',null,5,29,null,null,'cable','Cables & Adapters','Display & Computer Cables','usb-vga.jpeg','{"price_source":"Owner confirmed retail 29 AUD and cost 5 AUD on 2026-09-09","identification_source":"User product photo","legacy_match":"Not found"}'::jsonb)
)
insert into public.products(sku,slug,name,brand,model,cost_price,retail_price,upc,source_external_id,category_id,pos_category_id,image_url,source_system,source_metadata,is_visible,is_pos_visible,import_status,condition_label,stock_quantity)
select i.sku,i.slug,i.name,i.brand,i.model,i.cost,i.retail,i.upc,i.external_id,c.id,t.id,
'https://oztechm8.com.au/assets/products/20260909/'||i.image,'photo_catalog_20260909',i.metadata,false,true,'active','Brand New',0
from incoming i join public.categories c on c.slug=i.category
join public.pos_category_taxonomy t on t.category_name=i.pos_main and t.subcategory_name=i.pos_sub
where not exists (select 1 from public.products p where p.sku=i.sku or (i.external_id is not null and p.source_external_id=i.external_id))
returning id,sku,name,cost_price,retail_price;
commit;
