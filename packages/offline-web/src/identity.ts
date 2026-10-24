import { Identity } from "@offline/core";

const DB = "offline-web";
const STORE = "identity";
const KEY = "bundle";

export type StoredBundle = {
  noiseSecret: number[];
  signingSecret: number[];
  nickname: string;
};

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function loadOrCreateIdentity(
  nicknameHint?: string,
): Promise<{ identity: Identity; nickname: string; created: boolean }> {
  const existing = await readBundle();
  if (existing) {
    const identity = Identity.fromSecrets(
      new Uint8Array(existing.noiseSecret),
      new Uint8Array(existing.signingSecret),
    );
    return {
      identity,
      nickname: existing.nickname || nicknameHint || identity.peerId.slice(0, 8),
      created: false,
    };
  }
  const identity = new Identity();
  const nickname = nicknameHint?.trim() || identity.peerId.slice(0, 8);
  const secrets = identity.exportSecrets();
  await writeBundle({
    noiseSecret: [...secrets.noise_secret],
    signingSecret: [...secrets.signing_secret],
    nickname,
  });
  return { identity, nickname, created: true };
}

export async function saveNickname(nickname: string): Promise<void> {
  const existing = await readBundle();
  if (!existing) return;
  existing.nickname = nickname;
  await writeBundle(existing);
}

export async function regenerateIdentity(
  nicknameHint?: string,
): Promise<{ identity: Identity; nickname: string }> {
  await clearBundle();
  return loadOrCreateIdentity(nicknameHint);
}

export async function getStoredSecrets(): Promise<{
  noiseSecret: Uint8Array;
  signingSecret: Uint8Array;
  nickname: string;
} | null> {
  const b = await readBundle();
  if (!b) return null;
  return {
    noiseSecret: new Uint8Array(b.noiseSecret),
    signingSecret: new Uint8Array(b.signingSecret),
    nickname: b.nickname,
  };
}

async function readBundle(): Promise<StoredBundle | null> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readonly");
    const req = tx.objectStore(STORE).get(KEY);
    req.onsuccess = () => resolve((req.result as StoredBundle) ?? null);
    req.onerror = () => reject(req.error);
  });
}

async function writeBundle(bundle: StoredBundle): Promise<void> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).put(bundle, KEY);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function clearBundle(): Promise<void> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).delete(KEY);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}
