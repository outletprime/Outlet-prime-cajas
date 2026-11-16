// Conecta el agente a la página de Facebook de la tienda (API oficial de Meta).
//
//   npm run facebook        (o doble clic en "Conectar Facebook.command")
//
// Pide 3 datos de la app de Meta (ver LEEME.md → Facebook): el ID de la app, su clave secreta
// y un token de usuario sacado del Explorador de la API Graph. Con eso:
//   1. cambia el token corto (1–2 horas) por uno largo (60 días),
//   2. busca tus páginas y saca el token de la página, que NO vence,
//   3. revisa que pueda leer los lives y comentarios,
//   4. lo guarda en config.json y activa Facebook.
// La clave secreta de la app no se guarda.
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const GRAPH = process.env.GRAPH_URL || 'https://graph.facebook.com';
const rutaCfg = process.argv.includes('--config') ? process.argv[process.argv.indexOf('--config') + 1] : path.join(RAIZ, 'config.json');
const verde = t => `\x1b[32m${t}\x1b[0m`, rojo = t => `\x1b[31m${t}\x1b[0m`, rosa = t => `\x1b[95m\x1b[1m${t}\x1b[0m`;

// Una sola interfaz para todas las preguntas (las respuestas secretas no se muestran)
const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
let ocultar = false;
rl._writeToOutput = s => { if (!ocultar || /[:?)] $/.test(s)) rl.output.write(s); };
function preguntar(texto, secreto = false) {
  return new Promise(res => {
    ocultar = secreto;
    rl.question(texto, r => { if (secreto) rl.output.write('\n'); ocultar = false; res(r.trim()); });
  });
}

async function graph(ruta, params) {
  const url = `${GRAPH}/${ruta}?${new URLSearchParams(params)}`;
  const r = await fetch(url, { signal: AbortSignal.timeout(20000) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) throw new Error(j?.error?.message || `HTTP ${r.status}`);
  return j;
}

async function principal() {
  if (!fs.existsSync(rutaCfg)) { console.log(rojo(`No encontré ${rutaCfg}. Primero instala el agente.`)); process.exit(1); }
  const cfg = JSON.parse(fs.readFileSync(rutaCfg, 'utf8'));
  console.log(rosa('\n  Outlet Prime · Conectar Facebook\n'));
  console.log('Necesitas tu app de Meta (developers.facebook.com) y un token del Explorador de la API Graph');
  console.log('con los permisos pages_show_list, pages_read_engagement y pages_read_user_content.\n');

  const appId = await preguntar('ID de la app: ');
  const secreto = await preguntar('Clave secreta de la app (no se ve al escribir): ', true);
  const corto = await preguntar('Token de usuario del Explorador (no se ve al escribir): ', true);
  if (!appId || !secreto || !corto) { console.log(rojo('Faltan datos.')); process.exit(1); }

  console.log('\n1/3 · Cambiando el token por uno de larga duración…');
  const largo = await graph('oauth/access_token', { grant_type: 'fb_exchange_token', client_id: appId, client_secret: secreto, fb_exchange_token: corto });

  console.log('2/3 · Buscando tus páginas…');
  const cuentas = await graph('me/accounts', { fields: 'id,name,access_token,tasks', access_token: largo.access_token, limit: '100' });
  const paginas = cuentas.data || [];
  if (!paginas.length) throw new Error('Tu usuario no administra ninguna página, o el token no tiene el permiso pages_show_list.');
  let pagina = paginas[0];
  if (paginas.length > 1) {
    paginas.forEach((p, i) => console.log(`   ${i + 1}. ${p.name}`));
    const n = parseInt(await preguntar('¿Cuál es la de la tienda? (número): '), 10);
    pagina = paginas[n - 1];
    if (!pagina) throw new Error('Número inválido.');
  }

  console.log(`3/3 · Revisando que pueda leer los lives de "${pagina.name}"…`);
  await graph(`${pagina.id}/live_videos`, { broadcast_status: '["LIVE","SCHEDULED_LIVE","VOD"]', fields: 'id,status', limit: '1', access_token: pagina.access_token });

  cfg.redes = cfg.redes || {};
  cfg.redes.facebook = { activa: true, paginaId: pagina.id, pagina: pagina.name, token: pagina.access_token, version: '' };
  fs.writeFileSync(rutaCfg, JSON.stringify(cfg, null, 2) + '\n', { mode: 0o600 });
  console.log(verde(`\n✅ Facebook conectado: "${pagina.name}". El token de la página no vence (salvo que cambies tu contraseña`));
  console.log(verde('   de Facebook o quites la app). La próxima vez que inicies el agente leerá también ese live.'));
  rl.close();
}

principal().catch(e => { console.log(rojo(`\n❌ No se pudo conectar: ${e.message}`)); rl.close(); process.exit(1); });
