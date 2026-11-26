// Outlet Prime · Impresor de guías
//
// Pregunta cada 20 segundos qué guías ya compradas faltan por imprimir, las manda a la impresora
// de la tienda y avisa el resultado (con eso le llega a Operación "Guía lista para pegar").
//
//   node src/impresor.js             → se queda trabajando
//   node src/impresor.js --prueba    → imprime una hoja de prueba y termina
//   node src/impresor.js --revisar   → solo revisa conexión e impresora, no imprime
//
// La impresora se toma de config.json → "impresora": { "cola": "HP_Guias" } (si falta, usa HP_Guias).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const rutaCfg = args.includes('--config') ? args[args.indexOf('--config') + 1] : path.join(RAIZ, 'config.json');
const cfg = JSON.parse(fs.readFileSync(rutaCfg, 'utf8'));
const COLA = (cfg.impresora && cfg.impresora.cola) || 'HP_Guias';
const CADA_MS = 20000;
const ESPERA_HOJA_MS = 180000;

const hora = () => new Date().toLocaleString('es-MX', { hour12: false });
const decir = (...t) => console.log(`[${hora()}]`, ...t);
const correr = (cmd, a) => new Promise((ok, mal) => execFile(cmd, a, { timeout: 30000 }, (e, so, se) => e ? mal(new Error((se || e.message).trim())) : ok(so.trim())));
const dormir = ms => new Promise(r => setTimeout(r, ms));

async function impresoraLista() {
  const t = await correr('/usr/bin/lpstat', ['-p', COLA]).catch(e => { throw new Error(`La impresora "${COLA}" no está dada de alta en esta computadora (${e.message})`); });
  if (/deshabilitad|disabled|paused|en pausa/i.test(t)) throw new Error(`La impresora "${COLA}" está en pausa`);
  return t;
}

// Manda un archivo a la impresora y espera a que la hoja salga
async function imprimir(archivo, titulo) {
  await impresoraLista();
  const sal = await correr('/usr/bin/lp', ['-d', COLA, '-t', titulo, '-o', 'media=Letter', '-o', 'fit-to-page', archivo]);
  const trabajo = (sal.match(new RegExp(`${COLA}-\\d+`)) || [])[0];
  if (!trabajo) throw new Error(`La impresora no aceptó la hoja: ${sal}`);
  const limite = Date.now() + ESPERA_HOJA_MS;
  while (Date.now() < limite) {
    await dormir(3000);
    const cola = await correr('/usr/bin/lpstat', ['-W', 'not-completed', '-o', COLA]).catch(() => '');
    if (!cola.includes(trabajo)) return trabajo;
  }
  await correr('/usr/bin/cancel', [trabajo]).catch(() => {});
  throw new Error('La hoja se quedó atorada: revisa que la impresora esté prendida, con papel y en el wifi');
}

async function bajar(url, destino) {
  if (!/^https:\/\//i.test(url)) throw new Error('La guía no trae una dirección válida para descargarla');
  const r = await fetch(url, { signal: AbortSignal.timeout(30000) });
  if (!r.ok) throw new Error(`No se pudo descargar la guía (${r.status})`);
  const b = Buffer.from(await r.arrayBuffer());
  if (b.subarray(0, 5).toString() !== '%PDF-') throw new Error('Lo que se descargó no es un PDF');
  fs.writeFileSync(destino, b);
}

async function entrar() {
  const s = cfg.supabase;
  const sb = createClient(s.url, s.anonKey, { auth: { persistSession: false, autoRefreshToken: true } });
  const { error } = await sb.auth.signInWithPassword({ email: s.correo, password: s.contrasena });
  if (error) throw new Error(`No se pudo entrar al sistema: ${error.message}`);
  return sb;
}

async function vuelta(sb) {
  const { data, error } = await sb.rpc('impresion_pendientes');
  if (error) throw new Error(error.message);
  for (const g of data || []) {
    const archivo = path.join(os.tmpdir(), `guia-${g.envio}.pdf`);
    try {
      decir(`Imprimiendo guía de ${g.clienta} · ${g.paqueteria || ''} ${g.guia || ''}`);
      await bajar(g.etiqueta_url, archivo);
      await imprimir(archivo, `Guia ${g.guia || g.envio}`);
      const { error: e2 } = await sb.rpc('impresion_resultado', { p_envio: g.envio, p_ok: true });
      if (e2) throw new Error(e2.message);
      decir('  ✓ salió de la impresora');
    } catch (e) {
      decir(`  ✗ ${e.message}`);
      await sb.rpc('impresion_resultado', { p_envio: g.envio, p_ok: false, p_error: e.message }).then(() => {}, () => {});
    } finally {
      fs.rmSync(archivo, { force: true });
    }
  }
}

if (args.includes('--prueba')) {
  const archivo = path.join(os.tmpdir(), 'outletprime-prueba.txt');
  fs.writeFileSync(archivo, `\n\n   OUTLET PRIME\n\n   Hoja de prueba de la impresión automática de guías.\n   ${hora()}\n\n   Si estás leyendo esto, la impresora quedó bien ligada.\n`);
  const t = await imprimir(archivo, 'Prueba Outlet Prime');
  fs.rmSync(archivo, { force: true });
  console.log(`Hoja de prueba impresa (${t}).`);
  process.exit(0);
}

let sb = await entrar();
decir(`Impresor listo · impresora "${COLA}" · ${(await impresoraLista().catch(e => e.message))}`);
if (args.includes('--revisar')) {
  const { data, error } = await sb.rpc('impresion_pendientes');
  console.log(error ? `Error: ${error.message}` : `Conexión bien. Guías por imprimir: ${(data || []).length}`);
  process.exit(error ? 1 : 0);
}
let fallas = 0;
for (;;) {
  try { await vuelta(sb); fallas = 0; }
  catch (e) {
    fallas++;
    if (fallas === 1 || fallas % 30 === 0) decir(`Sin conexión con el sistema: ${e.message}`);
    if (fallas % 6 === 0) sb = await entrar().catch(() => sb);
  }
  await dormir(CADA_MS);
}
