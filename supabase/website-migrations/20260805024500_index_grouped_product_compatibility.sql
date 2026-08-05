create index if not exists product_fit_profile_devices_device_model_idx
on public.product_fit_profile_devices (device_model_id, fit_profile_id);
