-- Staff credentials are now individual. Keep the retired shared-password updater
-- unavailable to browser roles so it cannot be mistaken for an account reset API.
revoke all on function public.change_staff_password(text, text) from public, anon, authenticated;
grant execute on function public.change_staff_password(text, text) to service_role;

comment on function public.change_staff_password(text, text) is
  'Legacy shared staff password updater. Browser execution is disabled; staff now change individual credentials through change_staff_credentials.';
