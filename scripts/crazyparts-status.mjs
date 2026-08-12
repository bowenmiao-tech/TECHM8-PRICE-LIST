import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputDir = path.join(projectRoot, 'outputs', 'crazyparts-price-monitor');

const canonicalFamilies = new Map([
  ['a series', 'A Series'],
  ['oppo', 'Oppo'],
  ['huawei', 'Huawei'],
  ['xiaomi', 'Xiaomi'],
  ['redmi', 'Redmi'],
  ['motorola', 'Motorola'],
  ['nokia', 'Nokia'],
  ['oneplus', 'Oneplus'],
  ['realme', 'Realme'],
  ['vivo', 'Vivo'],
  ['sony', 'Sony'],
]);

function quote(value) {
  if (value === null || value === undefined) return 'null';
  return `'${String(value).replace(/'/g, "''")}'`;
}

export function canonicalStatusFamily(value) {
  return canonicalFamilies.get(String(value || '').trim().toLowerCase()) || '';
}

export function trackedFamilyFromArgs(argv) {
  if (process.env.CRAZYPARTS_TRACK_STATUS !== '1') return '';
  const values = [];
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--family') values.push(argv[index + 1]);
  }
  return values.length === 1 ? canonicalStatusFamily(values[0]) : '';
}

export function reportCrazyPartsStatus(familyValue, fields = {}) {
  const family = canonicalStatusFamily(familyValue);
  if (!family || process.env.CRAZYPARTS_TRACK_STATUS !== '1') return false;

  const assignments = [];
  const textFields = ['status', 'message'];
  const numberFields = ['totalModels', 'processedModels', 'eligibleModels', 'repairRows', 'progressPercent'];
  const columnNames = {
    totalModels: 'total_models',
    processedModels: 'processed_models',
    eligibleModels: 'eligible_models',
    repairRows: 'repair_rows',
    progressPercent: 'progress_percent',
  };

  for (const key of textFields) {
    if (Object.hasOwn(fields, key)) assignments.push(`${key} = ${quote(fields[key])}`);
  }
  for (const key of numberFields) {
    if (Object.hasOwn(fields, key) && Number.isFinite(Number(fields[key]))) {
      assignments.push(`${columnNames[key]} = ${Number(fields[key])}`);
    }
  }
  if (fields.startedNow) assignments.push('started_at = now()', 'completed_at = null');
  if (fields.completedNow) assignments.push('completed_at = now()');
  assignments.push('updated_at = now()');

  fs.mkdirSync(outputDir, { recursive: true });
  const sqlPath = path.join(outputDir, `.status-${process.pid}-${Date.now()}.sql`);
  fs.writeFileSync(sqlPath, `update public.crazyparts_update_status set ${assignments.join(', ')} where family = ${quote(family)};`, 'utf8');
  try {
    const executable = process.platform === 'win32' ? 'supabase.exe' : 'supabase';
    const result = spawnSync(executable, ['db', 'query', '--linked', '--file', sqlPath, '--output', 'json'], {
      cwd: projectRoot,
      encoding: 'utf8',
      windowsHide: true,
      timeout: 30000,
    });
    if (result.status !== 0) {
      console.warn(`Could not publish Crazy Parts progress: ${result.stderr || result.stdout || 'unknown error'}`);
      return false;
    }
    return true;
  } finally {
    fs.rmSync(sqlPath, { force: true });
  }
}
