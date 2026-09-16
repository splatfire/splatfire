/**
 * Offline cache. The app shell is precached on install so the page opens in a
 * cellar with no signal; everything else is served cache-first and refreshed
 * in the background when there happens to be a connection.
 *
 * Bump CACHE when shipping changed files — old caches are dropped on activate.
 */

const CACHE = 'qrlog-v2';
const SHELL = [
  './',
  './index.html',
  './css/app.css',
  './icon.svg',
  './manifest.webmanifest',
  './js/app.js',
  './js/store.js',
  './js/qr.js',
  './js/scanner.js',
  './js/stt.js',
  './js/parse.js',
  './vendor/qrcode.js',
  './vendor/jsQR.js',
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  event.respondWith(
    caches.match(event.request).then((hit) => {
      const network = fetch(event.request)
        .then((response) => {
          if (response.ok && new URL(event.request.url).origin === self.location.origin) {
            const copy = response.clone();
            caches.open(CACHE).then((cache) => cache.put(event.request, copy));
          }
          return response;
        })
        .catch(() => hit);
      return hit ?? network;
    })
  );
});
