// Instagram: API oficial de Meta. La cuenta debe ser profesional y estar ligada a la página.
import { esperar, aFecha, pedirJSON, nuevoEstado } from './comun.js';

export function crearInstagram(cfg, eventos) {
  const base = `https://graph.facebook.com/${cfg.version || 'v21.0'}`;
  const tk = encodeURIComponent(cfg.token || '');
  const estado = nuevoEstado('instagram', 'Esperando a que empiece el live de Instagram');
  let parar = false;

  async function ciclo() {
    while (!parar) {
      try {
        const v = await pedirJSON(`${base}/${cfg.cuentaId}/live_media?fields=id,media_type,timestamp&access_token=${tk}`);
        const live = v.data?.[0];
        if (!live) { estado.estado = 'esperando'; estado.detalle = 'Instagram no está en vivo todavía'; await esperar(30000); continue; }
        estado.estado = 'conectado'; estado.detalle = 'Leyendo el live de Instagram';
        eventos.enVivo('instagram');
        const vistos = new Set();
        let fallos = 0;
        while (!parar) {
          let c;
          try { c = await pedirJSON(`${base}/${live.id}/comments?fields=id,text,username,timestamp&limit=100&access_token=${tk}`); fallos = 0; }
          catch (e) { if (++fallos >= 3) break; await esperar(3000); continue; }   // el live terminó o falló la red
          const lista = (c.data || []).slice().sort((a, b) => String(a.timestamp).localeCompare(String(b.timestamp)));
          for (const k of lista) {
            if (vistos.has(k.id)) continue;
            vistos.add(k.id);
            eventos.comentario({ red: 'instagram', usuario: k.username, nombre: k.username, texto: k.text, id: k.id, fecha: aFecha(k.timestamp) });
          }
          await esperar(2500);
        }
        estado.estado = 'esperando'; estado.detalle = 'El live de Instagram terminó';
      } catch (e) {
        estado.estado = 'error'; estado.detalle = 'Instagram: ' + e.message;
        await esperar(20000);
      }
    }
  }
  return { estado, iniciar() { ciclo(); }, async detener() { parar = true; estado.estado = 'apagado'; } };
}
