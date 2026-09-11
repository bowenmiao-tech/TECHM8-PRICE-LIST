-- Public used-device listings. Run against the website/product project.
-- Every fixture write is rolled back.
begin;
do $test$
declare
  result jsonb;
  listings jsonb;
  refused boolean;
  base jsonb := jsonb_build_object(
    'device_code', 'USED-TESTABC123', 'device_category', 'Phone', 'store_code', 'toowong',
    'title', 'Apple iPhone 13 128GB Blue', 'brand', 'Apple', 'model', 'iPhone 13',
    'storage', '128GB', 'color', 'Blue', 'condition_grade', 'Good',
    'condition_summary', 'Good condition. Light signs of use.', 'battery_health', '89',
    'price', '649', 'description', 'Tested in store.',
    'highlights', jsonb_build_array('23 of 23 inspection checks passed'),
    'images', jsonb_build_array(jsonb_build_object('url', 'https://example.test/1.jpg', 'position', 1)));
begin
  result := public.upsert_used_device_listing(base || jsonb_build_object('source_version', '10'));
  assert (result->>'ok')::boolean and result->>'status' = 'published', 'The listing did not publish';
  assert result->>'slug' like 'apple-iphone-13-128gb-blue-%', format('Unexpected slug: %s', result->>'slug');

  listings := public.get_used_device_listings('used-phones', '', 10, 0);
  assert (listings->>'total')::integer >= 1, 'The published listing is not readable';
  assert jsonb_typeof(listings->'categories') = 'array', 'The category list is missing';
  assert not exists (
    select 1 from jsonb_array_elements(listings->'listings') entry
    where entry ? 'device_code' or entry ? 'store_code'
  ), 'The public feed exposed an internal field';

  -- A slow retry of an older version must not win.
  result := public.upsert_used_device_listing(base || jsonb_build_object('source_version', '5', 'price', '1'));
  assert (result->>'skipped')::boolean, 'An older version overwrote a newer one';
  assert (select price = 649 from public.used_device_listings where device_code = 'USED-TESTABC123'),
    'The price was overwritten by a stale retry';

  -- A device identifier must never reach a public field.
  refused := false;
  begin
    perform public.upsert_used_device_listing(base || jsonb_build_object(
      'source_version', '20', 'description', 'IMEI 356938035643809 included'));
  exception when others then refused := true;
  end;
  assert refused, 'An IMEI was accepted into a public listing';

  -- A published listing has to have something to show.
  refused := false;
  begin
    perform public.upsert_used_device_listing(base || jsonb_build_object(
      'device_code', 'USED-TESTXYZ999', 'source_version', '30', 'images', '[]'::jsonb));
  exception when others then refused := true;
  end;
  assert refused, 'A listing published without an image';

  result := public.withdraw_used_device_listing(jsonb_build_object(
    'device_code', 'USED-TESTABC123', 'status', 'sold', 'source_version', '40'));
  assert result->>'status' = 'sold', 'The listing was not marked sold';
  assert (select published_at is not null from public.used_device_listings where device_code = 'USED-TESTABC123'),
    'The original publish date was lost';

  listings := public.get_used_device_listings('used-phones', '', 10, 0);
  assert not exists (
    select 1 from jsonb_array_elements(listings->'listings') entry
    where entry->>'slug' like 'apple-iphone-13-128gb-blue-%'), 'A sold device is still listed';

  raise notice 'used_device_listings: all checks passed';
end;
$test$;
rollback;
