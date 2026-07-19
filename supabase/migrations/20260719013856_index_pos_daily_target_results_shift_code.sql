create index if not exists pos_daily_target_results_shift_code_idx
on public.pos_daily_target_results (shift_code)
where shift_code is not null;
