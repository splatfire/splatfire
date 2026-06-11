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

/** Backfill fields that tours saved by older app versions may lack. */
function normalizeTour(tour) {
  if (!tour || !Array.isArray(tour.scenes)) return tour;
  for (const scene of tour.scenes) {
    scene.hotspots ??= [];
    scene.measurements ??= [];
    scene.view ??= { lon: 0, lat: 0 };
  }
  return tour;
}

/** Persist the working tour (Blobs survive the structured clone). */
export function saveTour(tour) {
  return withStore('readwrite', (s) => s.put(tour, CURRENT_KEY));
}

export async function loadTour() {
  return normalizeTour(await withStore('readonly', (s) => s.get(CURRENT_KEY)));
}

export function clearTour() {
  return withStore('readwrite', (s) => s.delete(CURRENT_KEY));
}

export function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(r.result);
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}

export function downloadBlob(blob, filename) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  a.click();
  URL.revokeObjectURL(a.href);
}

export function tourFilename(name, ext) {
  return `${(name || 'tour').replace(/[^\w\- ]+/g, '').trim() || 'tour'}.${ext}`;
}

/** Serialize a tour (images inlined as data URLs) and download it. */
export async function exportTour(tour) {
  const scenes = await Promise.all(
    tour.scenes.map(async (s) => ({ ...s, image: await blobToDataUrl(s.image) })),
  );
  const json = JSON.stringify({ format: 'splatfire-tour', version: 1, ...tour, scenes });
  downloadBlob(new Blob([json], { type: 'application/json' }), tourFilename(tour.name, 'json'));
}

/** Parse a previously exported tour file back into a working tour. */
export async function importTour(file) {
  const data = JSON.parse(await file.text());
  if (data.format !== 'splatfire-tour' || !Array.isArray(data.scenes)) {
    throw new Error('Not a Splatfire tour file');
  }
  const scenes = await Promise.all(
    data.scenes.map(async (s) => {
      if (typeof s.image !== 'string' || !s.image.startsWith('data:')) {
        throw new Error(`Room "${s.name ?? '?'}" has no image data`);
      }
      return { ...s, image: await (await fetch(s.image)).blob() };
    }),
  );
  return normalizeTour({
    id: data.id || uid(),
    name: data.name || 'Imported tour',
    startSceneId: data.startSceneId ?? scenes[0]?.id ?? null,
    scenes,
  });
}
