-- Keep the RPC entry points independently authorized, including direct calls.
do $migration$
declare fn text; definition text; patched text;
begin
  foreach fn in array array['create_pos_used_device_acquisition','update_pos_used_device'] loop
    select replace(pg_get_functiondef(to_regprocedure('public.'||fn||'(text,jsonb)')),chr(13),'') into definition;
    patched := replace(definition, E'begin\n', E'begin\n  payload := payload || public.pos_authorized_actor(session_token, payload->>''store_code'', payload->>''staff_name'');\n');
    if patched = definition then raise exception 'Missing device authorization anchor: %',fn; end if;
    execute patched;
  end loop;
  foreach fn in array array['search_pos_used_devices','get_pos_used_device_transactions'] loop
    select replace(pg_get_functiondef(oid),chr(13),'') into definition
      from pg_proc where pronamespace='public'::regnamespace and proname=fn;
    patched := replace(definition, E'begin\n', E'begin\n  perform public.pos_authorized_actor(session_token,target_store_code,null);\n');
    if patched = definition then raise exception 'Missing device read authorization anchor: %',fn; end if;
    execute patched;
  end loop;

  select replace(pg_get_functiondef('public.get_pos_used_device_costs(text,text,text)'::regprocedure),chr(13),'') into definition;
  patched := replace(definition,
    '  device_id_value := (context->>''device_id'')::bigint;',
    '  if not coalesce((context->>''is_admin'')::boolean,false) then
    return jsonb_build_object(''ok'',true,''costs'',''[]''::jsonb,''can_view_costs'',false,''writable'',context->''writable'');
  end if;
  device_id_value := (context->>''device_id'')::bigint;');
  if patched=definition then raise exception 'Missing cost read anchor'; end if;
  execute patched;

  select replace(pg_get_functiondef('public.add_pos_used_device_cost(text,text,text,jsonb)'::regprocedure),chr(13),'') into definition;
  patched := replace(definition,
    E'    ''id'', cost_id,\n    ''refurb_cost'', public.pos_used_device_refurb_cost(device_id_value)',
    E'    ''id'', cost_id');
  if patched=definition then raise exception 'Missing cost response anchor'; end if;
  execute patched;
end;
$migration$;

-- pg_net lives in net, even when the extension is installed in extensions.
select cron.schedule('used-device-publish-drain','*/5 * * * *',$cron$
  select net.http_post(
    url := 'https://abkjbhmifswfexpjkval.supabase.co/functions/v1/pos-used-device-publish',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := '{"limit":20}'::jsonb,
    timeout_milliseconds := 55000
  ) where exists (
    select 1 from public.pos_used_device_publish_queue
    where completed_at is null and attempts < 5
  );
$cron$);
