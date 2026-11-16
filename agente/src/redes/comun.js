export const esperar = ms => new Promise(r => setTimeout(r, ms));

// Hora del comentario en milisegundos (acepta segundos, milisegundos o texto ISO)
export function aFecha(x) {
  if (x == null || x === '') return new Date();
  const n = Number(x);
  if (Number.isFinite(n) && n > 0) return new Date(n > 1e12 ? n : n * 1000);
  const d = new Date(x);
  return isNaN(d) ? new Date() : d;
}

export async function pedirJSON(url) {
  const r = await fetch(url, { signal: AbortSignal.timeout(15000) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    const msg = j?.error?.message || j?.error?.errors?.[0]?.message || `HTTP ${r.status}`;
    throw new Error(msg);
  }
  return j;
}

// Estado que ve el panel: conectado | esperando | error | apagado
export function nuevoEstado(red, detalle) {
  return { red, estado: 'esperando', detalle, comentarios: 0, pedidos: 0 };
}
