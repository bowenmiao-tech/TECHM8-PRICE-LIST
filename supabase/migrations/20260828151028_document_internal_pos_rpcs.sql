-- These RPCs still read staff_name and store_code out of the request body and
-- do not check the caller's store assignment themselves. That is safe only
-- because anon/authenticated are revoked on them and their single caller -
-- the pos-shared-state / pos-repair-tickets / pos-used-devices edge functions -
-- resolves the real actor with pos_authorized_actor and overwrites those fields
-- before calling in.
--
-- Any new caller that skips that step bypasses store and staff authorisation,
-- so the constraint is recorded on the functions themselves.

comment on function public.save_pos_held_cart(text, jsonb) is
  'Internal. anon/authenticated are revoked: call only through pos-shared-state, which resolves the actor with pos_authorized_actor and overwrites store_code/staff_name first.';
comment on function public.upsert_pos_repair_ticket(text, jsonb) is
  'Internal. anon/authenticated are revoked: call only through pos-repair-tickets, which resolves the actor with pos_authorized_actor and overwrites store_code/staff_name first.';
comment on function public.open_pos_store_shift(text, jsonb) is
  'Internal. anon/authenticated are revoked: call only through pos-shared-state, which resolves the actor with pos_authorized_actor and overwrites store_code/staff_name first.';
comment on function public.create_pos_used_device_acquisition(text, jsonb) is
  'Internal. anon/authenticated are revoked: call only through pos-used-devices, which resolves the actor with pos_authorized_actor and overwrites store_code/staff_name first.';
comment on function public.update_pos_used_device(text, jsonb) is
  'Internal. anon/authenticated are revoked: call only through pos-used-devices, which resolves the actor with pos_authorized_actor and overwrites store_code/staff_name first.';
