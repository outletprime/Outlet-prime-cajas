// TikTok: conexión NO oficial al chat del live (librería tiktok-live-connector).
// TikTok no ofrece una forma oficial de leer comentarios; si cambia algo, el panel
// mostrará "error" y el equipo puede capturar a mano mientras se actualiza la librería.
import { TikTokLiveConnection, WebcastEvent, ControlEvent, UserOfflineError } from 'tiktok-live-connector';
import { esperar, aFecha, nuevoEstado } from './comun.js';

export function crearTikTok(cfg, eventos) {
  const usuario = String(cfg.usuario || '').replace(/^@/, '');
  const estado = nuevoEstado('tiktok', `Esperando a que @${usuario} empiece el live`);
  let parar = false;
  let con = null;

  async function ciclo() {
    while (!parar) {
      let espera = 10000;
      try {
        con = new TikTokLiveConnection(usuario, cfg.signApiKey ? { signApiKey: cfg.signApiKey } : {});
        con.on(WebcastEvent.CHAT, d => {
          eventos.comentario({
            red: 'tiktok',
            usuario: d.user?.uniqueId,
            nombre: d.user?.nickname,
            texto: d.comment,
            id: d.event?.msgId || d.common?.msgId || null,
            fecha: aFecha(d.event?.createTime || d.common?.createTime),
          });
        });
        const cerrado = new Promise(res => {
          con.on(ControlEvent.DISCONNECTED, () => res('desconectado'));
          con.on(WebcastEvent.STREAM_END, () => res('terminó'));
        });
        const st = await con.connect();
        estado.estado = 'conectado';
        estado.detalle = `Leyendo el live de @${usuario} (sala ${st.roomId})`;
        eventos.enVivo('tiktok');
        const motivo = await cerrado;
        estado.estado = 'esperando';
        estado.detalle = motivo === 'terminó' ? `El live de @${usuario} terminó` : 'Se desconectó; reconectando…';
        espera = motivo === 'terminó' ? 30000 : 3000;
      } catch (e) {
        if (e instanceof UserOfflineError || /offline|not live|isn't online/i.test(e?.message || '')) {
          estado.estado = 'esperando';
          estado.detalle = `@${usuario} no está en vivo todavía`;
          espera = 30000;
        } else {
          estado.estado = 'error';
          estado.detalle = 'No se pudo conectar a TikTok: ' + (e?.message || e);
          espera = 20000;
        }
      }
      try { await con?.disconnect(); } catch { /* ya estaba cerrada */ }
      if (!parar) await esperar(espera);
    }
  }

  return {
    estado,
    iniciar() { ciclo(); },
    async detener() { parar = true; estado.estado = 'apagado'; try { await con?.disconnect(); } catch { } },
  };
}
