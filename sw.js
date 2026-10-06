/* Service worker E-Katalog CV Azzahra Mutiara Tani.
   - Halaman (index.html): ambil dari internet dulu supaya update langsung kelihatan,
     kalau offline pakai salinan terakhir.
   - Data produk (produk.json): internet dulu, kalau offline pakai salinan terakhir.
   - Ikon & foto produk (folder foto/): pakai salinan dulu, perbarui diam-diam di belakang.
   - Hal di luar situs ini (Google Maps, WhatsApp, font) tidak disentuh.
   Naikkan angka VERSI kalau mau memaksa semua salinan lama dibuang. */
const VERSI = "amt-v2";
const INTI = ["./", "manifest.webmanifest", "icon-192.png", "icon-512.png", "apple-touch-icon.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(VERSI).then(c => c.addAll(INTI)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys()
    .then(k => Promise.all(k.filter(n => n !== VERSI).map(n => caches.delete(n))))
    .then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  /* data produk: selalu coba yang terbaru dulu (supaya editan admin langsung kelihatan) */
  if (url.pathname.endsWith("/produk.json")) {
    e.respondWith(
      fetch(req).then(res => {
        if (res.ok) { const salin = res.clone(); caches.open(VERSI).then(c => c.put("produk.json", salin)); }
        return res;
      }).catch(() => caches.match("produk.json"))
    );
    return;
  }
  if (req.mode === "navigate") {
    e.respondWith(
      fetch(req).then(res => {
        if (res.ok) { const salin = res.clone(); caches.open(VERSI).then(c => c.put("./", salin)); }
        return res;
      }).catch(() => caches.match("./"))
    );
    return;
  }
  e.respondWith(
    caches.match(req).then(ada => {
      const baru = fetch(req).then(res => {
        if (res.ok) { const salin = res.clone(); caches.open(VERSI).then(c => c.put(req, salin)); }
        return res;
      });
      if (ada) { baru.catch(() => {}); return ada; }
      return baru;
    })
  );
});
