-- Keep one canonical line type for physical catalogue products. This also
-- makes historical product lines eligible for returned-quantity stock restore.
alter table public.pos_sales_order_lines
  drop constraint if exists pos_sales_order_lines_line_type_check;
alter table public.pos_sales_order_lines
  add constraint pos_sales_order_lines_line_type_check
  check (line_type in ('product', 'retail', 'repair', 'special', 'used_device'));

update public.pos_sales_order_lines
set line_type = 'retail'
where line_type = 'product';

create or replace function public.normalize_pos_retail_line_type()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.line_type = 'product' then new.line_type := 'retail'; end if;
  return new;
end;
$$;

drop trigger if exists normalize_pos_retail_line_type_trigger
  on public.pos_sales_order_lines;
create trigger normalize_pos_retail_line_type_trigger
before insert or update of line_type on public.pos_sales_order_lines
for each row execute function public.normalize_pos_retail_line_type();

revoke all on function public.normalize_pos_retail_line_type()
  from public, anon, authenticated;
