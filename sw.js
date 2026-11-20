// Yalnız statik uygulama kabuğu önbelleğe alınır; kullanıcı/API cevapları alınmaz.
const CACHE = 'tamisim-static-v56';
const ROOT_URL = self.registration.scope;
const HTML_URL = new URL('./index.html', ROOT_URL).href;
const SHELL = [
  './config.js', './turkiye-locations.js',
  './manifest.webmanifest', './icon-192.png', './icon-512.png', './hero-person.png',
];
const SHELL_URLS = new Set(SHELL.map((path) => new URL(path, self.registration.scope).href));
// index.html'deki sabit sürümlü tarayıcı betiği. Supabase API URL'leri dahil değildir.
const SDK_URL = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js';

// İki giriş adresi tek bir anonim, statik HTML kopyasını paylaşır.
function fetchHtml() {
  return fetch(HTML_URL, { mode: 'same-origin', credentials: 'omit', redirect: 'error', cache: 'no-store' });
}

function isPublicHtml(res) {
  const vary = res.headers.get('vary') || '';
  return res.url === HTML_URL && res.status === 200 &&
    /^text\/html(?:\s*;|$)/i.test(res.headers.get('content-type') || '') &&
    !/\b(?:private|no-store)\b/i.test(res.headers.get('cache-control') || '') &&
    vary.split(',').every(name => ['', 'accept-encoding', 'origin'].includes(name.trim().toLowerCase()));
}

self.addEventListener('install', (e) => {
  const assets = [...SHELL_URLS].map((url) =>
    new Request(url, { cache: 'reload', credentials: 'omit', redirect: 'error' })
  );
  e.waitUntil((async () => {
    const html = await fetchHtml();
    if (!isPublicHtml(html)) throw new Error('Statik index.html önbelleğe alınamadı.');
    const cache = await caches.open(CACHE);
    await cache.addAll(assets);
    await cache.put(HTML_URL, html);
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => /^tamisim-static-v\d+$/.test(k) && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

async function loadSdk(req) {
  try {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(SDK_URL);
    if (cached) return cached;

    const res = await fetch(SDK_URL, {
      mode: 'cors', credentials: 'omit', redirect: 'error', cache: 'no-store',
    });
    if (res.ok && /^(application|text)\/javascript(?:\s*;|$)/i.test(res.headers.get('content-type') || '')) {
      await cache.put(SDK_URL, res.clone()).catch(() => {});
      return res;
    }
    if (!res.ok) return res;
  } catch (_) {
    // A CORS or cache error must not prevent the browser's normal script request.
  }
  return fetch(req, { credentials: 'omit', cache: 'no-store' });
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET' || req.headers.has('authorization')) return;
  if (req.url === ROOT_URL || req.url === HTML_URL) {
    if (req.mode !== 'navigate') return;
    e.respondWith((async () => {
      let res;
      try {
        res = await fetchHtml();
      } catch (_) {
        const cache = await caches.open(CACHE);
        return (await cache.match(HTML_URL)) || Response.error();
      }
      if (isPublicHtml(res)) {
        await caches.open(CACHE).then(cache => cache.put(HTML_URL, res.clone())).catch(() => {});
      }
      return res;
    })());
    return;
  }
  if (req.url === SDK_URL && req.destination === 'script') {
    e.respondWith(loadSdk(req));
    return;
  }
  // Yalnız açıkça listelenen statik URL'ler. Sorgulu URL'ler ve API yanıtları önbelleğe girmez.
  if (!SHELL_URLS.has(req.url)) return;
  e.respondWith((async () => {
    try {
      return await fetch(req, { cache: 'no-store' });
    } catch (_) {
      const cache = await caches.open(CACHE);
      return (await cache.match(req.url)) || Response.error();
    }
  })());
});
