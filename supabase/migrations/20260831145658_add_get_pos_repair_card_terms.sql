-- The POS needs the active terms text to show the customer before they sign.
create or replace function public.get_pos_repair_card_terms(session_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  active_terms public.pos_repair_card_terms%rowtype;
begin
  if not public.is_valid_staff_session(session_token) then raise exception 'Invalid staff session'; end if;
  select * into active_terms
  from public.pos_repair_card_terms
  where active order by created_at desc limit 1;
  if not found then raise exception 'No active repair card terms'; end if;
  return jsonb_build_object('ok', true, 'version', active_terms.version, 'body', active_terms.body);
end;
$$;

revoke all on function public.get_pos_repair_card_terms(text) from public, anon, authenticated;
grant execute on function public.get_pos_repair_card_terms(text) to anon, authenticated, service_role;
