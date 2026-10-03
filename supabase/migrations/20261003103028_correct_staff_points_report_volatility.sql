-- Session validation expires stale sessions, so the admin report is volatile.
alter function public.get_staff_points_report(text, integer) volatile;
