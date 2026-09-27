const APP_VERSION = "0.3.25";

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()));

self.addEventListener("push", event => {
  event.waitUntil((async () => {
    let data = {};
    try { data = event.data ? event.data.json() : {}; }
    catch { data = { body: event.data ? event.data.text() : "" }; }

    await self.registration.showNotification(
      data.title || "СТОGarage",
      {
        body: data.body || "Новое сообщение",
        tag: data.tag || "stogarage-message",
        renotify: true,
        data: { url: data.url || "/" }
      }
    );
  })());
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const targetUrl = event.notification.data && event.notification.data.url
    ? new URL(event.notification.data.url, self.location.origin).href
    : self.location.origin + "/";

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({
      type: "window",
      includeUncontrolled: true
    });

    for (const client of windows) {
      if ("focus" in client) {
        try { await client.navigate(targetUrl); } catch {}
        return client.focus();
      }
    }
    return self.clients.openWindow(targetUrl);
  })());
});
