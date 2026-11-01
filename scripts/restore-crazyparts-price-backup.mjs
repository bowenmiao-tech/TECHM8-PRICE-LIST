import fs from 'node:fs/promises';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const [backupName, cutoff] = process.argv.slice(2);
if (!backupName || !/^\d{4}-\d{2}-\d{2}T[\d:.]+Z$/.test(cutoff || '')) throw new Error('Specify a backup and the completed sync timestamp.');
const backup = JSON.parse(await fs.readFile(backupName, 'utf8'));
const brands = [...new Set(backup.plan.updates.map((row) => row.brand))];
const payload = JSON.stringify(backup.rows);
const insertedPayload = JSON.stringify(backup.plan.updates.filter((row) => row.oldPrice === null));
const statusPayload = JSON.stringify((backup.plan.statusRows || []).map((row) => row.family));
const sql = `begin;
create temporary table restore_prices as
select * from jsonb_to_recordset($backup$${payload}$backup$::jsonb)
as t(brand text,model text,issue text,price text);
delete from public.repair_prices p
using jsonb_to_recordset($inserted$${insertedPayload}$inserted$::jsonb)
as inserted(brand text,model text,issue text,"newPrice" text)
where (p.brand,p.model,p.issue)=(inserted.brand,inserted.model,inserted.issue)
and p.price=inserted."newPrice"
and p.updated_at <= '${cutoff}'::timestamptz
and not exists(select 1 from restore_prices r where (r.brand,r.model,r.issue)=(p.brand,p.model,p.issue));
insert into public.repair_prices(brand,model,issue,price)
select brand,model,issue,price from restore_prices
on conflict(brand,model,issue) do update set price=excluded.price,updated_at=now()
where repair_prices.updated_at <= '${cutoff}'::timestamptz
and repair_prices.price is distinct from excluded.price;
update public.crazyparts_update_status set status='failed',message='Previous prices restored from a backup. A new verified update is required.',updated_at=now()
where family in (select jsonb_array_elements_text($families$${statusPayload}$families$::jsonb));
commit;`;
const file = path.resolve('outputs/crazyparts-price-monitor', `.restore-${process.pid}.sql`);
await fs.writeFile(file, sql);
try {
  const result = spawnSync('supabase.exe', ['db','query','--linked','--file',file,'--output','json','--agent=no'], { encoding:'utf8',windowsHide:true,timeout:60000 });
  if(result.status !== 0) throw new Error(result.stderr || result.stdout);
  console.log(`Restored pre-run prices for ${brands.join(', ')}; later edits were preserved.`);
} finally { await fs.rm(file,{force:true}); }
