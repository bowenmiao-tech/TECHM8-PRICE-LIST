import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { openCheckpoint } from './crazyparts-checkpoint.mjs';

const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'techm8-price-checkpoint-'));
try {
  const model = { name: 'A71 5G', family: 'A Series', href: '/collection/a71' };
  const result = { ...model, heading: 'A71 5G', validated: true, products: [{ name: 'Battery', price: 10.6 }] };
  const first = await openCheckpoint(directory, 'test-account-and-code-version', [model]);
  await first.put(result);
  const resumed = await openCheckpoint(directory, 'test-account-and-code-version', [model]);
  assert.deepEqual(resumed.get(model.href), result);
  const checkpointFile = path.join(directory, (await fs.readdir(directory))[0]);
  const beforeResume = await fs.readFile(checkpointFile, 'utf8');
  await resumed.put(resumed.get(model.href));
  assert.equal(await fs.readFile(checkpointFile, 'utf8'), beforeResume);
  assert.equal((await openCheckpoint(directory, 'different-account', [model])).get(model.href), undefined);
  assert.equal((await openCheckpoint(directory, 'test-account-and-code-version', [], 1000)).get(model.href), undefined);
  assert.equal((await openCheckpoint(directory, 'test-account-and-code-version', [model], -1)).get(model.href), undefined);
  await resumed.clear();
  assert.equal((await openCheckpoint(directory, 'test-account-and-code-version', [model])).get(model.href), undefined);
  console.log('PASS: verified checkpoint resume, account isolation, catalogue changes, expiry, and cleanup.');
} finally {
  // Remove only files in this test's newly allocated temporary directory.
  for (const entry of await fs.readdir(directory)) await fs.unlink(path.join(directory, entry));
  await fs.rmdir(directory);
}
