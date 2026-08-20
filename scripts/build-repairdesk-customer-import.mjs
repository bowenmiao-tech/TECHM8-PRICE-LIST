import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { FileBlob, SpreadsheetFile } from '@oai/artifact-tool';

const workspaceRoot = 'D:/program/TECHM8 PRICE LIST';
const sourcePath = process.argv[2] ?? 'E:/ontimefile/Customers-2026-08-20-23-08-12.xlsx';
const outputDir = process.argv[3] ?? path.join(workspaceRoot, '.codex-temp', 'repairdesk-customer-import');
const batchSize = Math.max(100, Math.min(Number(process.argv[4]) || 400, 1000));

const textValue = (value) => String(value ?? '').replace(/\s+/g, ' ').trim();
const keyText = (value) => textValue(value)
  .normalize('NFKD')
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, ' ')
  .trim();
const emailValue = (value) => textValue(value).toLowerCase();
const numberValue = (value) => {
  const parsed = Number(String(value ?? '').replace(/[$,]/g, '').trim());
  return Number.isFinite(parsed) ? parsed : 0;
};
const integerValue = (value) => Math.max(0, Math.trunc(numberValue(value)));
const normalizePhone = (value) => {
  let digits = textValue(value).replace(/\D/g, '');
  if (digits.startsWith('61') && digits.length === 11) digits = `0${digits.slice(2)}`;
  return digits;
};
const sqlJson = (value) => `'${JSON.stringify(value).replace(/'/g, "''")}'::jsonb`;
const hashCode = (value) => crypto.createHash('sha256').update(value).digest('hex').slice(0, 20).toUpperCase();

const storeCodes = new Map([
  ['techm8 toowong', 'toowong'],
  ['techm8 park ridge', 'parkridge'],
  ['techm8 fairfield', 'fairfield'],
  ['techm8 north lakes', 'northlakes'],
]);

const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(sourcePath));
const sheet = workbook.worksheets.getItemAt(0);
const values = sheet.getUsedRange(true).values;
const headers = values[0].map(textValue);
const column = Object.fromEntries(headers.map((header, index) => [header, index]));
const requiredHeaders = [
  'Code', 'FirstName', 'LastName', 'Email', 'Phone', 'Mobile', 'Address1', 'Address2',
  'Postcode', 'City', 'State', 'Country', 'Store Name', 'Organization', 'DrivingLicence',
  'Refered By', 'Contact person', 'Ticket', 'Tickets Amount', 'Amount Receivables', 'Customer Group',
];
for (const header of requiredHeaders) {
  if (!(header in column)) throw new Error(`Missing customer column: ${header}`);
}

const sourceByKey = new Map();
for (const row of values.slice(1)) {
  const sourceCode = textValue(row[column.Code]);
  const sourceStoreName = textValue(row[column['Store Name']]);
  if (!sourceCode) continue;
  const sourceKey = `${keyText(sourceStoreName)}|${sourceCode}`;
  const sourcePayload = Object.fromEntries(headers.map((header, index) => [header, row[index] ?? '']));
  const identitySerialized = JSON.stringify(Object.fromEntries(
    headers
      .filter((header) => !['Ticket', 'Tickets Amount', 'Amount Receivables'].includes(header))
      .map((header) => [header, sourcePayload[header]])
  ));

  const firstName = textValue(row[column.FirstName]);
  const lastName = textValue(row[column.LastName]);
  const email = emailValue(row[column.Email]);
  const mobile = normalizePhone(row[column.Mobile]);
  const landline = normalizePhone(row[column.Phone]);
  const phone = mobile || landline;
  const fullNameKey = keyText(`${firstName} ${lastName}`);
  const canonicalKey = phone && fullNameKey
    ? `phone:${phone}|name:${fullNameKey}`
    : email && fullNameKey
      ? `email:${email}|name:${fullNameKey}`
      : `source:${sourceKey}`;

  const sourceRecord = {
    identity_serialized: identitySerialized,
    canonicalKey,
    source_code: sourceCode,
    source_store_name: sourceStoreName,
    store_code: storeCodes.get(keyText(sourceStoreName)) ?? '',
    first_name: firstName,
    last_name: lastName,
    company: textValue(row[column.Organization]),
    phone,
    normalized_phone: phone,
    alert_number: landline && landline !== phone ? landline : '',
    email,
    customer_group: textValue(row[column['Customer Group']]) || 'Regular Customer',
    address1: textValue(row[column.Address1]),
    address2: textValue(row[column.Address2]),
    postcode: textValue(row[column.Postcode]),
    city: textValue(row[column.City]),
    state: textValue(row[column.State]),
    country: textValue(row[column.Country]),
    driving_licence: textValue(row[column.DrivingLicence]),
    referred_by: textValue(row[column['Refered By']]),
    contact_person: textValue(row[column['Contact person']]),
    legacy_ticket_count: integerValue(row[column.Ticket]),
    legacy_tickets_amount: numberValue(row[column['Tickets Amount']]),
    legacy_amount_receivable: numberValue(row[column['Amount Receivables']]),
    source_payload: sourcePayload,
  };
  const existingSource = sourceByKey.get(sourceKey);
  if (existingSource) {
    if (existingSource.identity_serialized !== identitySerialized) {
      throw new Error(`Conflicting duplicate customer source: ${sourceStoreName} / ${sourceCode}`);
    }
    const existingHistory = existingSource.legacy_ticket_count + existingSource.legacy_tickets_amount;
    const incomingHistory = sourceRecord.legacy_ticket_count + sourceRecord.legacy_tickets_amount;
    if (incomingHistory > existingHistory) sourceByKey.set(sourceKey, sourceRecord);
    continue;
  }
  sourceByKey.set(sourceKey, sourceRecord);
}

const sources = [...sourceByKey.values()];
const canonicalGroups = new Map();
for (const source of sources) {
  if (!canonicalGroups.has(source.canonicalKey)) canonicalGroups.set(source.canonicalKey, []);
  canonicalGroups.get(source.canonicalKey).push(source);
}

const richness = (record) => [
  record.phone, record.email, record.company, record.address1, record.address2, record.city,
  record.postcode, record.state, record.country, record.driving_licence, record.contact_person,
].filter(Boolean).length;

const customers = [...canonicalGroups.entries()].map(([canonicalKey, records]) => {
  const sorted = [...records].sort((left, right) => richness(right) - richness(left));
  const representative = sorted[0];
  return {
    customer_code: `RD-CUS-${hashCode(canonicalKey)}`,
    store_code: representative.store_code,
    source_system: 'repairdesk',
    source_store_name: representative.source_store_name,
    source_customer_code: representative.source_code,
    first_name: representative.first_name,
    last_name: representative.last_name,
    company: representative.company,
    phone: representative.phone,
    normalized_phone: representative.normalized_phone,
    alert_number: representative.alert_number,
    email: representative.email,
    customer_group: representative.customer_group,
    address1: representative.address1,
    address2: representative.address2,
    postcode: representative.postcode,
    city: representative.city,
    state: representative.state,
    country: representative.country,
    driving_licence: representative.driving_licence,
    referred_by: representative.referred_by,
    contact_person: representative.contact_person,
    legacy_ticket_count: records.reduce((sum, record) => sum + record.legacy_ticket_count, 0),
    legacy_tickets_amount: records.reduce((sum, record) => sum + record.legacy_tickets_amount, 0),
    legacy_amount_receivable: records.reduce((sum, record) => sum + record.legacy_amount_receivable, 0),
  };
});

const customerCodeByCanonicalKey = new Map(customers.map((customer, index) => [
  [...canonicalGroups.keys()][index],
  customer.customer_code,
]));
const sourceRows = sources.map((source) => ({
  customer_code: customerCodeByCanonicalKey.get(source.canonicalKey),
  source_system: 'repairdesk',
  source_store_name: source.source_store_name,
  source_customer_code: source.source_code,
  source_payload: source.source_payload,
}));

await fs.rm(outputDir, { recursive: true, force: true });
await fs.mkdir(outputDir, { recursive: true });

const chunks = (items) => Array.from({ length: Math.ceil(items.length / batchSize) }, (_, index) => items.slice(index * batchSize, (index + 1) * batchSize));
const customerBatches = chunks(customers);
for (let index = 0; index < customerBatches.length; index += 1) {
  const payload = customerBatches[index];
  const sql = `with payload as (
  select * from jsonb_to_recordset(${sqlJson(payload)}) as item(
    customer_code text, store_code text, source_system text, source_store_name text, source_customer_code text,
    first_name text, last_name text, company text, phone text, normalized_phone text, alert_number text,
    email text, customer_group text, address1 text, address2 text, postcode text, city text, state text,
    country text, driving_licence text, referred_by text, contact_person text, legacy_ticket_count integer,
    legacy_tickets_amount numeric, legacy_amount_receivable numeric
  )
)
insert into public.pos_customers (
  customer_code, store_id, source_system, source_store_name, source_customer_code, first_name, last_name,
  company, phone, normalized_phone, alert_number, email, customer_group, address1, address2, postcode,
  city, state, country, driving_licence, referred_by, contact_person, legacy_ticket_count,
  legacy_tickets_amount, legacy_amount_receivable, created_by, updated_by, active
)
select
  payload.customer_code, store_location.id, payload.source_system, payload.source_store_name, payload.source_customer_code,
  payload.first_name, payload.last_name, payload.company, payload.phone, payload.normalized_phone, payload.alert_number,
  payload.email, payload.customer_group, payload.address1, payload.address2, payload.postcode, payload.city, payload.state,
  payload.country, payload.driving_licence, payload.referred_by, payload.contact_person, payload.legacy_ticket_count,
  payload.legacy_tickets_amount, payload.legacy_amount_receivable, 'RepairDesk import', 'RepairDesk import', true
from payload
left join public.store_locations store_location on store_location.store_code = payload.store_code
on conflict (customer_code) do update set
  store_id = excluded.store_id, source_system = excluded.source_system, source_store_name = excluded.source_store_name,
  source_customer_code = excluded.source_customer_code, first_name = excluded.first_name, last_name = excluded.last_name,
  company = excluded.company, phone = excluded.phone, normalized_phone = excluded.normalized_phone,
  alert_number = excluded.alert_number, email = excluded.email, customer_group = excluded.customer_group,
  address1 = excluded.address1, address2 = excluded.address2, postcode = excluded.postcode, city = excluded.city,
  state = excluded.state, country = excluded.country, driving_licence = excluded.driving_licence,
  referred_by = excluded.referred_by, contact_person = excluded.contact_person,
  legacy_ticket_count = excluded.legacy_ticket_count, legacy_tickets_amount = excluded.legacy_tickets_amount,
  legacy_amount_receivable = excluded.legacy_amount_receivable, updated_by = excluded.updated_by,
  active = true, updated_at = now();
`;
  await fs.writeFile(path.join(outputDir, `customers-${String(index + 1).padStart(3, '0')}.sql`), sql);
}

const sourceBatches = chunks(sourceRows);
for (let index = 0; index < sourceBatches.length; index += 1) {
  const payload = sourceBatches[index];
  const sql = `with payload as (
  select * from jsonb_to_recordset(${sqlJson(payload)}) as item(
    customer_code text, source_system text, source_store_name text, source_customer_code text, source_payload jsonb
  )
)
insert into public.pos_customer_sources (customer_id, source_system, source_store_name, source_customer_code, source_payload)
select customer.id, payload.source_system, payload.source_store_name, payload.source_customer_code, payload.source_payload
from payload
join public.pos_customers customer on customer.customer_code = payload.customer_code
on conflict (source_system, source_store_name, source_customer_code) do update set
  customer_id = excluded.customer_id, source_payload = excluded.source_payload, imported_at = now();
`;
  await fs.writeFile(path.join(outputDir, `sources-${String(index + 1).padStart(3, '0')}.sql`), sql);
}

const sourceCounts = Object.fromEntries([...sources.reduce((counts, source) => {
  counts.set(source.source_store_name, (counts.get(source.source_store_name) || 0) + 1);
  return counts;
}, new Map()).entries()].sort(([left], [right]) => left.localeCompare(right)));
const summary = {
  source_file: sourcePath,
  worksheet: sheet.name,
  source_rows: values.length - 1,
  unique_source_rows: sources.length,
  duplicate_source_rows_removed: values.length - 1 - sources.length,
  canonical_customers: customers.length,
  canonical_merges: sources.length - customers.length,
  source_store_counts: sourceCounts,
  customer_batches: customerBatches.length,
  source_batches: sourceBatches.length,
  batch_size: batchSize,
};
await fs.writeFile(path.join(outputDir, 'manifest.json'), `${JSON.stringify(summary, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
