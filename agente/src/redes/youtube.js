// YouTube: API oficial (YouTube Data API v3) con una llave de API.
// Ojo con la cuota diaria gratis (10,000 unidades): buscar el live cuesta 100, cada lectura del chat 5.
import { esperar, aFecha, pedirJSON, nuevoEstado } from './comun.js';

export function crearYouTube(cfg, eventos) {
  const api = 'https://www.googleapis.com/youtube/v3';
  const key = encodeURIComponent(cfg.apiKey || '');
  const estado = nuevoEstado('youtube', 'Esperando a que empiece el live de YouTube');
  let parar = false;

  async function ciclo() {
    while (!parar) {
      try {
        const s = await pedirJSON(`${api}/search?part=id&channelId=${encodeURIComponent(cfg.canalId)}&eventType=live&type=video&key=${key}`);
        const video = s.items?.[0]?.id?.videoId;
        if (!video) { estado.estado = 'esperando'; estado.detalle = 'El canal no está en vivo todavía'; await esperar(120000); continue; }
        const v = await pedirJSON(`${api}/videos?part=liveStreamingDetails&id=${video}&key=${key}`);
        const chat = v.items?.[0]?.liveStreamingDetails?.activeLiveChatId;
        if (!chat) { await esperar(60000); continue; }
        estado.estado = 'conectado'; estado.detalle = 'Leyendo el chat del live de YouTube';
        eventos.enVivo('youtube');
        let pagina = '';
        while (!parar) {
          let m;
          try { m = await pedirJSON(`${api}/liveChat/messages?liveChatId=${chat}&part=snippet,authorDetails&maxResults=200&key=${key}${pagina ? '&pageToken=' + pagina : ''}`); }
          catch (e) { if (/ended|not found|disabled/i.test(e.message)) break; throw e; }
          for (const k of m.items || []) {
            const texto = k.snippet?.displayMessage || k.snippet?.textMessageDetails?.messageText;
            if (!texto) continue;
            eventos.comentario({ red: 'youtube', usuario: k.authorDetails?.displayName || k.authorDetails?.channelId, nombre: k.authorDetails?.displayName, texto, id: k.id, fecha: aFecha(k.snippet?.publishedAt) });
          }
          pagina = m.nextPageToken || pagina;
          await esperar(Math.max(Number(m.pollingIntervalMillis) || 5000, 5000));
        }
        estado.estado = 'esperando'; estado.detalle = 'El live de YouTube terminó';
      } catch (e) {
        estado.estado = 'error'; estado.detalle = 'YouTube: ' + e.message;
        await esperar(60000);
      }
    }
  }
  return { estado, iniciar() { ciclo(); }, async detener() { parar = true; estado.estado = 'apagado'; } };
}
