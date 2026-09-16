/**
 * Local-only persistence for the QR logbook.
 *
 * Everything lives in IndexedDB on the device that wrote it: assets
 * (Anlagen), their logbook entries, attached photos and the app settings.
 * There is no server, so sharing between devices goes through export/import.
 */

const DB_NAME = 'qrlog';
const DB_VERSION = 1;

/**
 * Short, hard-to-guess id. It ends up inside the QR code and in the URL, so
 * it has to be random rather than sequential: anyone who can read one label
 * must not be able to walk to the next asset by incrementing a number.
 * 10 chars of Crockford-style base32 ~= 50 bits.
 */
const ID_ALPHABET = '0123456789abcdefghjkmnpqrstvwxyz';
export function uid(len = 10) {
  const bytes = new Uint8Array(len);
  crypto.getRandomValues(bytes);
  let out = '';
  for (const b of bytes) out += ID_ALPHABET[b % ID_ALPHABET.length];
  return out;
}

function openDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains('assets')) {
        db.createObjectStore('assets', { keyPath: 'id' });
      }
      if (!db.objectStoreNames.contains('entries')) {
        const entries = db.createObjectStore('entries', { keyPath: 'id' });
        entries.createIndex('assetId', 'assetId');
      }
      if (!db.objectStoreNames.contains('settings')) {
        db.createObjectStore('settings');
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function withStore(name, mode, fn) {
  return openDb().then(
    (db) =>
      new Promise((resolve, reject) => {
        const tx = db.transaction(name, mode);
        const req = fn(tx.objectStore(name));
        tx.oncomplete = () => db.close();
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      })
  );
}

/* ---------- Assets (Anlagen) ---------- */

/** Backfill fields that records written by older versions may lack. */
function normalizeAsset(asset) {
  if (!asset) return asset;
  asset.photos ??= [];
  asset.notes ??= '';
  return asset;
}

export function newAsset(id = uid()) {
  const now = new Date().toISOString();
  return {
    id,
    name: '',
    type: '',
    location: '',
    manufacturer: '',
    model: '',
    serial: '',
    installedOn: '',
    intervalMonths: 12,
    notes: '',
    photos: [],
    createdAt: now,
    updatedAt: now,
  };
}

export function saveAsset(asset) {
  asset.updatedAt = new Date().toISOString();
  return withStore('assets', 'readwrite', (s) => s.put(asset));
}

export async function getAsset(id) {
  return normalizeAsset(await withStore('assets', 'readonly', (s) => s.get(id)));
}

export async function allAssets() {
  const assets = await withStore('assets', 'readonly', (s) => s.getAll());
  assets.forEach(normalizeAsset);
  assets.sort((a, b) => (a.name || '').localeCompare(b.name || '', 'de'));
  return assets;
}

export async function deleteAsset(id) {
  for (const entry of await entriesFor(id)) await deleteEntry(entry.id);
  return withStore('assets', 'readwrite', (s) => s.delete(id));
}

/* ---------- Logbook entries ---------- */

export function newEntry(assetId) {
  return {
    id: uid(12),
    assetId,
    date: new Date().toISOString().slice(0, 10),
    technician: '',
    company: '',
    kind: 'Wartung',
    work: '',
    findings: '',
    parts: '',
    nextService: '',
    photos: [],
    createdAt: new Date().toISOString(),
  };
}

export function saveEntry(entry) {
  return withStore('entries', 'readwrite', (s) => s.put(entry));
}

export function getEntry(id) {
  return withStore('entries', 'readonly', (s) => s.get(id));
}

export function deleteEntry(id) {
  return withStore('entries', 'readwrite', (s) => s.delete(id));
}

/** Entries for one asset, newest first — that is the order a technician reads. */
export async function entriesFor(assetId) {
  const db = await openDb();
  try {
    const entries = await new Promise((resolve, reject) => {
      const req = db
        .transaction('entries', 'readonly')
        .objectStore('entries')
        .index('assetId')
        .getAll(assetId);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
    return entries.sort((a, b) => (b.date + b.createdAt).localeCompare(a.date + a.createdAt));
  } finally {
    db.close();
  }
}

export async function allEntries() {
  return withStore('entries', 'readonly', (s) => s.getAll());
}

/** Most recent entry per asset, keyed by asset id — used for the list badges. */
export async function latestEntryByAsset() {
  const map = new Map();
  for (const entry of await allEntries()) {
    const prev = map.get(entry.assetId);
    if (!prev || entry.date > prev.date) map.set(entry.assetId, entry);
  }
  return map;
}

/* ---------- Settings ---------- */

const SETTINGS_DEFAULTS = {
  technician: '',
  company: '',
  lang: 'de-CH',
  offlineDictationOnly: true,
};

export async function getSettings() {
  const stored = await withStore('settings', 'readonly', (s) => s.get('settings'));
  return { ...SETTINGS_DEFAULTS, ...(stored || {}) };
}

export function saveSettings(settings) {
  return withStore('settings', 'readwrite', (s) => s.put(settings, 'settings'));
}

/* ---------- Photos ---------- */

export function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(r.result);
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}

export async function dataUrlToBlob(dataUrl) {
  return (await fetch(dataUrl)).blob();
}

/**
 * Shrink a camera photo before storing it. Full-resolution phone photos are
 * 3-5 MB each and a busy asset collects dozens; at 1600px the nameplate is
 * still readable and the whole logbook still fits in an export file.
 */
export async function shrinkImage(file, maxSide = 1600, quality = 0.8) {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, maxSide / Math.max(bitmap.width, bitmap.height));
  const w = Math.round(bitmap.width * scale);
  const h = Math.round(bitmap.height * scale);
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  canvas.getContext('2d').drawImage(bitmap, 0, 0, w, h);
  bitmap.close?.();
  const blob = await new Promise((res) => canvas.toBlob(res, 'image/jpeg', quality));
  return blob ?? file;
}

/* ---------- Export / Import ---------- */

async function photosOut(photos) {
  return Promise.all(
    photos.map(async (p) => ({ ...p, blob: undefined, dataUrl: await blobToDataUrl(p.blob) }))
  );
}

async function photosIn(photos) {
  return Promise.all(
    (photos || []).map(async (p) => ({
      id: p.id,
      name: p.name,
      blob: await dataUrlToBlob(p.dataUrl),
    }))
  );
}

/** The whole device's data as one JSON blob, photos inlined as data URLs. */
export async function exportAll() {
  const assets = await allAssets();
  const entries = await allEntries();
  return {
    format: 'qrlog',
    version: 1,
    exportedAt: new Date().toISOString(),
    assets: await Promise.all(
      assets.map(async (a) => ({ ...a, photos: await photosOut(a.photos ?? []) }))
    ),
    entries: await Promise.all(
      entries.map(async (e) => ({ ...e, photos: await photosOut(e.photos ?? []) }))
    ),
  };
}

/**
 * Merge an exported file into this device. Same id wins by `updatedAt` for
 * assets; entries are immutable records, so an id that already exists is kept
 * as-is rather than duplicated.
 */
export async function importAll(data) {
  if (data?.format !== 'qrlog') throw new Error('Keine QR-Logbuch-Datei.');
  let added = 0;
  let updated = 0;
  for (const raw of data.assets ?? []) {
    const incoming = { ...raw, photos: await photosIn(raw.photos) };
    const existing = await getAsset(incoming.id);
    if (!existing) {
      await saveAsset(incoming);
      added++;
    } else if ((incoming.updatedAt ?? '') > (existing.updatedAt ?? '')) {
      await saveAsset(incoming);
      updated++;
    }
  }
  let entriesAdded = 0;
  for (const raw of data.entries ?? []) {
    if (await getEntry(raw.id)) continue;
    await saveEntry({ ...raw, photos: await photosIn(raw.photos) });
    entriesAdded++;
  }
  return { added, updated, entriesAdded };
}
