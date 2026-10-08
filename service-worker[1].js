// Turnex — Service Worker
// Solo cachea el "cascarón" de la app (HTML, íconos, manifiesto) para que
// abra más rápido y pueda instalarse. Nunca cachea las llamadas a Supabase
// ni a librerías externas (CDN) — esas siempre van directo a la red para
// que los datos nunca queden desactualizados.

const CACHE_NAME = 'turnex-shell-v1';
const APP_SHELL = [
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './icon-maskable-512.png',
  './apple-touch-icon.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)).catch(()=>{})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter(n => n !== CACHE_NAME).map(n => caches.delete(n)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Nunca interceptar llamadas a Supabase ni a dominios externos (CDN, APIs):
  // siempre deben ir a la red para no servir datos ni librerías obsoletas.
  if (url.origin !== self.location.origin) {
    return;
  }

  // Para el propio origen: intenta la red primero (datos frescos del archivo),
  // y si no hay conexión, cae al caché del cascarón.
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy)).catch(()=>{});
        return response;
      })
      .catch(() => caches.match(event.request).then((cached) => cached || caches.match('./index.html')))
  );
});
