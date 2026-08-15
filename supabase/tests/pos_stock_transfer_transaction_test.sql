begin;

do $transfer_test$
declare
  test_product_id bigint;
  source_store_id bigint;
  destination_store_id bigint;
  transfer_one_id bigint;
  transfer_two_id bigint;
  transfer_three_id bigint;
  transfer_one_item_id bigint;
  transfer_two_item_id bigint;
  transfer_three_item_id bigint;
  dispatch_key uuid := gen_random_uuid();
  partial_key uuid := gen_random_uuid();
  final_key uuid := gen_random_uuid();
  clean_dispatch_key uuid := gen_random_uuid();
  clean_receive_key uuid := gen_random_uuid();
  return_dispatch_key uuid := gen_random_uuid();
  wrong_item_key uuid := gen_random_uuid();
  return_partial_key uuid := gen_random_uuid();
  return_key uuid := gen_random_uuid();
  result_payload jsonb;
  source_quantity integer;
  destination_quantity integer;
  expected_total integer;
  saved_total integer;
  movement_count integer;
  test_failed boolean;
begin
  select product.id
  into test_product_id
  from public.products product
  where product.is_pos_visible = true
  order by product.id
  limit 1;

  select id into source_store_id from public.stores where slug = 'park-ridge';
  select id into destination_store_id from public.stores where slug = 'north-lakes';

  if test_product_id is null or source_store_id is null or destination_store_id is null then
    raise exception 'Transfer test prerequisites are missing';
  end if;

  insert into public.product_store_inventory (product_id, store_id, quantity, updated_at)
  values
    (test_product_id, source_store_id, 20, now()),
    (test_product_id, destination_store_id, 3, now())
  on conflict (product_id, store_id) do update
  set quantity = excluded.quantity, updated_at = now();
  perform public.refresh_product_stock_totals(array[test_product_id]);

  test_failed := false;
  begin
    perform public.create_pos_stock_transfer(
      'park-ridge', 'park-ridge',
      jsonb_build_array(jsonb_build_object('product_id', test_product_id, 'quantity', 1)),
      'Codex Transaction Test', '', gen_random_uuid()
    );
  exception when others then
    test_failed := true;
  end;
  if not test_failed then raise exception 'Same-store transfer was accepted'; end if;

  test_failed := false;
  begin
    perform public.create_pos_stock_transfer(
      'park-ridge', 'warehouse-dispatch',
      jsonb_build_array(jsonb_build_object('product_id', test_product_id, 'quantity', 1)),
      'Codex Transaction Test', '', gen_random_uuid()
    );
  exception when others then
    test_failed := true;
  end;
  if not test_failed then raise exception 'Non-POS store transfer was accepted'; end if;

  test_failed := false;
  begin
    perform public.create_pos_stock_transfer(
      'park-ridge', 'north-lakes',
      jsonb_build_array(jsonb_build_object('product_id', test_product_id, 'quantity', 1.5)),
      'Codex Transaction Test', '', gen_random_uuid()
    );
  exception when others then
    test_failed := true;
  end;
  if not test_failed then raise exception 'Fractional dispatch quantity was accepted'; end if;

  test_failed := false;
  begin
    perform public.create_pos_stock_transfer(
      'park-ridge', 'north-lakes',
      jsonb_build_array(jsonb_build_object('product_id', test_product_id, 'quantity', 21)),
      'Codex Transaction Test', '', gen_random_uuid()
    );
  exception when others then
    test_failed := true;
  end;
  if not test_failed then raise exception 'Insufficient-stock transfer was accepted'; end if;
  select quantity into source_quantity from public.product_store_inventory
  where product_id = test_product_id and store_id = source_store_id;
  if source_quantity <> 20 then raise exception 'Rejected dispatch changed source stock'; end if;

  result_payload := public.create_pos_stock_transfer(
    'park-ridge', 'north-lakes',
    jsonb_build_array(jsonb_build_object('product_id', test_product_id, 'quantity', 5)),
    'Codex Transaction Test', 'First transfer', dispatch_key
  );
  transfer_one_id := (result_payload ->> 'id')::bigint;
  transfer_one_item_id := (result_payload #>> '{items,0,id}')::bigint;

  select quantity into source_quantity from public.product_store_inventory
  where product_id = test_product_id and store_id = source_store_id;
  select quantity into destination_quantity from public.product_store_inventory
  where product_id = test_product_id and store_id = destination_store_id;
  if source_quantity <> 15 or destination_quantity <> 3 then
    raise exception 'Dispatch did not deduct source exactly once';
  end if;

  perform public.create_pos_stock_transfer(
    'park-ridge', 'north-lakes',
    jsonb_build_array(jsonb_build_object('product_id', test_product_id, 'quantity', 5)),
    'Codex Transaction Test', 'First transfer', dispatch_key
  );
  select quantity into source_quantity from public.product_store_inventory
  where product_id = test_product_id and store_id = source_store_id;
  if source_quantity <> 15 then raise exception 'Idempotent dispatch deducted stock twice'; end if;

  test_failed := false;
  begin
    perform public.create_pos_stock_transfer(
      'park-ridge', 'north-lakes',
      jsonb_build_array(jsonb_build_object('product_id', test_product_id, 'quantity', 4)),
      'Codex Transaction Test', 'First transfer', dispatch_key
    );
  exception when others then
    test_failed := true;
  end;
  if not test_failed then raise exception 'Reused dispatch key accepted different content'; end if;

  test_failed := false;
  begin
    perform public.receive_pos_stock_transfer(
      transfer_one_id, partial_key,
      jsonb_build_array(jsonb_build_object(
        'transfer_item_id', transfer_one_item_id,
        'good_quantity', 2,
        'damaged_quantity', 1
      )),
      false, 'Codex Transaction Test', 'No photo yet'
    );
  exception when others then
    test_failed := true;
  end;
  if not test_failed then raise exception 'Receipt without a photo was accepted'; end if;

  perform public.register_pos_stock_transfer_photo(
    transfer_one_id, partial_key, 'receipt',
    transfer_one_id || '/' || partial_key || '/front.jpg',
    'image/jpeg', 1000, 'Codex Transaction Test'
  );
  perform public.register_pos_stock_transfer_photo(
    transfer_one_id, partial_key, 'issue',
    transfer_one_id || '/' || partial_key || '/damage.jpg',
    'image/jpeg', 1200, 'Codex Transaction Test'
  );

  result_payload := public.receive_pos_stock_transfer(
    transfer_one_id, partial_key,
    jsonb_build_array(jsonb_build_object(
      'transfer_item_id', transfer_one_item_id,
      'good_quantity', 2,
      'damaged_quantity', 1
    )),
    false, 'Codex Transaction Test', 'Partial receipt'
  );
  if result_payload ->> 'status' <> 'partially_received' then
    raise exception 'Partial receipt status is incorrect';
  end if;
  if (result_payload #>> '{items,0,remaining_quantity}')::integer <> 2 then
    raise exception 'Partial receipt remaining quantity is incorrect';
  end if;
  if jsonb_array_length(result_payload -> 'photos') <> 2 then
    raise exception 'Multiple receipt photos were not retained';
  end if;
  select quantity into destination_quantity from public.product_store_inventory
  where product_id = test_product_id and store_id = destination_store_id;
  if destination_quantity <> 5 then raise exception 'Only good partial stock should reach destination'; end if;

  perform public.receive_pos_stock_transfer(
    transfer_one_id, partial_key,
    jsonb_build_array(jsonb_build_object(
      'transfer_item_id', transfer_one_item_id,
      'good_quantity', 2,
      'damaged_quantity', 1
    )),
    false, 'Codex Transaction Test', 'Partial receipt'
  );
  select quantity into destination_quantity from public.product_store_inventory
  where product_id = test_product_id and store_id = destination_store_id;
  if destination_quantity <> 5 then raise exception 'Idempotent receipt added stock twice'; end if;

  test_failed := false;
  begin
    perform public.receive_pos_stock_transfer(
      transfer_one_id, partial_key,
      jsonb_build_array(jsonb_build_object(
        'transfer_item_id', transfer_one_item_id,
        'good_quantity', 1,
        'damaged_quantity', 0
      )),
      false, 'Codex Transaction Test', 'Different retry'
    );
  exception when others then
    test_failed := true;
  end;
  if not test_failed then raise exception 'Reused receipt key accepted different content'; end if;

  perform public.register_pos_stock_transfer_photo(
    transfer_one_id, final_key, 'receipt',
    transfer_one_id || '/' || final_key || '/final.jpg',
    'image/jpeg', 1300, 'Codex Transaction Test'
  );
  result_payload := public.receive_pos_stock_transfer(
    transfer_one_id, final_key,
    jsonb_build_array(jsonb_build_object(
      'transfer_item_id', transfer_one_item_id,
      'good_quantity', 1,
      'damaged_quantity', 0
    )),
    true, 'Codex Transaction Test', 'Final receipt with one missing'
  );
  if result_payload ->> 'status' <> 'completed_with_issues' then
    raise exception 'Issue completion status is incorrect';
  end if;
  if (result_payload #>> '{items,0,received_good_quantity}')::integer <> 3
    or (result_payload #>> '{items,0,received_damaged_quantity}')::integer <> 1
    or (result_payload #>> '{items,0,missing_quantity}')::integer <> 1 then
    raise exception 'Good, damaged or missing totals are incorrect';
  end if;
  select quantity into destination_quantity from public.product_store_inventory
  where product_id = test_product_id and store_id = destination_store_id;
  if destination_quantity <> 6 then raise exception 'Issue completion added incorrect saleable stock'; end if;

  result_payload := public.create_pos_stock_transfer(
    'park-ridge', 'north-lakes',
    jsonb_build_array(jsonb_build_object('product_id', test_product_id, 'quantity', 2)),
    'Codex Transaction Test', 'Clean transfer', clean_dispatch_key
  );
  transfer_two_id := (result_payload ->> 'id')::bigint;
  transfer_two_item_id := (result_payload #>> '{items,0,id}')::bigint;
  perform public.register_pos_stock_transfer_photo(
    transfer_two_id, clean_receive_key, 'receipt',
    transfer_two_id || '/' || clean_receive_key || '/clean.jpg',
    'image/jpeg', 1400, 'Codex Transaction Test'
  );
  result_payload := public.receive_pos_stock_transfer(
    transfer_two_id, clean_receive_key,
    jsonb_build_array(jsonb_build_object(
      'transfer_item_id', transfer_two_item_id,
      'good_quantity', 2,
      'damaged_quantity', 0
    )),
    true, 'Codex Transaction Test', 'Clean receipt'
  );
  if result_payload ->> 'status' <> 'completed' then
    raise exception 'Clean completion status is incorrect';
  end if;

  result_payload := public.create_pos_stock_transfer(
    'park-ridge', 'north-lakes',
    jsonb_build_array(jsonb_build_object('product_id', test_product_id, 'quantity', 3)),
    'Codex Transaction Test', 'Return transfer', return_dispatch_key
  );
  transfer_three_id := (result_payload ->> 'id')::bigint;
  transfer_three_item_id := (result_payload #>> '{items,0,id}')::bigint;

  perform public.register_pos_stock_transfer_photo(
    transfer_three_id, wrong_item_key, 'receipt',
    transfer_three_id || '/' || wrong_item_key || '/wrong-item.jpg',
    'image/jpeg', 900, 'Codex Transaction Test'
  );
  test_failed := false;
  begin
    perform public.receive_pos_stock_transfer(
      transfer_three_id, wrong_item_key,
      jsonb_build_array(jsonb_build_object(
        'transfer_item_id', transfer_one_item_id,
        'good_quantity', 1,
        'damaged_quantity', 0
      )),
      false, 'Codex Transaction Test', 'Wrong transfer item'
    );
  exception when others then
    test_failed := true;
  end;
  if not test_failed then raise exception 'Receipt accepted an item from another transfer'; end if;

  perform public.register_pos_stock_transfer_photo(
    transfer_three_id, return_partial_key, 'receipt',
    transfer_three_id || '/' || return_partial_key || '/partial.jpg',
    'image/jpeg', 1500, 'Codex Transaction Test'
  );
  perform public.receive_pos_stock_transfer(
    transfer_three_id, return_partial_key,
    jsonb_build_array(jsonb_build_object(
      'transfer_item_id', transfer_three_item_id,
      'good_quantity', 1,
      'damaged_quantity', 0
    )),
    false, 'Codex Transaction Test', 'Receive one before return'
  );

  perform public.register_pos_stock_transfer_photo(
    transfer_three_id, return_key, 'return',
    transfer_three_id || '/' || return_key || '/return.jpg',
    'image/jpeg', 1600, 'Codex Transaction Test'
  );
  select quantity into source_quantity from public.product_store_inventory
  where product_id = test_product_id and store_id = source_store_id;
  result_payload := public.return_pos_stock_transfer(
    transfer_three_id, return_key, 'Codex Transaction Test', 'Courier returned remaining box'
  );
  if result_payload ->> 'status' <> 'returned' then
    raise exception 'Return status is incorrect';
  end if;
  if (select quantity from public.product_store_inventory
      where product_id = test_product_id and store_id = source_store_id) <> source_quantity + 2 then
    raise exception 'Returned remaining stock was not restored to source';
  end if;
  perform public.return_pos_stock_transfer(
    transfer_three_id, return_key, 'Codex Transaction Test', 'Courier returned remaining box'
  );
  if (select quantity from public.product_store_inventory
      where product_id = test_product_id and store_id = source_store_id) <> source_quantity + 2 then
    raise exception 'Idempotent return restored source stock twice';
  end if;

  select coalesce(sum(quantity), 0)::integer into expected_total
  from public.product_store_inventory where product_id = test_product_id;
  select stock_quantity into saved_total from public.products where id = test_product_id;
  if saved_total <> expected_total then raise exception 'Product aggregate does not match store stock'; end if;

  select count(*) into movement_count
  from public.inventory_movements
  where transfer_id in (transfer_one_id, transfer_two_id, transfer_three_id);
  if movement_count <> 8 then
    raise exception 'Expected 8 immutable inventory movements, found %', movement_count;
  end if;

  test_failed := false;
  begin
    update public.product_store_inventory
    set quantity = -1
    where product_id = test_product_id and store_id = source_store_id;
  exception when check_violation then
    test_failed := true;
  end;
  if not test_failed then raise exception 'Negative store stock was accepted'; end if;

  raise notice 'POS stock transfer transaction tests passed for product %, transfers %, %, %',
    test_product_id, transfer_one_id, transfer_two_id, transfer_three_id;
end
$transfer_test$;

rollback;
