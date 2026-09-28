// Yalnız statik uygulama kabuğu önbelleğe alınır; kullanıcı/API cevapları alınmaz.
const CACHE_PREFIX = 'tamisim-';
const CACHE = `${CACHE_PREFIX}static-v54`;
const SHELL = ['./', './index.html', './config.js', './turkiye-locations.js', './manifest.webmanifest', './icon-192.png', './icon-512.png'];
const STATIC_PATHS = new Set(SHELL.map((path) => new URL(path, self.registration.scope).pathname));

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith(CACHE_PREFIX) && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  const url = new URL(req.url);
  // Supabase, ödeme ve tüm diğer dış/dinamik istekler doğrudan ağa gider.
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  const isNavigation = req.mode === 'navigate';
  const isStatic = STATIC_PATHS.has(url.pathname) && !url.search;
  if (!isNavigation && !isStatic) return;
  e.respondWith((async () => {
    try {
      const res = await fetch(req, { cache: 'no-store' });
      if (res.ok) {
        const key = isNavigation ? new URL('./index.html', self.registration.scope).href : req;
        const cache = await caches.open(CACHE);
        await cache.put(key, res.clone());
      }
      return res;
    } catch (_) {
      const cache = await caches.open(CACHE);
      if (isNavigation) return (await cache.match(new URL('./index.html', self.registration.scope).href)) || Response.error();
      return (await cache.match(req)) || Response.error();
    }
  })());
});
