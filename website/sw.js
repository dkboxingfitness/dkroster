// DK Boxing — service worker.
// Lets the app open instantly and install to the home screen.
// Always tries the network first so updates show up straight away;
// falls back to the saved copy when offline. Data from Supabase is never cached.
const CACHE = 'dk-app-v9';
const FILES = [
  './', './index.html', './styles.css', './app.js', './config.js',
  './vendor/supabase.js', './vendor/qrcode.js', './logo.png', './manifest.json',
  './icons/icon-192.png', './icons/icon-512.png', './icons/apple-touch-icon.png'
];

self.addEventListener('install', e=>{
  e.waitUntil(caches.open(CACHE).then(c=>c.addAll(FILES)).then(()=>self.skipWaiting()));
});

self.addEventListener('activate', e=>{
  e.waitUntil(
    caches.keys()
      .then(keys=>Promise.all(keys.filter(k=>k !== CACHE).map(k=>caches.delete(k))))
      .then(()=>self.clients.claim())
  );
});

self.addEventListener('fetch', e=>{
  const req = e.request;
  if(req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;
  e.respondWith(
    fetch(req)
      .then(res=>{
        if(res.ok){ const copy = res.clone(); caches.open(CACHE).then(c=>c.put(req, copy)); }
        return res;
      })
      .catch(()=>caches.match(req, { ignoreSearch:true }).then(r=> r || caches.match('./index.html')))
  );
});
