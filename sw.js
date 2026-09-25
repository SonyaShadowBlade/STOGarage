const CACHE_NAME = "stogarage-shell-v1";

self.addEventListener("install", event => {
  self.skipWaiting();
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys
          .filter(key => key !== CACHE_NAME)
          .map(key => caches.delete(key))
      )
    ).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  const request = event.request;

  if (request.method !== "GET") return;
  if (new URL(request.url).origin !== self.location.origin) return;

  event.respondWith(
    fetch(request, { cache: "no-store" })
      .then(response => {
        if (response.ok && request.mode === "navigate") {
          const copy = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put("./", copy));
        }
        return response;
      })
      .catch(() => caches.match("./"))
  );
});
