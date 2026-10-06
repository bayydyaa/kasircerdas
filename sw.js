/* Service worker Kasir AMT.
   Tugasnya hanya dua: membuat kasir bisa dipasang seperti aplikasi, dan membuat
   halamannya cepat terbuka. Data penjualan TIDAK disimpan di sini: kasir tetap
   butuh internet untuk masuk, menyimpan transaksi, dan membuka laporan.
   - Halaman kasir: ambil dari internet dulu supaya pembaruan langsung terpakai,
     kalau internet putus pakai salinan terakhir.
   - Ikon: pakai salinan dulu.
   - Selain itu (Supabase, daftar barang dari katalog, font) tidak disentuh.
   Naikkan angka VERSI kalau mau memaksa semua salinan lama dibuang. */
const VERSI = "kasir-amt-v1";
const INTI = ["./", "manifest.webmanifest", "icon-192.png", "icon-512.png", "apple-touch-icon.png"];

self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(VERSI)
      .then(c => Promise.all(INTI.map(u => c.add(u).catch(() => {}))))   // satu file gagal tidak membatalkan pemasangan
      .then(() => self.skipWaiting())
  );
});
self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(k => Promise.all(k.filter(n => n !== VERSI).map(n => caches.delete(n))))
      .then(() => self.clients.claim())
  );
});
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;                 // Supabase, font, dll.
  if (!url.pathname.startsWith(new URL("./", self.location).pathname)) return;   // di luar folder kasir (mis. katalog)

  if (req.mode === "navigate") {
    e.respondWith(
      fetch(req).then(res => {
        if (res.ok) { const salin = res.clone(); caches.open(VERSI).then(c => c.put("./", salin)); }
        return res;
      }).catch(() => caches.match("./"))
    );
    return;
  }
  if (/\.(png|webmanifest)$/.test(url.pathname)) {
    e.respondWith(
      caches.match(req).then(ada => ada || fetch(req).then(res => {
        if (res.ok) { const salin = res.clone(); caches.open(VERSI).then(c => c.put(req, salin)); }
        return res;
      }))
    );
  }
});
