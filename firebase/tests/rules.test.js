const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { initializeTestEnvironment, assertFails, assertSucceeds } = require('@firebase/rules-unit-testing');
const { doc, getDoc, setDoc, deleteDoc, updateDoc, collection, getDocs } = require('firebase/firestore');
const { ref, getBytes, uploadBytes } = require('firebase/storage');

let env;
before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-cascade',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '../firestore.rules'), 'utf8'), host: '127.0.0.1', port: 8085 },
    storage: { rules: fs.readFileSync(path.join(__dirname, '../storage.rules'), 'utf8'), host: '127.0.0.1', port: 9199 },
  });
});
after(async () => env && env.cleanup());
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'users/alice'), { currency: 'INR' });
    await setDoc(doc(db, 'users/alice/financial_records/r1'), { name: 'Rent', amount_minor: 1800000 });
    await setDoc(doc(db, 'users/alice/audit_events/a1'), { action: 'x' });
    await setDoc(doc(db, 'users/bob/financial_records/r2'), { name: 'Bob rent' });
    await uploadBytes(ref(ctx.storage(), 'users/alice/documents/d1/original'), new Uint8Array([37, 80, 68, 70]));
  });
});

const as = (uid) => env.authenticatedContext(uid);

test('owner can read own profile and records', async () => {
  const db = as('alice').firestore();
  await assertSucceeds(getDoc(doc(db, 'users/alice')));
  await assertSucceeds(getDoc(doc(db, 'users/alice/financial_records/r1')));
  await assertSucceeds(getDocs(collection(db, 'users/alice/financial_records')));
});

test('user cannot read another user records', async () => {
  const db = as('alice').firestore();
  await assertFails(getDoc(doc(db, 'users/bob/financial_records/r2')));
  await assertFails(getDocs(collection(db, 'users/bob/financial_records')));
  await assertFails(getDoc(doc(db, 'users/bob')));
});

test('user cannot overwrite or delete another user documents', async () => {
  const db = as('alice').firestore();
  await assertFails(setDoc(doc(db, 'users/bob/financial_records/r2'), { name: 'pwned' }));
  await assertFails(updateDoc(doc(db, 'users/bob/financial_records/r2'), { name: 'pwned' }));
  await assertFails(deleteDoc(doc(db, 'users/bob/financial_records/r2')));
});

test('clients cannot write even their own financial data (server is the only writer)', async () => {
  const db = as('alice').firestore();
  await assertFails(setDoc(doc(db, 'users/alice/financial_records/new'), { amount_minor: 1 }));
  await assertFails(updateDoc(doc(db, 'users/alice/financial_records/r1'), { amount_minor: 1 }));
  await assertFails(deleteDoc(doc(db, 'users/alice/financial_records/r1')));
  await assertFails(setDoc(doc(db, 'users/alice'), { currency: 'USD' }));
});

test('audit events are not readable by clients', async () => {
  await assertFails(getDoc(doc(as('alice').firestore(), 'users/alice/audit_events/a1')));
});

test('unauthenticated access is denied everywhere', async () => {
  const db = env.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(db, 'users/alice')));
  await assertFails(getDoc(doc(db, 'users/alice/financial_records/r1')));
  await assertFails(setDoc(doc(db, 'users/alice/financial_records/x'), { a: 1 }));
  await assertFails(getDoc(doc(db, 'other/anything')));
});

test('deleted records are simply absent (no stale access after delete)', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => deleteDoc(doc(ctx.firestore(), 'users/alice/financial_records/r1')));
  const snap = await assertSucceeds(getDoc(doc(as('alice').firestore(), 'users/alice/financial_records/r1')));
  assert.strictEqual(snap.exists(), false);
});

test('storage: owner reads own document; others and anonymous cannot; nobody writes from clients', async () => {
  const p = 'users/alice/documents/d1/original';
  await assertSucceeds(getBytes(ref(as('alice').storage(), p)));
  await assertFails(getBytes(ref(as('bob').storage(), p)));
  await assertFails(getBytes(ref(env.unauthenticatedContext().storage(), p)));
  await assertFails(uploadBytes(ref(as('alice').storage(), 'users/alice/documents/d2/original'), new Uint8Array([1])));
  await assertFails(uploadBytes(ref(as('bob').storage(), 'users/alice/documents/d3/original'), new Uint8Array([1])));
  await assertFails(uploadBytes(ref(as('alice').storage(), 'public/x'), new Uint8Array([1])));
});

