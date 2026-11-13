/* Recibe los avisos del equipo y los muestra como notificación en el teléfono.
 * No guarda nada en caché: las apps siempre cargan la versión más reciente. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { cuerpo: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.titulo || 'Outlet Prime', {
    body: d.cuerpo || '',
    icon: 'icons/app-192.png',
    badge: 'icons/badge-96.png',
    tag: d.tag || undefined,
    data: { url: d.url || 'live.html' },
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const destino = new URL((e.notification.data && e.notification.data.url) || 'live.html', self.registration.scope).href;
  e.waitUntil((async () => {
    const ventanas = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of ventanas) {
      if (w.url.startsWith(self.registration.scope)) {
        try { await w.focus(); if ('navigate' in w) await w.navigate(destino); return; } catch (x) { /* abre una nueva */ }
      }
    }
    await self.clients.openWindow(destino);
  })());
});
