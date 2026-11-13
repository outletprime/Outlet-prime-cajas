// Avisos al celular del equipo (Web Push).
//
// - POST {"accion":"llave"} → devuelve la llave pública para que un teléfono active los avisos.
// - POST (cualquier otro)   → manda los avisos pendientes a todos los teléfonos activos.
//   La base de datos la llama sola en cuanto hay un aviso nuevo (y cada minuto como respaldo).
//
// No necesita secretos: las llaves de notificación las genera esta función la primera vez y
// las guarda en la tabla avisos_config, que solo el servidor puede leer.
// Cifrado según RFC 8291 (aes128gcm) y firma VAPID (RFC 8292), solo con WebCrypto.

import { createClient } from 'npm:@supabase/supabase-js@2.49.4';

const sb = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', {
  auth: { persistSession: false },
});
const CONTACTO = 'https://outletprime.github.io/Outlet-prime-cajas/';
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const enc = new TextEncoder();

export const b64u = (buf: ArrayBuffer | Uint8Array) => {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
export const deB64u = (s: string) => {
  const t = s.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(t + '='.repeat((4 - (t.length % 4)) % 4));
  return Uint8Array.from(bin, c => c.charCodeAt(0));
};
const unir = (...partes: Uint8Array[]) => {
  const out = new Uint8Array(partes.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of partes) { out.set(p, i); i += p.length; }
  return out;
};

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, largo: number) {
  const k = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, k, largo * 8));
}

// Cifra el contenido para un teléfono (RFC 8291 / RFC 8188, un solo registro)
export async function cifrar(contenido: Uint8Array, p256dh: string, auth: string) {
  const uaPub = deB64u(p256dh);
  const secretoAuth = deB64u(auth);
  const uaLlave = await crypto.subtle.importKey('raw', uaPub, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const efimera = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
  const asPub = new Uint8Array(await crypto.subtle.exportKey('raw', efimera.publicKey));
  const compartido = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaLlave }, efimera.privateKey, 256));
  const ikm = await hkdf(secretoAuth, compartido, unir(enc.encode('WebPush: info\0'), uaPub, asPub), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);
  const llave = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const cifrado = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, llave, unir(contenido, new Uint8Array([2]))));
  const cabecera = new Uint8Array(16 + 4 + 1 + asPub.length);
  cabecera.set(salt, 0);
  new DataView(cabecera.buffer).setUint32(16, 4096);
  cabecera[20] = asPub.length;
  cabecera.set(asPub, 21);
  return unir(cabecera, cifrado);
}

// Firma VAPID: identifica a Outlet Prime ante el servicio de notificaciones
export async function firmaVapid(endpoint: string, privadaJwk: JsonWebKey) {
  const cab = b64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const datos = b64u(enc.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: CONTACTO })));
  const llave = await crypto.subtle.importKey('jwk', privadaJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const firma = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, llave, enc.encode(`${cab}.${datos}`));
  return `${cab}.${datos}.${b64u(firma)}`;
}

type Config = { vapid_publica: string; vapid_privada: JsonWebKey };
async function llaves(): Promise<Config> {
  const { data, error } = await sb.from('avisos_config').select('vapid_publica, vapid_privada').eq('id', true).limit(1);
  if (error) throw error;
  if (data?.[0]?.vapid_publica && data[0].vapid_privada) return data[0] as Config;
  const par = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const nuevas = {
    vapid_publica: b64u(await crypto.subtle.exportKey('raw', par.publicKey)),
    vapid_privada: await crypto.subtle.exportKey('jwk', par.privateKey),
    actualizado_en: new Date().toISOString(),
  };
  // Solo se guardan si nadie las guardó antes (dos llamadas a la vez usan las mismas)
  const { data: guardadas } = await sb.from('avisos_config').update(nuevas).eq('id', true).is('vapid_publica', null).select('vapid_publica, vapid_privada');
  if (guardadas?.length) return guardadas[0] as Config;
  const { data: otra, error: e2 } = await sb.from('avisos_config').select('vapid_publica, vapid_privada').eq('id', true).limit(1);
  if (e2 || !otra?.[0]?.vapid_publica) throw e2 ?? new Error('No se pudieron guardar las llaves de avisos.');
  return otra[0] as Config;
}

async function enviarUno(cfg: Config, d: { endpoint: string; p256dh: string; auth: string }, aviso: Record<string, unknown>) {
  const contenido = enc.encode(JSON.stringify({ titulo: aviso.titulo, cuerpo: aviso.cuerpo, url: aviso.url, tag: aviso.id }));
  const cuerpo = await cifrar(contenido, d.p256dh, d.auth);
  const jwt = await firmaVapid(d.endpoint, cfg.vapid_privada);
  return fetch(d.endpoint, {
    method: 'POST',
    headers: {
      'Content-Encoding': 'aes128gcm',
      'Content-Type': 'application/octet-stream',
      TTL: '86400',
      Urgency: 'high',
      Authorization: `vapid t=${jwt}, k=${cfg.vapid_publica}`,
    },
    body: cuerpo,
  });
}

async function mandarPendientes(cfg: Config) {
  const desde = new Date(Date.now() - 24 * 3600e3).toISOString();
  const [{ data: avisos, error: e1 }, { data: dispositivos, error: e2 }] = await Promise.all([
    sb.from('avisos').select('*').is('enviado_en', null).gt('creado_en', desde).order('creado_en', { ascending: true }).limit(50),
    sb.from('avisos_dispositivos').select('*').eq('activo', true),
  ]);
  if (e1) throw e1;
  if (e2) throw e2;
  let procesados = 0;
  for (const a of avisos ?? []) {
    // Se aparta antes de mandarlo, para que dos llamadas a la vez no lo dupliquen
    const { data: tomado } = await sb.from('avisos').update({ enviado_en: new Date().toISOString() }).eq('id', a.id).is('enviado_en', null).select('id');
    if (!tomado?.length) continue;
    procesados++;
    const destino = (dispositivos ?? []).filter(d => !a.usuario_id || d.usuario_id === a.usuario_id);
    let ok = 0;
    const errores: string[] = [];
    await Promise.all(destino.map(async d => {
      try {
        const r = await enviarUno(cfg, d, a);
        if (r.ok) {
          ok++;
          await sb.from('avisos_dispositivos').update({ ultimo_envio: new Date().toISOString(), ultimo_error: null }).eq('id', d.id);
        } else if (r.status === 404 || r.status === 410) {
          // El teléfono ya no acepta avisos (se desinstaló o se quitó el permiso)
          await sb.from('avisos_dispositivos').update({ activo: false, ultimo_error: `ya no existe (${r.status})` }).eq('id', d.id);
        } else {
          const txt = (await r.text()).slice(0, 200);
          errores.push(`${d.nombre ?? d.id}: ${r.status} ${txt}`);
          await sb.from('avisos_dispositivos').update({ ultimo_error: `${r.status} ${txt}` }).eq('id', d.id);
        }
      } catch (e) {
        errores.push(`${d.nombre ?? d.id}: ${String(e).slice(0, 200)}`);
      }
    }));
    await sb.from('avisos').update({ enviados: ok, error: errores.join(' | ') || null }).eq('id', a.id);
  }
  return { procesados, telefonos: dispositivos?.length ?? 0 };
}

if (typeof Deno !== 'undefined' && typeof Deno.serve === 'function') {
  Deno.serve(async req => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
    let cuerpo: Record<string, unknown> = {};
    try { cuerpo = await req.json(); } catch { /* sin cuerpo */ }
    try {
      const cfg = await llaves();
      if (cuerpo.accion === 'llave') return Response.json({ llave: cfg.vapid_publica }, { headers: CORS });
      return Response.json(await mandarPendientes(cfg), { headers: CORS });
    } catch (e) {
      console.error('avisos', e);
      return Response.json({ error: String(e) }, { status: 500, headers: CORS });
    }
  });
}
