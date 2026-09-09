create table public.pos_repair_ticket_updates (
  id uuid primary key,
  repair_ticket_id bigint not null references public.pos_repair_tickets(id),
  kind text not null check (kind in ('comment', 'photo')),
  body text not null default '' check (length(body) <= 5000),
  storage_path text unique,
  file_name text,
  author text not null,
  created_at timestamptz not null default now(),
  check ((kind = 'comment' and length(btrim(body)) > 0 and storage_path is null)
    or (kind = 'photo' and storage_path is not null))
);
create index pos_repair_ticket_updates_ticket_date_idx
  on public.pos_repair_ticket_updates(repair_ticket_id, created_at desc);
alter table public.pos_repair_ticket_updates enable row level security;
revoke all on public.pos_repair_ticket_updates from anon, authenticated;
grant all on public.pos_repair_ticket_updates to service_role;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('repair-ticket-photos', 'repair-ticket-photos', false, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- Both portals use this gate; the browser cannot supply an author or ticket ID.
create or replace function public.authorize_repair_ticket_update(session_token text, store_code text, ticket_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor jsonb;
  ticket public.pos_repair_tickets%rowtype;
  admin_name text;
begin
  select * into ticket from public.pos_repair_tickets t
    where t.ticket_code = authorize_repair_ticket_update.ticket_code;
  if not found then raise exception 'Repair ticket not found'; end if;
  if not exists (select 1 from public.store_locations s where s.id = ticket.store_id and s.store_code = authorize_repair_ticket_update.store_code) then
    raise exception 'Repair ticket belongs to another store';
  end if;
  select coalesce(nullif(staff.display_name, ''), admin.login_email) into admin_name
    from public.admin_sessions sessions join public.admin_users admin on admin.id = sessions.admin_user_id
    left join public.staff_directory staff on lower(staff.email) = lower(admin.login_email) and staff.active
    where sessions.expires_at > now() and admin.active
      and extensions.crypt(session_token, sessions.session_hash) = sessions.session_hash limit 1;
  if admin_name is null then
    actor := public.pos_authorized_actor(session_token, store_code, null);
    if (actor->>'store_id')::bigint <> ticket.store_id then raise exception 'Store access denied'; end if;
    admin_name := actor->>'staff_name';
  end if;
  return jsonb_build_object('ok', true, 'ticket_id', ticket.id, 'store_id', ticket.store_id,
    'author', admin_name, 'writable', ticket.active);
end;
$$;

create or replace function public.get_repair_ticket_updates(session_token text, store_code text, ticket_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  context jsonb;
  result jsonb;
  legacy jsonb;
begin
  context := public.authorize_repair_ticket_update(session_token, store_code, ticket_code);
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'body', body,
    'storage_path', storage_path, 'file_name', file_name, 'author', author, 'created_at', created_at)
    order by created_at desc, id), '[]'::jsonb) into result
    from public.pos_repair_ticket_updates where repair_ticket_id = (context->>'ticket_id')::bigint;
  select coalesce(jsonb_agg(jsonb_build_object('id', entry->>'id', 'kind', 'comment',
    'body', regexp_replace(coalesce(entry->>'text',''), '^commented:\s*', '', 'i'),
    'author', coalesce(entry->>'staffName','Staff'), 'created_at', entry->>'at')), '[]'::jsonb) into legacy
    from public.pos_repair_tickets t, lateral jsonb_array_elements(t.activity) entry
    where t.id = (context->>'ticket_id')::bigint
      and (entry->>'type' = 'comment' or coalesce(entry->>'text','') ~* '^commented:');
  return jsonb_build_object('ok', true, 'updates', result || legacy, 'writable', context->'writable');
end;
$$;

create or replace function public.add_repair_ticket_update(session_token text, store_code text, ticket_code text, payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  context jsonb;
  update_id uuid := (payload->>'id')::uuid;
  ticket_id_value bigint;
  existing public.pos_repair_ticket_updates%rowtype;
  path_value text;
begin
  context := public.authorize_repair_ticket_update(session_token, store_code, ticket_code);
  if not (context->>'writable')::boolean then raise exception 'Deleted repair tickets are read-only'; end if;
  ticket_id_value := (context->>'ticket_id')::bigint;
  perform id from public.pos_repair_tickets where id = ticket_id_value for update;
  if not (select active from public.pos_repair_tickets where id = ticket_id_value) then
    raise exception 'Deleted repair tickets are read-only';
  end if;
  select * into existing from public.pos_repair_ticket_updates where id = update_id;
  if found then
    if existing.repair_ticket_id <> ticket_id_value or existing.author <> context->>'author'
      or existing.kind <> payload->>'kind' then raise exception 'Update ID already used'; end if;
    return jsonb_build_object('ok', true, 'id', existing.id);
  end if;
  if payload->>'kind' = 'photo' then
    path_value := payload->>'storage_path';
    if path_value is distinct from ((context->>'store_id') || '/' || ticket_id_value || '/' || update_id || '.jpg') then
      raise exception 'Invalid repair photo path';
    end if;
    if not exists(select 1 from storage.objects where bucket_id = 'repair-ticket-photos' and name = path_value) then
      raise exception 'Photo upload is missing';
    end if;
  elsif payload->>'kind' is distinct from 'comment' then raise exception 'Invalid update type';
  end if;
  insert into public.pos_repair_ticket_updates(id, repair_ticket_id, kind, body, storage_path, file_name, author)
    values(update_id, ticket_id_value, payload->>'kind', btrim(coalesce(payload->>'body','')),
      path_value, left(coalesce(payload->>'file_name',''), 180), context->>'author');
  return jsonb_build_object('ok', true, 'id', update_id);
end;
$$;

revoke all on function public.authorize_repair_ticket_update(text,text,text) from public, anon, authenticated;
revoke all on function public.get_repair_ticket_updates(text,text,text) from public, anon, authenticated;
revoke all on function public.add_repair_ticket_update(text,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.authorize_repair_ticket_update(text,text,text) to service_role;
grant execute on function public.get_repair_ticket_updates(text,text,text) to service_role;
grant execute on function public.add_repair_ticket_update(text,text,text,jsonb) to service_role;
