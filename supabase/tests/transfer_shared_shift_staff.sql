-- All test sessions and temporary shift changes are rolled back, including on failure.
do $test$
declare
  token text := gen_random_uuid()::text;
  staff public.staff_directory%rowtype;
  store_id_value bigint;
  shift_row public.pos_store_shifts%rowtype;
  result jsonb;
  denied boolean;
  today_value date := (now() at time zone 'Australia/Brisbane')::date;
begin
  begin
    select * into strict staff from public.staff_directory where display_name='Jinny' and active;
    select id into strict store_id_value from public.store_locations where store_code='northlakes';
    assert public.staff_has_store_access(staff.id, store_id_value), 'Jinny must have NL access';
    insert into public.staff_sessions(staff_id,session_hash,token_digest,expires_at)
      values(staff.id,extensions.crypt(token,extensions.gen_salt('bf')),
        encode(extensions.digest(token,'sha256'),'hex'),now()+interval '5 minutes');
    perform pg_catalog.pg_advisory_xact_lock(store_id_value);
    select * into shift_row from public.pos_store_shifts
      where store_id=store_id_value and status='open' limit 1 for update;
    if not found then
      insert into public.pos_store_shifts(shift_code,store_id,business_date,status,opened_by,current_staff_name,last_staff_name)
        values('TRANSFER-TEST-'||gen_random_uuid(),store_id_value,today_value,'open','Bowen','Bowen','Bowen')
        returning * into shift_row;
    else
      update public.pos_store_shifts set business_date=today_value,current_staff_name='Bowen',last_staff_name='Bowen'
        where id=shift_row.id returning * into shift_row;
    end if;
    result := public.get_staff_transfer_context(token,'Jinny','northlakes',shift_row.shift_code);
    assert result->>'display_name'='Jinny' and result->>'current_store_slug'='north-lakes'
      and (result->>'ok')::boolean, 'Different staff must be allowed on shared store shift';
    assert (select current_staff_name from public.pos_store_shifts where id=shift_row.id)='Bowen',
      'Transfer must not overwrite another terminal operator';

    denied := false;
    begin perform public.get_staff_transfer_context(token,'Bowen','northlakes',shift_row.shift_code);
    exception when others then denied := true; end;
    assert denied, 'Cannot impersonate another staff member';
    denied := false;
    begin perform public.get_staff_transfer_context('invalid-session','Jinny','northlakes',shift_row.shift_code);
    exception when others then denied := true; end;
    assert denied, 'Invalid session accepted';
    denied := false;
    begin perform public.get_staff_transfer_context(token,'Jinny','toowong',shift_row.shift_code);
    exception when others then denied := true; end;
    assert denied, 'Wrong store shift accepted';
    denied := false;
    begin perform public.get_staff_transfer_context(token,'Jinny','northlakes','');
    exception when others then denied := true; end;
    assert denied, 'Missing shift accepted';

    update public.pos_store_shifts set business_date=today_value-1 where id=shift_row.id;
    denied := false;
    begin perform public.get_staff_transfer_context(token,'Jinny','northlakes',shift_row.shift_code);
    exception when others then denied := true; end;
    assert denied, 'Yesterday shift accepted';
    update public.pos_store_shifts set business_date=today_value,status='closed' where id=shift_row.id;
    denied := false;
    begin perform public.get_staff_transfer_context(token,'Jinny','northlakes',shift_row.shift_code);
    exception when others then denied := true; end;
    assert denied, 'Closed shift accepted';
    raise sqlstate 'P7777' using message='Transfer shared shift regression passed; roll back fixtures';
  exception when sqlstate 'P7777' then null;
  end;
end;
$test$;
