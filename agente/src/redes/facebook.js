// Facebook: API oficial de Meta (Graph API). Necesita el token de la página con permiso
// pages_read_engagement / pages_read_user_content. Se conecta con: npm run facebook (ver LEEME.md).
// En Facebook no hay @usuario: se usa el nombre de la persona sin espacios ni acentos ("Ana Gómez" → anagomez).
import { esperar, aFecha, pedirJSON, nuevoEstado } from './comun.js';

export function crearFacebook(cfg, eventos) {
  const raiz = process.env.GRAPH_URL || 'https://graph.facebook.com';
  const base = cfg.version ? `${raiz}/${cfg.version}` : raiz;
  const tk = encodeURIComponent(cfg.token || '');
  const estado = nuevoEstado('facebook', 'Esperando a que empiece el live de la página');
  let parar = false;

  async function ciclo() {
    while (!parar) {
      try {
        const v = await pedirJSON(`${base}/${cfg.paginaId}/live_videos?broadcast_status=${encodeURIComponent('["LIVE"]')}&fields=id,title&access_token=${tk}`);
        const live = v.data?.[0];
        if (!live) { estado.estado = 'esperando'; estado.detalle = 'La página no está en vivo todavía'; await esperar(30000); continue; }
        estado.estado = 'conectado';
        estado.detalle = `Leyendo el live de Facebook (${live.title || live.id})`;
        eventos.enVivo('facebook');
        const vistos = new Set();
        while (!parar) {
          const c = await pedirJSON(`${base}/${live.id}/comments?order=reverse_chronological&live_filter=no_filter&filter=stream&limit=100&fields=id,message,created_time,from{id,name}&access_token=${tk}`);
          for (const k of (c.data || []).slice().reverse()) {
            if (vistos.has(k.id)) continue;
            vistos.add(k.id);
            if (!k.from) { eventos.sinAutor?.('facebook', k.message, { id: k.id, fecha: aFecha(k.created_time) }); continue; }   // Facebook no compartió quién fue
            eventos.comentario({ red: 'facebook', usuario: k.from.name || k.from.id, nombre: k.from.name, texto: k.message, id: k.id, fecha: aFecha(k.created_time) });
          }
          const sigue = await pedirJSON(`${base}/${live.id}?fields=status&access_token=${tk}`);
          if (sigue.status && sigue.status !== 'LIVE') break;
          await esperar(2500);
        }
        estado.estado = 'esperando'; estado.detalle = 'El live de Facebook terminó';
      } catch (e) {
        estado.estado = 'error'; estado.detalle = 'Facebook: ' + e.message;
        await esperar(20000);
      }
    }
  }
  return { estado, iniciar() { ciclo(); }, async detener() { parar = true; estado.estado = 'apagado'; } };
}
