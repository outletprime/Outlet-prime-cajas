// Outlet Prime · Agente del live
// Lee los comentarios de las redes, entiende qué prendas piden (reglas + IA)
// y las aparta en Supabase con live_comentario(). Se corre en la computadora de la tienda.
//
//   npm start                     → agente normal (redes activas en config.json)
//   npm run simulador             → escribes comentarios en esta ventana: "tiktok ana_23 la 23"
//   npm run probar -- "texto"     → solo muestra cómo interpreta un comentario (no aparta nada)

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import { interpretarReglas, validarRespuestaIA } from './interprete.js';
import { crearIA } from './ia.js';
import { numAClave } from './claves.js';
import { esperar } from './redes/comun.js';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const MODO_SIM = args.includes('--simulador');
const PROBAR = args.includes('--probar') ? args.slice(args.indexOf('--probar') + 1).join(' ') : null;
const VERIFICAR = args.includes('--verificar');   // revisa Supabase, nivel e IA y se cierra
const rutaCfg = args.includes('--config') ? args[args.indexOf('--config') + 1] : path.join(RAIZ, 'config.json');

// ---------- Pantalla ----------
const C = { gris: '\x1b[90m', verde: '\x1b[32m', amarillo: '\x1b[33m', rojo: '\x1b[31m', rosa: '\x1b[95m', azul: '\x1b[36m', neg: '\x1b[1m', fin: '\x1b[0m' };
const hora = () => new Date().toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
const num = n => numAClave(Number(n)) || String(n);
const lista = a => a.map(num).join(', ');
let archivoRegistro = null;
function anotar(txt) {
  if (!archivoRegistro) return;
  try { fs.appendFileSync(archivoRegistro, `${new Date().toISOString()} ${txt.replace(/\x1b\[[0-9;]*m/g, '')}\n`); } catch { /* sin disco: seguimos */ }
}
function decir(color, txt) {
  const linea = `${C.gris}${hora()}${C.fin} ${color}${txt}${C.fin}`;
  console.log(linea);
  anotar(txt);
}

// ---------- Configuración ----------
function leerConfig() {
  if (!fs.existsSync(rutaCfg)) {
    console.error(`${C.rojo}Falta el archivo ${rutaCfg}.${C.fin}\nCopia config.ejemplo.json como config.json y llena los datos (ver LEEME.md).`);
    process.exit(1);
  }
  try { return JSON.parse(fs.readFileSync(rutaCfg, 'utf8')); }
  catch (e) { console.error(`${C.rojo}config.json tiene un error de escritura: ${e.message}${C.fin}`); process.exit(1); }
}

// ---------- Interpretación en orden ----------
// Las consultas a la IA corren a la vez, pero los comentarios se mandan a Supabase en el
// orden en que llegaron: así "gana el primer comentario" aunque la IA tarde un poco.
function crearFila({ ia, enviar }) {
  const cola = [];
  let trabajando = false;
  let enCurso = 0;
  const esperandoTurno = [];
  const limitar = async fn => {
    while (enCurso >= 5) await new Promise(r => esperandoTurno.push(r));
    enCurso++;
    try { return await fn(); } finally { enCurso--; esperandoTurno.shift()?.(); }
  };

  async function bombear() {
    if (trabajando) return;
    trabajando = true;
    try {
      while (cola.length) {
        const { c, promesa } = cola.shift();
        const i = await promesa;
        if (i.prendas.length) await enviar(c, i);
        else if (i.tipo === 'pregunta') decir(C.azul, `❓ @${c.usuario} pregunta: "${c.texto}"`);
        else if (i.tipo === 'cancelar') decir(C.amarillo, `✋ @${c.usuario} quiere cancelar: "${c.texto}" → revisar en el panel`);
        else if (i.nota) decir(C.amarillo, `👀 Revisar a mano @${c.usuario}: "${c.texto}" (${i.nota})`);
      }
    } finally { trabajando = false; }
  }

  return {
    get pendientes() { return cola.length + (trabajando ? 1 : 0); },
    agregar(c) {
      const r = interpretarReglas(c.texto);
      if (r.tipo === 'ignorar') return false;
      if (r.tipo === 'sin_clave') { decir(C.amarillo, `🔢 @${c.usuario} escribió "${c.texto}" sin letra: falta la clave completa (ej. A23)`); return false; }
      let promesa;
      if (r.tipo === 'apartar') promesa = Promise.resolve({ prendas: r.prendas, por: 'reglas' });
      else if (!ia) promesa = Promise.resolve({ prendas: [], por: 'reglas', nota: 'la IA está apagada' });
      else promesa = limitar(() => ia(c.usuario, c.texto))
        .then(x => ({ prendas: validarRespuestaIA(c.texto, x), por: 'ia', tipo: x.tipo, nota: x.nota }));
      cola.push({ c, promesa });
      bombear();
      return true;
    },
  };
}

// ---------- Solo probar la interpretación ----------
async function probar(texto, cfg) {
  const r = interpretarReglas(texto);
  console.log('Reglas:', r);
  if (r.claves?.length) console.log('Claves:', r.claves.join(', '));
  if (r.tipo === 'dudoso') {
    const ia = crearIA(cfg?.ia);
    if (!ia) return console.log('IA apagada en config.json');
    const x = await ia('prueba', texto);
    console.log('IA:', x, '→ se apartaría:', validarRespuestaIA(texto, x));
  }
}

// ---------- Programa ----------
async function principal() {
  const cfg = leerConfig();
  if (PROBAR !== null) { await probar(PROBAR, cfg); return; }

  fs.mkdirSync(path.join(RAIZ, 'registro'), { recursive: true });
  archivoRegistro = path.join(RAIZ, 'registro', `${new Date().toISOString().slice(0, 10)}.txt`);

  console.log(`${C.rosa}${C.neg}\n  Outlet Prime · Agente del live\n${C.fin}`);
  const s = cfg.supabase || {};
  const sb = createClient(s.url, s.anonKey, { auth: { persistSession: false, autoRefreshToken: true } });
  const { error: eLogin } = await sb.auth.signInWithPassword({ email: s.correo, password: s.contrasena });
  if (eLogin) { decir(C.rojo, `No pude entrar a Supabase con ${s.correo}: ${eLogin.message}`); process.exit(1); }
  const { data: rol } = await sb.rpc('mi_rol');
  if (!['duena', 'operacion'].includes(rol)) {
    decir(C.rojo, `El usuario ${s.correo} no tiene nivel "Operación". Asígnalo en Panel → Ajustes → Equipo.`);
    process.exit(1);
  }
  decir(C.verde, `Conectado a Supabase como ${s.correo} (${rol === 'duena' ? 'Dueña' : 'Operación'})`);

  // Sesión: si se pierde (por ejemplo, si la computadora se quedó sin internet cuando tocaba renovarla),
  // el sistema rechaza todo con "permission denied". Se revisa cada minuto y también en cuanto algo es
  // rechazado; si se perdió, el agente vuelve a entrar solo con el mismo usuario.
  const esDeSesion = e => !!e && (['42501', 'PGRST301', 'PGRST303'].includes(e.code)
    || /JWT|permission denied|not authorized|Auth session missing|Invalid Refresh Token/i.test(e.message || ''));
  let reentrando = null;
  function volverAEntrar(motivo) {
    reentrando ??= (async () => {
      try {
        const { error: eRef } = await sb.auth.refreshSession();
        let ok = !eRef && !!(await sb.rpc('mi_rol')).data;
        if (!ok) {
          const { error } = await sb.auth.signInWithPassword({ email: s.correo, password: s.contrasena });
          ok = !error && !!(await sb.rpc('mi_rol')).data;
          if (!ok) { decir(C.rojo, `No pude volver a entrar a Supabase (${error?.message || 'sin nivel'}). Lo intento otra vez en un minuto.`); return false; }
        }
        decir(C.verde, `🔑 Volví a entrar a Supabase (${motivo})`);
        return true;
      } catch (e) {
        decir(C.rojo, `No pude volver a entrar a Supabase: ${e.message}. Lo intento otra vez en un minuto.`);
        return false;
      }
    })().finally(() => { reentrando = null; });
    return reentrando;
  }
  setInterval(async () => {
    try {
      const { data, error } = await sb.rpc('mi_rol');
      if (error ? esDeSesion(error) : !data) await volverAEntrar('la sesión se había perdido');
    } catch { /* sin internet: se revisa en el siguiente minuto */ }
  }, 60000);

  const ia = crearIA(cfg.ia);
  decir(ia ? C.verde : C.amarillo, ia ? `IA activa (${cfg.ia.modelo || 'claude-opus-5-5'}) para comentarios poco claros` : 'IA apagada: solo se entienden comentarios claros ("23", "la 23")');

  if (VERIFICAR) {
    let ok = true;
    const { error: eTabla } = await sb.from('live_dm').select('id', { head: true, count: 'exact' }).limit(1);
    if (eTabla) { ok = false; decir(C.rojo, '❌ Falta pegar en Supabase 20261116090000_comentarios_live.sql'); }
    else decir(C.verde, '✅ La base de datos ya tiene lo de comentarios');
    if (ia) {
      const r = await ia('prueba', 'me llevo la A veintitrés');
      if (r.error) { ok = false; decir(C.rojo, `❌ La IA no respondió: ${r.nota}`); }
      else decir(C.verde, `✅ La IA respondió bien ("me llevo la A veintitrés" → ${(r.claves || []).join(', ') || r.tipo})`);
    }
    const tk = cfg.redes?.tiktok;
    if (tk?.activa) decir(C.verde, `✅ Leerá el TikTok de @${String(tk.usuario || '').replace(/^@/, '')}`);
    const fb = cfg.redes?.facebook;
    if (fb?.activa) {
      try {
        const raiz = process.env.GRAPH_URL || 'https://graph.facebook.com';
        const base = fb.version ? `${raiz}/${fb.version}` : raiz;
        const r = await fetch(`${base}/${fb.paginaId}?fields=name&access_token=${encodeURIComponent(fb.token || '')}`, { signal: AbortSignal.timeout(15000) });
        const j = await r.json();
        if (!r.ok || j.error) throw new Error(j?.error?.message || `HTTP ${r.status}`);
        decir(C.verde, `✅ Leerá el live de Facebook de la página "${j.name}"`);
      } catch (e) { ok = false; decir(C.rojo, `❌ Facebook no responde: ${e.message}. Vuelve a conectarlo con "Conectar Facebook".`); }
    }
    decir(ok ? C.verde + C.neg : C.rojo + C.neg, ok ? '🎉 Todo listo. Para usarlo: doble clic en "Iniciar agente".' : 'Hay que corregir lo de arriba antes del live.');
    process.exit(ok ? 0 : 1);
  }

  // Live del panel: si no hay uno iniciado y la red ya está en vivo, se inicia solo
  let iniciando = null;
  async function asegurarLive() {
    if (!cfg.iniciarLiveSolo) return false;
    iniciando ??= (async () => {
      const { data } = await sb.from('lives').select('id').eq('estado', 'activo').eq('tipo', 'redes').limit(1);
      if (data?.length) return true;
      const titulo = 'Live ' + new Date().toLocaleDateString('es-MX', { weekday: 'long', day: 'numeric', month: 'short' });
      let { error } = await sb.rpc('live_iniciar', { p_titulo: titulo, p_usuario: 'Agente' });
      if (esDeSesion(error) && await volverAEntrar('al iniciar el live')) ({ error } = await sb.rpc('live_iniciar', { p_titulo: titulo, p_usuario: 'Agente' }));
      if (error && !/Ya hay un live/.test(error.message)) { decir(C.rojo, 'No pude iniciar el live en el panel: ' + error.message); return false; }
      decir(C.verde, `▶️  Live iniciado en el panel: ${titulo}`);
      return true;
    })().finally(() => setTimeout(() => { iniciando = null; }, 5000));
    return iniciando;
  }

  const redes = [];
  const porRed = red => redes.find(r => r.estado.red === red)?.estado;

  async function enviar(c, i, intento = 1) {
    const { data, error } = await sb.rpc('live_comentario', {
      p_red: c.red, p_usuario: c.usuario, p_texto: c.texto, p_prendas: i.prendas,
      p_comentado_en: c.fecha.toISOString(), p_comentario_id: c.id, p_nombre: c.nombre,
      p_interpretado_por: i.por, p_simulado: !!c.simulado,
    });
    if (error) {
      if (esDeSesion(error) && intento < 4 && await volverAEntrar('el sistema rechazó un comentario')) return enviar(c, i, intento + 1);
      const reintentar = ['40P01', '40001', '57014', ''].includes(error.code || '') || /fetch|network|timeout|ECONN/i.test(error.message);
      if (reintentar && intento < 4) { await esperar(400 * intento); return enviar(c, i, intento + 1); }
      decir(C.rojo, `❌ No se pudo apartar ${lista(i.prendas)} a @${c.usuario}: ${error.message} → capturar a mano`);
      return;
    }
    const st = porRed(c.red) || porRed('simulador');
    if (st) st.pedidos++;
    const quien = `@${data.usuario}`;
    switch (data.resultado) {
      case 'clienta': {
        const p = [];
        if (data.tuyas?.length) p.push(`${C.verde}✅ ${lista(data.tuyas)} → ${data.casillero || 'sin casillero'}`);
        for (const e of data.espera || []) p.push(`${C.amarillo}⏳ ${num(e.n)} en espera #${e.pos}`);
        if (data.ya?.length) p.push(`${C.gris}ya era suya ${lista(data.ya)}`);
        if (data.vendidas?.length) p.push(`${C.rojo}vendida ${lista(data.vendidas)}`);
        if (data.noexiste?.length) p.push(`${C.rojo}no existe ${lista(data.noexiste)}`);
        if (data.limite?.length) p.push(`${C.rojo}límite ${lista(data.limite)}`);
        decir('', `${quien} (${data.clienta}) ${p.join(`${C.fin} · `)}`);
        break;
      }
      case 'pide_dm': {
        const p = [];
        if (data.provisional?.length) p.push(`provisional ${lista(data.provisional)}`);
        if (data.espera_provisional?.length) p.push(`en espera ${lista(data.espera_provisional)}`);
        if (data.vendidas?.length) p.push(`vendida ${lista(data.vendidas)}`);
        if (data.noexiste?.length) p.push(`no existe ${lista(data.noexiste)}`);
        decir(C.rosa + C.neg, `🙋 PIDE DM A ${quien} (${c.red}) · ${p.join(' · ') || 'ya lo tenía'}`);
        break;
      }
      case 'sin_live':
        if (intento === 1 && await asegurarLive()) return enviar(c, i, 2);
        decir(C.amarillo, `⚠️  No hay live iniciado en el panel: no se apartó ${lista(i.prendas)} de @${c.usuario}`);
        break;
      case 'duplicado':
        break;
      default:
        decir(C.gris, `${quien}: ${data.resultado}`);
    }
  }

  const fila = crearFila({ ia, enviar });
  const propios = new Set(Object.values(cfg.redes || {}).map(r => String(r.usuario || '').replace(/^@/, '').toLowerCase()).filter(Boolean));
  const eventos = {
    comentario(c) {
      if (!c.usuario || !c.texto) return;
      const st = porRed(c.red) || porRed('simulador');
      if (st) st.comentarios++;
      if (propios.has(String(c.usuario).toLowerCase())) return;   // la cuenta de la tienda
      if (fila.agregar(c)) anotar(`[${c.red}] @${c.usuario}: ${c.texto}`);
    },
    enVivo(red) { decir(C.verde, `🔴 ${red} en vivo`); asegurarLive(); },
    sinAutor(red, texto) { if (texto && /\d/.test(texto)) decir(C.amarillo, `👀 ${red}: "${texto}" sin nombre visible (Facebook no compartió quién fue) → revisar a mano`); },
    finSimulador() { setTimeout(() => apagar(), 1500); },
  };

  if (MODO_SIM) {
    const { crearSimulador } = await import('./redes/simulador.js');
    redes.push(crearSimulador(eventos));
    decir(C.azul, 'Modo simulador: escribe  red usuario comentario  (por ejemplo: tiktok ana_23 quiero la A23)');
  } else {
    const r = cfg.redes || {};
    if (r.tiktok?.activa) redes.push((await import('./redes/tiktok.js')).crearTikTok(r.tiktok, eventos));
    if (r.facebook?.activa) redes.push((await import('./redes/facebook.js')).crearFacebook(r.facebook, eventos));
    if (r.instagram?.activa) redes.push((await import('./redes/instagram.js')).crearInstagram(r.instagram, eventos));
    if (r.youtube?.activa) redes.push((await import('./redes/youtube.js')).crearYouTube(r.youtube, eventos));
    if (!redes.length) { decir(C.rojo, 'No hay ninguna red activa en config.json.'); process.exit(1); }
  }
  redes.forEach(r => r.iniciar());

  // Estado para el panel (cada 15 s)
  const equipo = os.hostname();
  let ultimoTexto = '';
  async function reportar(apagado = false) {
    const filas = redes.map(r => ({ ...r.estado, estado: apagado ? 'apagado' : r.estado.estado, equipo, actualizado_en: new Date().toISOString() }));
    filas.push({ red: 'agente', estado: apagado ? 'apagado' : 'conectado', equipo, comentarios: 0, pedidos: 0,
      detalle: `IA ${ia ? 'activa' : 'apagada'} · ${fila.pendientes} en fila`, actualizado_en: new Date().toISOString() });
    const { error } = await sb.from('live_agente').upsert(filas);
    if (error) {
      decir(C.amarillo, 'No pude actualizar el estado en el panel: ' + error.message);
      if (esDeSesion(error)) volverAEntrar('el panel rechazó el estado');
    }
    const t = redes.map(r => `${r.estado.red}: ${r.estado.detalle}`).join(' | ');
    if (t !== ultimoTexto) { decir(C.gris, t); ultimoTexto = t; }
  }
  await reportar();
  const latido = setInterval(reportar, 15000);

  let apagando = false;
  async function apagar() {
    if (apagando) return;
    apagando = true;
    clearInterval(latido);
    decir(C.amarillo, 'Apagando el agente…');
    while (fila.pendientes) await esperar(200);
    await Promise.all(redes.map(r => r.detener()));
    await reportar(true).catch(() => {});
    process.exit(0);
  }
  process.on('SIGINT', apagar);
  process.on('SIGTERM', apagar);
}

principal().catch(e => { console.error(`${C.rojo}Error: ${e?.stack || e}${C.fin}`); process.exit(1); });
