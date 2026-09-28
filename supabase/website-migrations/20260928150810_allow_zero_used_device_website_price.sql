-- Published used devices may be free; their price remains explicitly stored.
alter table public.used_device_listings
  drop constraint used_device_listings_price_check,
  add constraint used_device_listings_price_check check (price >= 0);
