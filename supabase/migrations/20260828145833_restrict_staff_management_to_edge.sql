revoke all on function public.get_staff_management(text) from public, anon, authenticated;
revoke all on function public.update_staff_management(text, bigint, text, boolean) from public, anon, authenticated;

grant execute on function public.get_staff_management(text) to service_role;
grant execute on function public.update_staff_management(text, bigint, text, boolean) to service_role;
