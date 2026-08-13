begin;

insert into public.pos_category_taxonomy (
  category_name, subcategory_name, category_sort, subcategory_sort, active
)
values ('Uncategorized', 'Uncategorized', 110, 10, true)
on conflict (category_name, subcategory_name) do update
set category_sort = excluded.category_sort,
    subcategory_sort = excluded.subcategory_sort,
    active = true,
    updated_at = now();

create temporary table misc_accessory_group_input on commit drop as
select *
from jsonb_to_recordset($groups$[{"code":"TM8-GRP-MISC-MAGSAFE-SILICONE-GRIP","slug":"tm8-grp-misc-magsafe-silicone-grip","name":"MagSafe Silicone Phone Grip","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","product_family":"phone_accessory","main_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.95072500%201763529951.jpg"},{"code":"TM8-GRP-MISC-MAGSAFE-MULTI-WALLET","slug":"tm8-grp-misc-magsafe-multi-wallet","name":"MagSafe Multi-Wallet","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","product_family":"phone_accessory","main_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.67864700%201763529791.jpg"},{"code":"TM8-GRP-MISC-MAGSAFE-CARD-WALLET","slug":"tm8-grp-misc-magsafe-card-wallet","name":"MagSafe Card Wallet","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","product_family":"phone_accessory","main_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1681523094.jpg"},{"code":"TM8-GRP-MISC-ADHESIVE-CARD-HOLDER","slug":"tm8-grp-misc-adhesive-card-holder","name":"Adhesive Silicone Card Holder","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","product_family":"phone_accessory","main_image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663820866.jpg"}]$groups$::jsonb) as x(
  code text,
  slug text,
  name text,
  database_category_slug text,
  pos_main_category text,
  pos_subcategory text,
  product_family text,
  main_image_url text
);

create temporary table misc_accessory_product_input on commit drop as
select *
from jsonb_to_recordset($catalog$[{"sku":"108881499","slug":"repairdesk-misc-10888-magsafe-stand-wallet-black","name":"MagSafe Stand Wallet - Black","brand":"OZTECHM8","model":null,"database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":3,"retail_price":35,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.49269900%201764811438.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000108885","product_group_code":null,"variant_name":"Black","variant_color":"Black","source_system":"repairdesk_misc_accessories","source_external_id":"10888","source_category_path":"Card Holder & Pop Scoket > Magsafe Card Holder","import_status":"active","source_metadata":{"original_name":"Magsafe Card Holder Stand-Wallet Black","original_sku":"108881499","original_upc":"77","source_stock":1,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":3,"owner_confirmed_retail":35,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"108571484","slug":"repairdesk-misc-10857-magsafe-silicone-phone-grip-purple","name":"MagSafe Silicone Phone Grip - Purple","brand":"OZTECHM8","model":"MagSafe Silicone Phone Grip","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":2,"retail_price":29,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.07349000%201763530125.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000108571","product_group_code":"TM8-GRP-MISC-MAGSAFE-SILICONE-GRIP","variant_name":"Purple","variant_color":"Purple","source_system":"repairdesk_misc_accessories","source_external_id":"10857","source_category_path":"Card Holder & Pop Scoket > Magsafe Pop Scoket","import_status":"active","source_metadata":{"original_name":"Magsafe Silicone Phone Holder Purple","original_sku":"108571484","original_upc":"77","source_stock":2,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":2,"owner_confirmed_retail":29,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"108561483","slug":"repairdesk-misc-10856-magsafe-silicone-phone-grip-pink","name":"MagSafe Silicone Phone Grip - Pink","brand":"OZTECHM8","model":"MagSafe Silicone Phone Grip","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":2,"retail_price":29,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.79588200%201763530092.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000108564","product_group_code":"TM8-GRP-MISC-MAGSAFE-SILICONE-GRIP","variant_name":"Pink","variant_color":"Pink","source_system":"repairdesk_misc_accessories","source_external_id":"10856","source_category_path":"Card Holder & Pop Scoket > Magsafe Pop Scoket","import_status":"active","source_metadata":{"original_name":"Magsafe Silicone Phone Holder Pink","original_sku":"108561483","original_upc":"77","source_stock":4,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":2,"owner_confirmed_retail":29,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"108551482","slug":"repairdesk-misc-10855-magsafe-silicone-phone-grip-sky-blue","name":"MagSafe Silicone Phone Grip - Sky Blue","brand":"OZTECHM8","model":"MagSafe Silicone Phone Grip","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":2,"retail_price":29,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.39449400%201763530053.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000108557","product_group_code":"TM8-GRP-MISC-MAGSAFE-SILICONE-GRIP","variant_name":"Sky Blue","variant_color":"Sky Blue","source_system":"repairdesk_misc_accessories","source_external_id":"10855","source_category_path":"Card Holder & Pop Scoket > Magsafe Pop Scoket","import_status":"active","source_metadata":{"original_name":"Magsafe Silicone Phone Holder Sky Blue","original_sku":"108551482","original_upc":"77","source_stock":4,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":2,"owner_confirmed_retail":29,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"108541481","slug":"repairdesk-misc-10854-magsafe-silicone-phone-grip-black","name":"MagSafe Silicone Phone Grip - Black","brand":"OZTECHM8","model":"MagSafe Silicone Phone Grip","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":2,"retail_price":29,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.95072500%201763529951.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000108540","product_group_code":"TM8-GRP-MISC-MAGSAFE-SILICONE-GRIP","variant_name":"Black","variant_color":"Black","source_system":"repairdesk_misc_accessories","source_external_id":"10854","source_category_path":"Card Holder & Pop Scoket > Magsafe Pop Scoket","import_status":"active","source_metadata":{"original_name":"Magsafe Silicone Phone Holder Black","original_sku":"108541481","original_upc":"77","source_stock":1,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":2,"owner_confirmed_retail":29,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"108531480","slug":"repairdesk-misc-10853-magsafe-multi-wallet-brown","name":"MagSafe Multi-Wallet - Brown","brand":"OZTECHM8","model":"MagSafe Multi-Wallet","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":3,"retail_price":35,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.81691900%201763529824.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000108533","product_group_code":"TM8-GRP-MISC-MAGSAFE-MULTI-WALLET","variant_name":"Brown","variant_color":"Brown","source_system":"repairdesk_misc_accessories","source_external_id":"10853","source_category_path":"Card Holder & Pop Scoket > Magsafe Card Holder","import_status":"active","source_metadata":{"original_name":"Magsafe Card Holder Muti-Wallet Brown","original_sku":"108531480","original_upc":"77","source_stock":4,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":3,"owner_confirmed_retail":35,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"108521479","slug":"repairdesk-misc-10852-magsafe-multi-wallet-black","name":"MagSafe Multi-Wallet - Black","brand":"OZTECHM8","model":"MagSafe Multi-Wallet","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":3,"retail_price":35,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.67864700%201763529791.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000108526","product_group_code":"TM8-GRP-MISC-MAGSAFE-MULTI-WALLET","variant_name":"Black","variant_color":"Black","source_system":"repairdesk_misc_accessories","source_external_id":"10852","source_category_path":"Card Holder & Pop Scoket > Magsafe Card Holder","import_status":"active","source_metadata":{"original_name":"Magsafe Card Holder Muti-Wallet Black","original_sku":"108521479","original_upc":"77","source_stock":1,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":3,"owner_confirmed_retail":35,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"108511478","slug":"repairdesk-misc-10851-magsafe-multi-wallet-grey","name":"MagSafe Multi-Wallet - Grey","brand":"OZTECHM8","model":"MagSafe Multi-Wallet","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":3,"retail_price":35,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.95980500%201763529726.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000108519","product_group_code":"TM8-GRP-MISC-MAGSAFE-MULTI-WALLET","variant_name":"Grey","variant_color":"Grey","source_system":"repairdesk_misc_accessories","source_external_id":"10851","source_category_path":"Card Holder & Pop Scoket > Magsafe Card Holder","import_status":"active","source_metadata":{"original_name":"Magsafe Card Holder Muti-Wallet Gray","original_sku":"108511478","original_upc":"77","source_stock":3,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":3,"owner_confirmed_retail":35,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"TM8-MISC-10322","slug":"repairdesk-misc-10322-ctf-earbuds-pouch","name":"CTF Earbuds Pouch","brand":"CTF","model":null,"database_category_slug":"accessories","pos_main_category":"Other Electronics","pos_subcategory":"Earbud Cases","short_description":"Earbud Cases","condition_label":"Brand New","compatibility":null,"cost_price":5,"retail_price":32.99,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/0.11040200%201748142764.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000103224","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"10322","source_category_path":"Card Holder & Pop Scoket","import_status":"active","source_metadata":{"original_name":"CTF EARBUDS POUCH","original_sku":"1032168","original_upc":"77","source_stock":4,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":5,"owner_confirmed_retail":32.99,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Other Electronics","pos_subcategory":"Earbud Cases"}},{"sku":"TM8-MISC-10321","slug":"repairdesk-misc-10321-ctf-car-holder-grip-magsafe-stand","name":"CTF Car Holder & Grip MagSafe Stand","brand":"CTF","model":null,"database_category_slug":"accessories","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized","short_description":"Uncategorized","condition_label":"Brand New","compatibility":null,"cost_price":10,"retail_price":32.99,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1748142475640pxCasetifylogo.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000103217","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"10321","source_category_path":"Card Holder & Pop Scoket","import_status":"active","source_metadata":{"original_name":"CTF CARHOLDER & GRIP MAGSAFE STAND","original_sku":"1032168","original_upc":"77","source_stock":9,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":10,"owner_confirmed_retail":32.99,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized"}},{"sku":"8974626","slug":"repairdesk-misc-8974-card-strap-holder","name":"Card Strap Holder","brand":"OZTECHM8","model":null,"database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":1,"retail_price":15,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1705559061.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000089740","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"8974","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"Card Strap Holder","original_sku":"8974626","original_upc":"77","source_stock":3,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":1,"owner_confirmed_retail":15,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"8633797","slug":"repairdesk-misc-8633-techm8-small-bag","name":"TechM8 Small Bag","brand":"TechM8","model":null,"database_category_slug":"accessories","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized","short_description":"Uncategorized","condition_label":"Brand New","compatibility":null,"cost_price":1,"retail_price":0,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1694762449.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000086336","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"8633","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"Techm8 Small Bag","original_sku":"8633797","original_upc":"77","source_stock":943,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":1,"owner_confirmed_retail":0,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized"}},{"sku":"8632796","slug":"repairdesk-misc-8632-techm8-big-bag","name":"TechM8 Big Bag","brand":"TechM8","model":null,"database_category_slug":"accessories","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized","short_description":"Uncategorized","condition_label":"Brand New","compatibility":null,"cost_price":1,"retail_price":0,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1694762375.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000086329","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"8632","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"Techm8 Big Bag","original_sku":"8632796","original_upc":"77","source_stock":452,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":1,"owner_confirmed_retail":0,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized"}},{"sku":"8483784","slug":"repairdesk-misc-8483-drone-map","name":"Drone Map","brand":"OZTECHM8","model":null,"database_category_slug":"accessories","pos_main_category":"Other Electronics","pos_subcategory":"Drones & Accessories","short_description":"Drones & Accessories","condition_label":"Brand New","compatibility":null,"cost_price":5,"retail_price":25,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1691125302.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000084837","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"8483","source_category_path":"Drone","import_status":"active","source_metadata":{"original_name":"Drone Map","original_sku":"8483784","original_upc":"77","source_stock":3,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":5,"owner_confirmed_retail":25,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Other Electronics","pos_subcategory":"Drones & Accessories"}},{"sku":"8416553","slug":"repairdesk-misc-8416-special-order","name":"Special Order","brand":"OZTECHM8","model":null,"database_category_slug":"accessories","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized","short_description":"Uncategorized","condition_label":"Brand New","compatibility":null,"cost_price":0,"retail_price":0,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/168921082742458135.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000084165","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"8416","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"Special Order","original_sku":"8416553","original_upc":"77","source_stock":9949,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":0,"owner_confirmed_retail":0,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized"}},{"sku":"8412763","slug":"repairdesk-misc-8412-phone-strap-adapter-patch","name":"Phone Strap Adapter Patch","brand":"OZTECHM8","model":null,"database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":0.5,"retail_price":1,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/168871018042458131.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000084127","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"8412","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"Phone Strap Gasket","original_sku":"8412763","original_upc":"77","source_stock":106,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":0.5,"owner_confirmed_retail":1,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"8411762","slug":"repairdesk-misc-8411-phone-lanyard-strap","name":"Phone Lanyard Strap","brand":"OZTECHM8","model":null,"database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":3,"retail_price":15,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1688703436.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000084110","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"8411","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"Phone Strap","original_sku":"8411762","original_upc":"77","source_stock":3,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":3,"owner_confirmed_retail":15,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"8263681","slug":"repairdesk-misc-8263-fimi-x8-mini-v2-drone","name":"FIMI X8 Mini V2 Drone","brand":"FIMI","model":null,"database_category_slug":"accessories","pos_main_category":"Other Electronics","pos_subcategory":"Drones & Accessories","short_description":"Drones & Accessories","condition_label":"Brand New","compatibility":null,"cost_price":550,"retail_price":599,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1684714683.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000082635","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"8263","source_category_path":"Drone","import_status":"active","source_metadata":{"original_name":"FIMI X8 MINI V2","original_sku":"8263681","original_upc":"77","source_stock":2,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":550,"owner_confirmed_retail":599,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Other Electronics","pos_subcategory":"Drones & Accessories"}},{"sku":"8041585","slug":"repairdesk-misc-8041-magsafe-card-wallet-navy","name":"MagSafe Card Wallet - Navy","brand":"OZTECHM8","model":"MagSafe Card Wallet","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":10,"retail_price":39.95,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1681523094.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000080419","product_group_code":"TM8-GRP-MISC-MAGSAFE-CARD-WALLET","variant_name":"Navy","variant_color":"Navy","source_system":"repairdesk_misc_accessories","source_external_id":"8041","source_category_path":"Card Holder & Pop Scoket > Magsafe Card Holder","import_status":"active","source_metadata":{"original_name":"Magsafe Card Holder Navy","original_sku":"8041585","original_upc":"77","source_stock":1,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":10,"owner_confirmed_retail":39.95,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"8040584","slug":"repairdesk-misc-8040-magsafe-card-wallet-orange","name":"MagSafe Card Wallet - Orange","brand":"OZTECHM8","model":"MagSafe Card Wallet","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":10,"retail_price":39.95,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1681523051.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000080402","product_group_code":"TM8-GRP-MISC-MAGSAFE-CARD-WALLET","variant_name":"Orange","variant_color":"Orange","source_system":"repairdesk_misc_accessories","source_external_id":"8040","source_category_path":"Card Holder & Pop Scoket > Magsafe Card Holder","import_status":"active","source_metadata":{"original_name":"Magsafe Card Holder Orange","original_sku":"8040584","original_upc":"77","source_stock":2,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":10,"owner_confirmed_retail":39.95,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"8039583","slug":"repairdesk-misc-8039-magsafe-card-wallet-red","name":"MagSafe Card Wallet - Red","brand":"OZTECHM8","model":"MagSafe Card Wallet","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":10,"retail_price":39.95,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1681522979.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000080396","product_group_code":"TM8-GRP-MISC-MAGSAFE-CARD-WALLET","variant_name":"Red","variant_color":"Red","source_system":"repairdesk_misc_accessories","source_external_id":"8039","source_category_path":"Card Holder & Pop Scoket > Magsafe Card Holder","import_status":"active","source_metadata":{"original_name":"Magsafe Card Holder Red","original_sku":"8039583","original_upc":"77","source_stock":2,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":10,"owner_confirmed_retail":39.95,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"8038582","slug":"repairdesk-misc-8038-magsafe-card-wallet-green","name":"MagSafe Card Wallet - Green","brand":"OZTECHM8","model":"MagSafe Card Wallet","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":10,"retail_price":39.95,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1681522813.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000080389","product_group_code":"TM8-GRP-MISC-MAGSAFE-CARD-WALLET","variant_name":"Green","variant_color":"Green","source_system":"repairdesk_misc_accessories","source_external_id":"8038","source_category_path":"Card Holder & Pop Scoket > Magsafe Card Holder","import_status":"active","source_metadata":{"original_name":"Magsafe Card Holder Green","original_sku":"8038582","original_upc":"77","source_stock":2,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":10,"owner_confirmed_retail":39.95,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"8036580","slug":"repairdesk-misc-8036-magsafe-card-wallet-brown","name":"MagSafe Card Wallet - Brown","brand":"OZTECHM8","model":"MagSafe Card Wallet","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":10,"retail_price":39.95,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1681522658.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000080365","product_group_code":"TM8-GRP-MISC-MAGSAFE-CARD-WALLET","variant_name":"Brown","variant_color":"Brown","source_system":"repairdesk_misc_accessories","source_external_id":"8036","source_category_path":"Card Holder & Pop Scoket > Magsafe Card Holder","import_status":"active","source_metadata":{"original_name":"Magsafe Card Holder Brown","original_sku":"8036580","original_upc":"77","source_stock":2,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":10,"owner_confirmed_retail":39.95,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"776330","slug":"repairdesk-misc-7763-phone-tag","name":"Phone Tag","brand":"OZTECHM8","model":null,"database_category_slug":"accessories","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized","short_description":"Uncategorized","condition_label":"Brand New","compatibility":null,"cost_price":2,"retail_price":5,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/168871032742457480.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000077631","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"7763","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"Phone tag","original_sku":"776330","original_upc":"77","source_stock":80,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":2,"owner_confirmed_retail":5,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized"}},{"sku":"7148331","slug":"repairdesk-misc-7148-adhesive-silicone-card-holder-black","name":"Adhesive Silicone Card Holder - Black","brand":"OZTECHM8","model":"Adhesive Silicone Card Holder","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":2,"retail_price":10,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663820866.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000071486","product_group_code":"TM8-GRP-MISC-ADHESIVE-CARD-HOLDER","variant_name":"Black","variant_color":"Black","source_system":"repairdesk_misc_accessories","source_external_id":"7148","source_category_path":"Card Holder & Pop Scoket > Sticker Card Holder","import_status":"active","source_metadata":{"original_name":"Silicone Card Holder Black","original_sku":"7148331","original_upc":"77","source_stock":17,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":2,"owner_confirmed_retail":10,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"7147330","slug":"repairdesk-misc-7147-adhesive-silicone-card-holder-green","name":"Adhesive Silicone Card Holder - Green","brand":"OZTECHM8","model":"Adhesive Silicone Card Holder","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":2,"retail_price":10,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663820813.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000071479","product_group_code":"TM8-GRP-MISC-ADHESIVE-CARD-HOLDER","variant_name":"Green","variant_color":"Green","source_system":"repairdesk_misc_accessories","source_external_id":"7147","source_category_path":"Card Holder & Pop Scoket > Sticker Card Holder","import_status":"active","source_metadata":{"original_name":"Silicone Card Holder Green","original_sku":"7147330","original_upc":"77","source_stock":4,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":2,"owner_confirmed_retail":10,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"7146329","slug":"repairdesk-misc-7146-adhesive-silicone-card-holder-yellow","name":"Adhesive Silicone Card Holder - Yellow","brand":"OZTECHM8","model":"Adhesive Silicone Card Holder","database_category_slug":"holder-car-play-charger","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips","short_description":"Wallets, Card Holders & Grips","condition_label":"Brand New","compatibility":null,"cost_price":2,"retail_price":10,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1663820750.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000071462","product_group_code":"TM8-GRP-MISC-ADHESIVE-CARD-HOLDER","variant_name":"Yellow","variant_color":"Yellow","source_system":"repairdesk_misc_accessories","source_external_id":"7146","source_category_path":"Card Holder & Pop Scoket > Sticker Card Holder","import_status":"active","source_metadata":{"original_name":"Silicone Card Holder Yellow","original_sku":"7146329","original_upc":"77","source_stock":6,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":2,"owner_confirmed_retail":10,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Mounts & Holders","pos_subcategory":"Wallets, Card Holders & Grips"}},{"sku":"676992","slug":"repairdesk-misc-6769-shop-credit","name":"Shop Credit","brand":"OZTECHM8","model":null,"database_category_slug":"accessories","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized","short_description":"Uncategorized","condition_label":"Brand New","compatibility":null,"cost_price":0,"retail_price":0,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/168921107742456481.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000067694","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"6769","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"Shop Credit","original_sku":"676992","original_upc":"77","source_stock":982,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":0,"owner_confirmed_retail":0,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized"}},{"sku":"606257","slug":"repairdesk-misc-6062-rgb-digital-clock","name":"RGB Digital Clock","brand":"OZTECHM8","model":null,"database_category_slug":"accessories","pos_main_category":"Other Electronics","pos_subcategory":"Lighting & Clocks","short_description":"Lighting & Clocks","condition_label":"Brand New","compatibility":null,"cost_price":100,"retail_price":179,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1636603808.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000060626","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"6062","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"RGB Digital Clock","original_sku":"606257","original_upc":"77","source_stock":1,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":100,"owner_confirmed_retail":179,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Other Electronics","pos_subcategory":"Lighting & Clocks"}},{"sku":"606156","slug":"repairdesk-misc-6061-music-reactive-rgb-light","name":"Music-Reactive RGB Light","brand":"OZTECHM8","model":null,"database_category_slug":"accessories","pos_main_category":"Other Electronics","pos_subcategory":"Lighting & Clocks","short_description":"Lighting & Clocks","condition_label":"Brand New","compatibility":null,"cost_price":40,"retail_price":79,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1636603500.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000060619","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"6061","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"Music Reactive RGB Light","original_sku":"606156","original_upc":"77","source_stock":2,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":40,"owner_confirmed_retail":79,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Other Electronics","pos_subcategory":"Lighting & Clocks"}},{"sku":"TM8-MISC-6021","slug":"repairdesk-misc-6021-special","name":"Special","brand":"OZTECHM8","model":null,"database_category_slug":"accessories","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized","short_description":"Uncategorized","condition_label":"Brand New","compatibility":null,"cost_price":1,"retail_price":5,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1630905457.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000060213","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"6021","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"Special","original_sku":"595728","original_upc":"77","source_stock":775,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":1,"owner_confirmed_retail":5,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized"}},{"sku":"597334","slug":"repairdesk-misc-5995-paragon-stylus-pen","name":"Paragon Stylus Pen","brand":"Paragon","model":null,"database_category_slug":"accessories","pos_main_category":"Other Electronics","pos_subcategory":"Other Electronics","short_description":"Other Electronics","condition_label":"Brand New","compatibility":null,"cost_price":2,"retail_price":10,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/1628060986.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000059958","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"5995","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"Stylus Paragon Pen","original_sku":"597334","original_upc":"77","source_stock":30,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":2,"owner_confirmed_retail":10,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Other Electronics","pos_subcategory":"Other Electronics"}},{"sku":"TM8-MISC-5957","slug":"repairdesk-misc-5957-miscellaneous-other-products","name":"Miscellaneous & Other Products","brand":"OZTECHM8","model":null,"database_category_slug":"accessories","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized","short_description":"Uncategorized","condition_label":"Brand New","compatibility":null,"cost_price":0,"retail_price":0,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/162626207742455667.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000059576","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"5957","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"MIS & Other Products","original_sku":"595728","original_upc":"77","source_stock":611,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":0,"owner_confirmed_retail":0,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Uncategorized","pos_subcategory":"Uncategorized"}},{"sku":"593419","slug":"repairdesk-misc-5934-2-sim","name":"$2 SIM","brand":"OZTECHM8","model":null,"database_category_slug":"accessories","pos_main_category":"Other Electronics","pos_subcategory":"Other Electronics","short_description":"Other Electronics","condition_label":"Brand New","compatibility":null,"cost_price":0,"retail_price":2,"image_url":"https://dghyt15qon7us.cloudfront.net/images/productTheme/Inventory/small/162626215842348592.jpg","stock_quantity":0,"is_visible":false,"is_pos_visible":true,"upc":"2996000059347","product_group_code":null,"variant_name":null,"variant_color":null,"source_system":"repairdesk_misc_accessories","source_external_id":"5934","source_category_path":"Uncategorized","import_status":"active","source_metadata":{"original_name":"$2 SIM","original_sku":"593419","original_upc":"77","source_stock":869,"proposed_stock":0,"inventory_assignment":"none","owner_confirmed_cost":0,"owner_confirmed_retail":2,"owner_confirmed_at":"2026-08-14","image_source":"repairdesk_pos","pos_main_category":"Other Electronics","pos_subcategory":"Other Electronics"}}]$catalog$::jsonb) as x(
  sku text,
  slug text,
  name text,
  brand text,
  model text,
  database_category_slug text,
  pos_main_category text,
  pos_subcategory text,
  short_description text,
  condition_label text,
  compatibility text,
  cost_price numeric,
  retail_price numeric,
  image_url text,
  stock_quantity integer,
  is_visible boolean,
  is_pos_visible boolean,
  upc text,
  product_group_code text,
  variant_name text,
  variant_color text,
  source_system text,
  source_external_id text,
  source_category_path text,
  import_status text,
  source_metadata jsonb
);

do $$
begin
  if (select count(*) from misc_accessory_product_input) <> 34 then
    raise exception 'Expected 34 miscellaneous accessory products.';
  end if;

  if (select count(*) from misc_accessory_group_input) <> 4 then
    raise exception 'Expected four grouped accessory styles.';
  end if;

  if exists (
    select 1
    from misc_accessory_product_input input
    left join public.categories category on category.slug = input.database_category_slug
    left join public.pos_category_taxonomy taxonomy
      on taxonomy.category_name = input.pos_main_category
     and taxonomy.subcategory_name = input.pos_subcategory
     and taxonomy.active
    where category.id is null or taxonomy.id is null
  ) then
    raise exception 'An import product references a missing category.';
  end if;

  if exists (
    select 1 from misc_accessory_product_input input
    where input.cost_price < 0
       or input.retail_price < 0
       or input.stock_quantity <> 0
       or input.is_visible
       or not input.is_pos_visible
       or coalesce(btrim(input.image_url), '') = ''
  ) then
    raise exception 'An import product has an invalid price, stock, visibility, or image.';
  end if;

  if exists (
    select 1 from misc_accessory_product_input input
    where input.cost_price = 0
      and input.source_external_id not in ('8416', '6769', '5957', '5934')
  ) or exists (
    select 1 from misc_accessory_product_input input
    where input.retail_price = 0
      and input.source_external_id not in ('8633', '8632', '8416', '6769', '5957')
  ) then
    raise exception 'Unexpected zero price found in import products.';
  end if;

  if exists (
    select input.sku from misc_accessory_product_input input group by input.sku having count(*) > 1
  ) or exists (
    select input.upc from misc_accessory_product_input input group by input.upc having count(*) > 1
  ) or exists (
    select input.source_external_id
    from misc_accessory_product_input input
    group by input.source_system, input.source_external_id
    having count(*) > 1
  ) then
    raise exception 'The import contains a duplicate SKU, barcode, or source item.';
  end if;

  if exists (
    select 1
    from misc_accessory_product_input input
    join public.products existing on existing.sku = input.sku
    where existing.source_system is distinct from input.source_system
       or existing.source_external_id is distinct from input.source_external_id
  ) or exists (
    select 1
    from misc_accessory_product_input input
    join public.products existing on existing.upc = input.upc
    where existing.source_system is distinct from input.source_system
       or existing.source_external_id is distinct from input.source_external_id
  ) then
    raise exception 'An import SKU or barcode is owned by another product.';
  end if;

  if exists (
    select 1
    from misc_accessory_product_input input
    join public.products existing
      on existing.source_system = input.source_system
     and existing.source_external_id = input.source_external_id
    where existing.sku <> input.sku
  ) then
    raise exception 'An import source item already has another SKU.';
  end if;
end
$$;

insert into public.product_groups (
  code, slug, name, category_id, product_family, main_image_url,
  status, is_pos_visible, is_visible, pos_category_id
)
select
  input.code,
  input.slug,
  input.name,
  category.id,
  input.product_family,
  input.main_image_url,
  'active',
  true,
  false,
  taxonomy.id
from misc_accessory_group_input input
join public.categories category on category.slug = input.database_category_slug
join public.pos_category_taxonomy taxonomy
  on taxonomy.category_name = input.pos_main_category
 and taxonomy.subcategory_name = input.pos_subcategory
 and taxonomy.active
on conflict (code) do update
set slug = excluded.slug,
    name = excluded.name,
    category_id = excluded.category_id,
    product_family = excluded.product_family,
    main_image_url = excluded.main_image_url,
    status = 'active',
    is_pos_visible = true,
    is_visible = false,
    pos_category_id = excluded.pos_category_id,
    updated_at = timezone('utc'::text, now())
where public.product_groups.product_family = 'phone_accessory';

insert into public.products (
  sku, slug, name, brand, model, category_id, pos_category_id,
  short_description, condition_label, compatibility,
  cost_price, retail_price, image_url, stock_quantity,
  is_visible, is_pos_visible, upc,
  product_group_id, variant_name, variant_color,
  source_system, source_external_id, source_category_path,
  import_status, source_metadata
)
select
  input.sku,
  input.slug,
  input.name,
  input.brand,
  input.model,
  category.id,
  taxonomy.id,
  input.short_description,
  input.condition_label,
  input.compatibility,
  input.cost_price,
  input.retail_price,
  input.image_url,
  0,
  false,
  true,
  input.upc,
  product_group.id,
  input.variant_name,
  input.variant_color,
  input.source_system,
  input.source_external_id,
  input.source_category_path,
  input.import_status,
  input.source_metadata
from misc_accessory_product_input input
join public.categories category on category.slug = input.database_category_slug
join public.pos_category_taxonomy taxonomy
  on taxonomy.category_name = input.pos_main_category
 and taxonomy.subcategory_name = input.pos_subcategory
 and taxonomy.active
left join public.product_groups product_group on product_group.code = input.product_group_code
on conflict (sku) do update
set slug = excluded.slug,
    name = excluded.name,
    brand = excluded.brand,
    model = excluded.model,
    category_id = excluded.category_id,
    pos_category_id = excluded.pos_category_id,
    short_description = excluded.short_description,
    condition_label = excluded.condition_label,
    compatibility = excluded.compatibility,
    cost_price = excluded.cost_price,
    retail_price = excluded.retail_price,
    image_url = excluded.image_url,
    stock_quantity = 0,
    is_visible = false,
    is_pos_visible = true,
    upc = excluded.upc,
    product_group_id = excluded.product_group_id,
    variant_name = excluded.variant_name,
    variant_color = excluded.variant_color,
    source_category_path = excluded.source_category_path,
    import_status = excluded.import_status,
    source_metadata = excluded.source_metadata,
    updated_at = timezone('utc'::text, now())
where public.products.source_system = excluded.source_system
  and public.products.source_external_id = excluded.source_external_id;

do $$
begin
  if (
    select count(*)
    from public.products product
    join public.pos_category_taxonomy taxonomy on taxonomy.id = product.pos_category_id
    where product.source_system = 'repairdesk_misc_accessories'
      and product.source_external_id in (select source_external_id from misc_accessory_product_input)
      and product.import_status = 'active'
      and product.is_pos_visible
      and not product.is_visible
      and product.stock_quantity = 0
      and coalesce(btrim(product.image_url), '') <> ''
      and taxonomy.active
  ) <> 34 then
    raise exception 'Miscellaneous accessory product validation failed.';
  end if;

  if (
    select count(*)
    from public.product_groups product_group
    where product_group.code in (select code from misc_accessory_group_input)
      and product_group.product_family = 'phone_accessory'
      and product_group.status = 'active'
      and product_group.is_pos_visible
      and not product_group.is_visible
  ) <> 4 then
    raise exception 'Miscellaneous accessory group validation failed.';
  end if;

  if exists (
    select 1
    from public.product_store_inventory inventory
    join public.products product on product.id = inventory.product_id
    where product.source_system = 'repairdesk_misc_accessories'
      and product.source_external_id in (select source_external_id from misc_accessory_product_input)
  ) then
    raise exception 'New products must not begin with store inventory.';
  end if;
end
$$;

commit;
