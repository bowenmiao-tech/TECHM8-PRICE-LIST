import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { assertSupplierPage } from './crazyparts-page-validation.mjs';

export async function openCheckpoint(directory, identity, models, maxAgeMs = 6 * 60 * 60 * 1000) {
  const key = createHash('sha256').update(identity).digest('hex');
  const file = path.join(directory, `${key}.json`);
  const allowed = new Map(models.map((model) => [model.href, model]));
  const saved = new Map();
  try {
    const data = JSON.parse(await fs.readFile(file, 'utf8'));
    for (const entry of data.entries || []) {
      const model = allowed.get(entry.result?.href);
      const age = Date.now() - entry.savedAt;
      if (!model || age < 0 || age > maxAgeMs || !entry.result.validated
        || model.family !== entry.result.family || !Array.isArray(entry.result.products)) continue;
      assertSupplierPage({ heading: entry.result.heading });
      saved.set(model.href, entry);
    }
  } catch (error) {
    if (error.code !== 'ENOENT') console.warn(`Ignoring unreadable price checkpoint: ${error.message}`);
  }
  let writes = Promise.resolve();
  return {
    get(href) { return saved.get(href)?.result; },
    put(result) {
      // Reusing a capture must not renew its six-hour freshness window.
      if (saved.get(result.href)?.result === result) return writes;
      saved.set(result.href, { savedAt: Date.now(), result });
      // Serial writes also support multiple model workers in the same run.
      const snapshot = JSON.stringify({ entries: [...saved.values()] });
      writes = writes.then(async () => {
        await fs.mkdir(directory, { recursive: true });
        const temporary = `${file}.${process.pid}.tmp`;
        await fs.writeFile(temporary, snapshot, 'utf8');
        await fs.rename(temporary, file);
      });
      return writes;
    },
    async clear() {
      await writes;
      await fs.rm(file, { force: true });
    },
  };
}
