const DB_NAME = 'splatfire';
const STORE = 'tours';
const CURRENT_KEY = 'current';

export function uid() {
  return Math.random().toString(36).slice(2, 10);
}

function openDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function withStore(mode, fn) {
  const db = await openDb();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, mode);
      const req = fn(tx.objectStore(STORE));
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  } finally {
    db.close();
  }
}

/** Persist the working tour (Blobs survive the structured clone). */
export function saveTour(tour) {
  return withStore('readwrite', (s) => s.put(tour, CURRENT_KEY));
}

export function loadTour() {
  return withStore('readonly', (s) => s.get(CURRENT_KEY));
}

export function clearTour() {
  return withStore('readwrite', (s) => s.delete(CURRENT_KEY));
}

function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(r.result);
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}

/** Serialize a tour (images inlined as data URLs) and download it. */
export async function exportTour(tour) {
  const scenes = await Promise.all(
    tour.scenes.map(async (s) => ({ ...s, image: await blobToDataUrl(s.image) })),
  );
  const json = JSON.stringify({ format: 'splatfire-tour', version: 1, ...tour, scenes });
  const blob = new Blob([json], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `${(tour.name || 'tour').replace(/[^\w\- ]+/g, '').trim() || 'tour'}.json`;
  a.click();
  URL.revokeObjectURL(a.href);
}

/** Parse a previously exported tour file back into a working tour. */
export async function importTour(file) {
  const data = JSON.parse(await file.text());
  if (data.format !== 'splatfire-tour' || !Array.isArray(data.scenes)) {
    throw new Error('Not a Splatfire tour file');
  }
  const scenes = await Promise.all(
    data.scenes.map(async (s) => ({ ...s, image: await (await fetch(s.image)).blob() })),
  );
  return {
    id: data.id || uid(),
    name: data.name || 'Imported tour',
    startSceneId: data.startSceneId ?? scenes[0]?.id ?? null,
    scenes,
  };
}
