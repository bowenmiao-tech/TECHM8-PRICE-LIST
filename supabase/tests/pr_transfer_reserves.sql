-- Run against the product project. All fixture writes are rolled back.
begin;
do $test$
declare
  p bigint;
  pr bigint := (select id from public.stores where slug='park-ridge');
  tw bigint := (select id from public.stores where slug='toowong');
  nl bigint := (select id from public.stores where slug='north-lakes');
  t jsonb;
  req uuid := gen_random_uuid();
  receipt uuid;
  tid bigint;
  iid bigint;
  before_tw integer;
  before_nl integer;
  pr_before jsonb;
  before_total integer;
  rejected boolean;
begin
  select a.product_id into p from public.product_store_inventory a
    join public.product_store_inventory b on b.product_id=a.product_id and b.store_id=nl and b.quantity>1
    join public.products prod on prod.id=a.product_id and prod.is_pos_visible
    where a.store_id=tw and a.quantity>1 order by a.product_id limit 1;
  if p is null then raise exception 'No suitable test product'; end if;
  select quantity into before_tw from public.product_store_inventory where store_id=tw and product_id=p;
  select quantity into before_nl from public.product_store_inventory where store_id=nl and product_id=p;
  select stock_quantity into before_total from public.products where id=p;
  select to_jsonb(i) into pr_before from public.product_store_inventory i where store_id=pr and product_id=p;
  -- New products use 999 without a required inventory/seed job.
  delete from public.pos_pr_transfer_reserves where product_id=p;
  if (public.get_pos_pr_transfer_reserves()->>p::text)::integer<>999 then raise exception 'Future product default missing'; end if;
  t:=public.create_pos_stock_transfer('park-ridge','toowong',jsonb_build_array(jsonb_build_object('product_id',p,'quantity',10)),'Reserve regression test','rollback only',req);
  tid:=(t->>'id')::bigint; iid:=(t->'items'->0->>'id')::bigint;
  if t->>'source_stock_mode'<>'reserve' then raise exception 'Reserve mode not stored'; end if;
  if (select quantity from public.pos_pr_transfer_reserves where product_id=p)<>989 then raise exception 'Reserve not debited'; end if;
  if (select to_jsonb(i) from public.product_store_inventory i where store_id=pr and product_id=p) is distinct from pr_before then raise exception 'PR physical stock changed'; end if;
  if (select stock_quantity from public.products where id=p)<>before_total then raise exception 'Dispatch polluted web total'; end if;
  if (select quantity from public.product_store_inventory where store_id=tw and product_id=p)<>before_tw then raise exception 'Destination credited before receipt'; end if;
  perform public.create_pos_stock_transfer('park-ridge','toowong',jsonb_build_array(jsonb_build_object('product_id',p,'quantity',10)),'Reserve regression test','rollback only',req);
  if (select quantity from public.pos_pr_transfer_reserves where product_id=p)<>989 then raise exception 'Duplicate dispatch debited twice'; end if;
  rejected:=false;
  begin
    perform public.create_pos_stock_transfer('park-ridge','north-lakes',jsonb_build_array(jsonb_build_object('product_id',p,'quantity',990)),'Reserve regression test','rollback only',gen_random_uuid());
  exception when others then rejected:=true; end;
  if not rejected then raise exception 'Reserve limit bypassed'; end if;
  receipt:=gen_random_uuid();
  insert into public.stock_transfer_photos(transfer_id,receipt_key,storage_path,mime_type,file_size,uploaded_by)
    values(tid,receipt,'rollback-test/'||receipt,'image/png',1,'Reserve regression test');
  -- 4 good + 1 damaged + 1 missing, auto-return 4: only good stock reaches TW.
  perform public.receive_pos_stock_transfer(tid,receipt,jsonb_build_array(jsonb_build_object('transfer_item_id',iid,'good_quantity',4,'damaged_quantity',1,'missing_quantity',1)),true,'Reserve regression test','rollback only');
  if (select quantity from public.product_store_inventory where store_id=tw and product_id=p)<>before_tw+4 then raise exception 'Receipt quantity incorrect'; end if;
  if (select quantity from public.pos_pr_transfer_reserves where product_id=p)<>993 then raise exception 'Auto-return did not restore reserve'; end if;
  if (select stock_quantity from public.products where id=p)<>before_total+4 then raise exception 'Receipt polluted web total'; end if;
  perform public.receive_pos_stock_transfer(tid,receipt,jsonb_build_array(jsonb_build_object('transfer_item_id',iid,'good_quantity',4,'damaged_quantity',1,'missing_quantity',1)),true,'Reserve regression test','rollback only');
  if (select quantity from public.pos_pr_transfer_reserves where product_id=p)<>993 then raise exception 'Receipt replay restored twice'; end if;
  -- Partial receiving at NL, then explicit source return of remaining units.
  t:=public.create_pos_stock_transfer('park-ridge','north-lakes',jsonb_build_array(jsonb_build_object('product_id',p,'quantity',5)),'Reserve regression test','rollback only',gen_random_uuid());
  tid:=(t->>'id')::bigint; iid:=(t->'items'->0->>'id')::bigint; receipt:=gen_random_uuid();
  insert into public.stock_transfer_photos(transfer_id,receipt_key,storage_path,mime_type,file_size,uploaded_by)
    values(tid,receipt,'rollback-test/'||receipt,'image/png',1,'Reserve regression test');
  perform public.receive_pos_stock_transfer(tid,receipt,jsonb_build_array(jsonb_build_object('transfer_item_id',iid,'good_quantity',2)),false,'Reserve regression test','rollback only');
  receipt:=gen_random_uuid();
  insert into public.stock_transfer_photos(transfer_id,receipt_key,storage_path,mime_type,file_size,uploaded_by)
    values(tid,receipt,'rollback-test/'||receipt,'image/png',1,'Reserve regression test');
  perform public.return_pos_stock_transfer(tid,receipt,'Reserve regression test','rollback only');
  perform public.return_pos_stock_transfer(tid,receipt,'Reserve regression test','rollback only');
  if (select quantity from public.pos_pr_transfer_reserves where product_id=p)<>991 then raise exception 'Explicit return / retry incorrect'; end if;
  if (select quantity from public.product_store_inventory where store_id=nl and product_id=p)<>before_nl+2 then raise exception 'NL receipt incorrect'; end if;
  if (select to_jsonb(i) from public.product_store_inventory i where store_id=pr and product_id=p) is distinct from pr_before then raise exception 'Return changed PR physical stock'; end if;
  perform public.refresh_product_stock_totals(array[p]);
  if (select stock_quantity from public.products where id=p)<>before_total+6 then raise exception 'Recalculation included virtual stock'; end if;
  if exists(select 1 from public.inventory_movements m join public.stock_transfers tr on tr.id=m.transfer_id where tr.source_stock_mode='reserve' and m.store_id=pr) then raise exception 'Virtual movements polluted physical audit'; end if;
  -- Existing physical-store behavior remains unchanged.
  t:=public.create_pos_stock_transfer('toowong','north-lakes',jsonb_build_array(jsonb_build_object('product_id',p,'quantity',1)),'Reserve regression test','rollback only',gen_random_uuid());
  if t->>'source_stock_mode'<>'physical' then raise exception 'Other source incorrectly uses reserve'; end if;
  if (select quantity from public.product_store_inventory where store_id=tw and product_id=p)<>before_tw+3 then raise exception 'Physical dispatch debit broken'; end if;
  tid:=(t->>'id')::bigint; receipt:=gen_random_uuid();
  insert into public.stock_transfer_photos(transfer_id,receipt_key,storage_path,mime_type,file_size,uploaded_by)
    values(tid,receipt,'rollback-test/'||receipt,'image/png',1,'Reserve regression test');
  perform public.return_pos_stock_transfer(tid,receipt,'Reserve regression test','rollback only');
  if (select quantity from public.product_store_inventory where store_id=tw and product_id=p)<>before_tw+4 then raise exception 'Physical return broken'; end if;
  if has_table_privilege('anon','public.pos_pr_transfer_reserves','SELECT')
    or has_function_privilege('anon','public.get_pos_pr_transfer_reserves()','EXECUTE') then raise exception 'Reserve authorization leak'; end if;
end;
$test$;
rollback;
select 'PASS: PR reserve, physical inventory isolation, TW/NL receiving, partial/final receipts, damaged/missing units, auto/explicit returns, retries, limits, future products, web totals, physical transfer compatibility, grants' as result;
