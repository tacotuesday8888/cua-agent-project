import { readFileSync } from 'node:fs';
import { afterAll, beforeAll, describe, it } from 'vitest';
import { assertFails, initializeTestEnvironment, type RulesTestEnvironment } from '@firebase/rules-unit-testing';

const runRulesTests = process.env.FIREBASE_RULES_TEST === '1';
const describeRules = runRulesTests ? describe : describe.skip;

function rootFile(path: string): string {
  return readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');
}

describeRules('Firebase direct client rules', () => {
  let testEnv: RulesTestEnvironment;

  beforeAll(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: 'demo-macautopilot-rules',
      firestore: { rules: rootFile('firestore.rules') },
      database: { rules: rootFile('database.rules.json') },
      storage: { rules: rootFile('storage.rules') },
    });
  });

  afterAll(async () => {
    await testEnv?.cleanup();
  });

  for (const [label, context] of [
    ['unauthenticated', () => testEnv.unauthenticatedContext()],
    ['authenticated', () => testEnv.authenticatedContext('user-123')],
  ] as const) {
    it(`denies ${label} Firestore reads and writes`, async () => {
      const firestore = context().firestore();
      const doc = firestore.doc('usage/user-123/months/2026-06');

      await assertFails(doc.get());
      await assertFails(doc.set({ tokens: 1 }));
    });

    it(`denies ${label} Realtime Database reads and writes`, async () => {
      const database = context().database();
      const ref = database.ref('usage/user-123');

      await assertFails(ref.get());
      await assertFails(ref.set({ tokens: 1 }));
    });

    it(`denies ${label} Storage reads and writes`, async () => {
      const storage = context().storage();
      const ref = storage.ref('artifacts/user-123/screenshot.png');

      await assertFails(ref.getDownloadURL());
      await assertFails(ref.putString('never store screenshots here'));
    });
  }
});
