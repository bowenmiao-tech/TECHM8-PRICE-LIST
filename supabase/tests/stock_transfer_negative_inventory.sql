-- Run in the PRODUCT project. All inventory/transfer fixtures roll back.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '25s';
do $test$
declare
  p bigint;
  pr bigint := (select id from public.stores where slug = 'park-ridge');
  tw bigint := (select id from public.stores where slug = 'toowong');
  t jsonb;
  tid bigint;
  iid bigint;
  receipt uuid := gen_random_uuid();
  receipt2 uuid := gen_random_uuid();
  pr_before jsonb;
  reserve_before integer;
  rejected boolean;
begin
  select id into p from public.products where is_pos_visible order by id limit 1;
  if p is null or pr is null or tw is null then raise exception 'Missing test product/store'; end if;
  select to_jsonb(i) into pr_before from public.product_store_inventory i where store_id = pr and product_id = p;
  select coalesce((public.get_pos_pr_transfer_reserves()->>p::text)::integer,999) into reserve_before;
  insert into public.product_store_inventory(product_id,store_id,quantity)
    values(p,tw,-3) on conflict(product_id,store_id) do update set quantity = -3;
  t := public.create_pos_stock_transfer('park-ridge','toowong',
    jsonb_build_array(jsonb_build_object('product_id',p,'quantity',3)),
    'Signed balance regression','rollback only',gen_random_uuid());
  tid := (t->>'id')::bigint;
  iid := (t->'items'->0->>'id')::bigint;
  insert into public.stock_transfer_photos(transfer_id,receipt_key,storage_path,mime_type,file_size,uploaded_by)
    values(tid,receipt,'rollback-test/'||receipt,'image/png',1,'Signed balance regression');
  perform public.receive_pos_stock_transfer(tid,receipt,
    jsonb_build_array(jsonb_build_object('transfer_item_id',iid,'good_quantity',1)),
    false,'Signed balance regression','rollback only');
  if (select quantity from public.product_store_inventory where store_id=tw and product_id=p) <> -2 then
    raise exception 'Partial receipt must preserve the remaining deficit';
  end if;
  if not exists(select 1 from public.inventory_movements where transfer_id=tid
    and quantity_before=-3 and quantity_delta=1 and quantity_after=-2) then
    raise exception 'Signed movement audit is missing';
  end if;
  perform public.receive_pos_stock_transfer(tid,receipt,
    jsonb_build_array(jsonb_build_object('transfer_item_id',iid,'good_quantity',1)),
    false,'Signed balance regression','rollback only');
  if (select quantity from public.product_store_inventory where store_id=tw and product_id=p) <> -2 then
    raise exception 'Receipt retry credited stock twice';
  end if;
  rejected := false;
  begin
    perform public.create_pos_stock_transfer('toowong','park-ridge',
      jsonb_build_array(jsonb_build_object('product_id',p,'quantity',1)),
      'Signed balance regression','rollback only',gen_random_uuid());
  exception when raise_exception then
    if sqlerrm <> 'One or more products do not have enough source-store inventory' then raise; end if;
    rejected := true;
  end;
  if not rejected then raise exception 'Negative source stock allowed physical dispatch'; end if;
  insert into public.stock_transfer_photos(transfer_id,receipt_key,storage_path,mime_type,file_size,uploaded_by)
    values(tid,receipt2,'rollback-test/'||receipt2,'image/png',1,'Signed balance regression');
  perform public.receive_pos_stock_transfer(tid,receipt2,
    jsonb_build_array(jsonb_build_object('transfer_item_id',iid,'good_quantity',2)),
    true,'Signed balance regression','rollback only');
  if (select quantity from public.product_store_inventory where store_id=tw and product_id=p) <> 0 then
    raise exception 'Final receipt did not clear deficit';
  end if;
  if (select status from public.stock_transfers where id=tid) <> 'completed' then
    raise exception 'Transfer did not complete';
  end if;
  if (select quantity from public.pos_pr_transfer_reserves where product_id=p) <> reserve_before-3 then
    raise exception 'Reserve accounting changed';
  end if;
  if (select to_jsonb(i) from public.product_store_inventory i where store_id=pr and product_id=p) is distinct from pr_before then
    raise exception 'PR physical stock changed';
  end if;
end;
$test$;
rollback;
select 'PASS: negative receipt balances, signed audit, retry, physical dispatch guard, completion and PR isolation; all fixtures rolled back' as result;
