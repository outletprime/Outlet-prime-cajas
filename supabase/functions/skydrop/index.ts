// Guías con Skydrop (API oficial de Skydropx PRO) para la app de Cajas.
// Flujo: el Supervisor (o una Dueña) pesa, mide y cotiza → se avisa a las Dueñas → una Dueña elige la
// paquetería y compra (descuenta saldo de Skydrop) → se avisa al Supervisor para que imprima la guía.
// Cotizar es gratis y no compromete nada. Comprar y cancelar solo lo hace una Dueña.
//
// Secretos (Supabase → Edge Functions → Secrets): SKYDROP_CLIENT_ID y SKYDROP_CLIENT_SECRET
// (Skydrop → Conexiones → API). Opcional SKYDROP_HOST para apuntar al ambiente de pruebas.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.49.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-llave-prueba',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const HOST = (Deno.env.get('SKYDROP_HOST') || 'https://api-pro.skydropx.com').replace(/\/+$/, '');
const ID = Deno.env.get('SKYDROP_CLIENT_ID') ?? '';
const SECRETO = Deno.env.get('SKYDROP_CLIENT_SECRET') ?? '';
const PUEDEN = ['duena', 'supervisor'];      // cotizar y revisar
const AUTORIZA = 'duena';                    // comprar y cancelar
const HORAS_TARIFA = 23;            // Skydrop respeta el precio 24 horas

class Aviso extends Error {
  codigo: string;
  constructor(codigo: string, mensaje: string) { super(mensaje); this.codigo = codigo; }
}
const espera = (ms: number) => new Promise(r => setTimeout(r, ms));
const corto = (t: unknown, n: number) => String(t ?? '').replace(/\s+/g, ' ').trim().slice(0, n);
const digitos = (t: unknown) => String(t ?? '').replace(/\D/g, '');

// ---------- Conexión con Skydrop ----------
let ficha: { token: string; vence: number } | null = null;
async function token(): Promise<string> {
  if (ficha && Date.now() < ficha.vence) return ficha.token;
  if (!ID || !SECRETO) throw new Aviso('SIN_CREDENCIALES', 'Faltan las credenciales de Skydrop.');
  const datos = { grant_type: 'client_credentials', client_id: ID, client_secret: SECRETO };
  let r = await fetch(`${HOST}/api/v1/oauth/token`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(datos), signal: AbortSignal.timeout(15000),
  });
  let d = await r.json().catch(() => ({}));
  if (!r.ok || !d.access_token) {
    r = await fetch(`${HOST}/api/v1/oauth/token`, {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(datos), signal: AbortSignal.timeout(15000),
    });
    d = await r.json().catch(() => ({}));
  }
  if (!r.ok || !d.access_token) {
    console.error('skydrop token', r.status, d.error);
    throw new Aviso('CREDENCIALES_MAL', 'Skydrop no aceptó las credenciales. Revisa que estén bien copiadas.');
  }
  ficha = { token: d.access_token, vence: Date.now() + Math.max(60, (d.expires_in ?? 7200) - 300) * 1000 };
  return ficha.token;
}
let ultima = 0;
async function sky(metodo: string, ruta: string, cuerpo?: unknown): Promise<{ ok: boolean; status: number; d: any }> {
  const falta = 550 - (Date.now() - ultima);      // Skydrop permite 2 solicitudes por segundo
  if (falta > 0) await espera(falta);
  ultima = Date.now();
  const r = await fetch(`${HOST}${ruta}`, {
    method: metodo,
    headers: { Authorization: `Bearer ${await token()}`, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
    signal: AbortSignal.timeout(25000),
  });
  if (r.status === 401) ficha = null;
  const d = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, d };
}
function errorSky(r: { status: number; d: any }): string {
  const d = r.d || {};
  const partes: string[] = [];
  const junta = (o: unknown, pre = '') => {
    if (o == null) return;
    if (typeof o === 'string') partes.push(pre + o);
    else if (Array.isArray(o)) o.forEach(x => junta(x, pre));
    else if (typeof o === 'object') Object.entries(o as Record<string, unknown>).forEach(([k, v]) => junta(v, `${pre}${k}: `));
  };
  junta(d.errors); junta(d.error); junta(d.message); junta(d.error_description);
  return corto(partes.join(' · ') || `Skydrop respondió ${r.status}`, 400);
}

// ---------- Configuración ----------
type Cfg = {
  origen: Record<string, string> | null; carta_porte: string | null; tipo_empaque: string; formato: string;
  correo_destino: string | null; llave_prueba: string | null;
};
async function config(adm: SupabaseClient): Promise<Cfg> {
  const { data, error } = await adm.from('envios_config').select('*').eq('id', true).single();
  if (error) throw error;
  return data as Cfg;
}
// El domicilio de la tienda se toma de las direcciones guardadas en Skydrop (la marcada como origen)
async function origen(adm: SupabaseClient, cfg: Cfg): Promise<Record<string, string>> {
  if (cfg.origen && cfg.origen.postal_code) return cfg.origen;
  const r = await sky('GET', '/api/v1/address_templates?per_page=20');
  if (!r.ok) throw new Aviso('SKYDROP', errorSky(r));
  const lista: any[] = r.d.data || [];
  const deOrigen = lista.filter(t => !t.address_type || /from|origin|both/i.test(String(t.address_type)));
  const t = deOrigen.find(x => x.default) || deOrigen[0];
  if (!t) throw new Aviso('SIN_ORIGEN', 'Falta guardar en Skydrop la dirección de la tienda (Direcciones → nueva dirección de origen).');
  const a = t.address || {};
  const o: Record<string, string> = {
    address_template_id: String(t.id),
    name: corto(a.name, 30), company: corto(a.company || a.name || 'Outlet Prime', 60),
    street1: corto(a.street1, 45), phone: digitos(a.phone), email: corto(a.email, 80),
    reference: corto(a.reference || 'Tienda', 30),
    postal_code: String(a.postal_code || ''), area_level1: String(a.area_level1 || ''),
    area_level2: String(a.area_level2 || ''), area_level3: String(a.area_level3 || ''), country_code: String(a.country_code || 'MX').toUpperCase(),
  };
  await adm.from('envios_config').update({ origen: o, actualizado_en: new Date().toISOString() }).eq('id', true);
  return o;
}
async function saldo(): Promise<{ saldo: number | null; moneda: string }> {
  const r = await sky('GET', '/api/v1/finance/credits');
  return { saldo: r.ok && r.d.data ? Number(r.d.data.balance) : null, moneda: (r.ok && r.d.data && r.d.data.currency) || 'MXN' };
}

// ---------- Cotizar ----------
type Paquete = { peso_kg: number; largo: number; ancho: number; alto: number };
function paquete(c: any): Paquete {
  const n = (v: unknown) => Number(v);
  const p = { peso_kg: Math.ceil(n(c.peso_kg) * 10) / 10, largo: Math.round(n(c.largo)), ancho: Math.round(n(c.ancho)), alto: Math.round(n(c.alto)) };
  if (!(p.peso_kg >= 1 && p.peso_kg <= 70)) throw new Aviso('DATOS', 'Escribe el peso en kilos (de 1 a 70).');
  for (const k of ['largo', 'ancho', 'alto'] as const) if (!(p[k] >= 1 && p[k] <= 200)) throw new Aviso('DATOS', 'Escribe las medidas en centímetros.');
  return p;
}
async function cotizarSky(de: Record<string, string>, para: Record<string, string>, p: Paquete) {
  const lugar = (x: Record<string, string>) => ({
    country_code: x.country_code || 'MX', postal_code: x.postal_code,
    area_level1: x.area_level1, area_level2: x.area_level2, area_level3: x.area_level3,
  });
  const r = await sky('POST', '/api/v1/quotations', {
    quotation: {
      address_from: lugar(de), address_to: lugar(para),
      parcels: [{ length: p.largo, width: p.ancho, height: p.alto, weight: p.peso_kg }],
    },
  });
  if (!r.ok || !r.d.id) throw new Aviso('SKYDROP', errorSky(r));
  let q = r.d;
  for (let i = 0; i < 14 && !q.is_completed; i++) {
    await espera(1500);
    const v = await sky('GET', `/api/v1/quotations/${q.id}`);
    if (v.ok) q = v.d;
  }
  const tarifas = (q.rates || [])
    .filter((t: any) => t && t.success !== false && Number(t.total) > 0)
    .map((t: any) => ({
      id: String(t.id), paqueteria: String(t.provider_display_name || t.provider_name || ''), codigo: String(t.provider_name || ''),
      servicio: String(t.provider_service_name || ''), dias: t.days == null ? null : Number(t.days), total: Number(t.total),
      recoleccion: !!t.pickup, verificar_origen: !!t.requires_origin_verification,
    }))
    .sort((a: any, b: any) => a.total - b.total);
  return { id: String(q.id), completa: !!q.is_completed, tarifas };
}

// ---------- Datos de la caja ----------
async function cajaPorEnviar(adm: SupabaseClient, asignacion: string) {
  const { data: a } = await adm.from('asignaciones').select('*').eq('id', asignacion).maybeSingle();
  if (!a) throw new Aviso('NO_EXISTE', 'No encontramos ese pedido por enviar. Actualiza la pantalla.');
  if (a.estado === 'enviada') throw new Aviso('YA_ENVIADA', 'Ese pedido ya se marcó como enviado.');
  if (!a.lista_guia_en || a.lista_para === 'tienda') throw new Aviso('NO_LISTA', 'Primero hay que marcar la caja como lista para generar guía.');
  const { data: c } = await adm.from('clientas').select('*').eq('id', a.clienta_id).maybeSingle();
  if (!c) throw new Aviso('NO_EXISTE', 'No encontramos a la clienta de ese pedido.');
  const { data: peds } = await adm.from('pedidos').select('id').eq('asignacion_id', a.id);
  const ids = (peds || []).map((x: { id: string }) => x.id);
  const { data: porCobrar } = ids.length
    ? await adm.from('ventas_privadas').select('id').eq('estado', 'por_cobrar').in('pedido_id', ids).limit(1) : { data: [] };
  if (porCobrar && porCobrar.length) throw new Aviso('POR_COBRAR', 'Tiene una venta privada por cobrar: no lleva guía hasta confirmar el pago.');
  return { a, c };
}
function destino(c: any, cfg: Cfg, de: Record<string, string>) {
  const faltan = [['calle', 'calle'], ['numero', 'número'], ['colonia', 'colonia'], ['cp', 'código postal'], ['ciudad', 'ciudad'], ['estado', 'estado']]
    .filter(([k]) => !String(c[k] ?? '').trim()).map(([, n]) => n);
  if (!/^\d{5}$/.test(String(c.cp ?? '').trim()) && !faltan.includes('código postal')) faltan.push('código postal de 5 dígitos');
  const tel = digitos(c.telefono).slice(-10);
  if (tel.length !== 10) faltan.push('teléfono de 10 dígitos');
  if (faltan.length) throw new Aviso('DOMICILIO', `Al domicilio de la clienta le falta: ${faltan.join(', ')}.`);
  const nombre = corto(`${c.nombre || ''} ${c.apellidos || ''}`, 30);
  return {
    name: nombre, company: corto(`${c.nombre || ''} ${c.apellidos || ''}`, 60),
    street1: corto(`${c.calle} ${c.numero}${c.interior ? ' Int. ' + c.interior : ''}`, 45),
    phone: tel, email: corto(c.correo || cfg.correo_destino || de.email, 80),
    reference: corto(c.referencia || 'Sin referencia', 40),
    further_information: corto(c.referencia || '', 70),
    postal_code: String(c.cp).trim(), area_level1: corto(c.estado, 60), area_level2: corto(c.ciudad, 60), area_level3: corto(c.colonia, 60), country_code: 'MX',
  };
}

// ---------- Comprar ----------
function datosEnvio(d: any) {
  const at = (d.data && d.data.attributes) || {};
  const paquetes = (d.included || []).filter((x: any) => x && /package/i.test(String(x.type || '')) && x.attributes).map((x: any) => x.attributes);
  const p = paquetes[0] || {};
  return {
    id: String((d.data && d.data.id) || at.id || ''),
    estado: String(at.workflow_status || ''),
    guia: String(p.tracking_number || at.master_tracking_number || ''),
    etiqueta: String(p.label_url || ''),
    rastreo: String(p.tracking_url_provider || ''),
    total: at.total == null ? null : Number(at.total),
    paqueteria: String(at.carrier_name || ''),
    error: at.error_detail && (at.error_detail.error_message || at.error_detail.error_code)
      ? corto([at.error_detail.error_message, at.error_detail.error_message_detail].filter(Boolean).join(' · '), 300) : '',
  };
}
const FALLO = /fail|error|cancel|reject/i;
async function esperarGuia(envioId: string, vueltas: number) {
  let e = datosEnvio({});
  for (let i = 0; i < vueltas; i++) {
    const r = await sky('GET', `/api/v1/shipments/${envioId}`);
    if (r.ok) {
      e = datosEnvio(r.d);
      if (e.etiqueta || FALLO.test(e.estado) || e.error) break;
    }
    await espera(2000);
  }
  return e;
}
async function guardarCompra(adm: SupabaseClient, fila: any, e: ReturnType<typeof datosEnvio>, quien: string) {
  const elegida = (fila.tarifas || []).find((t: any) => t.id === fila.tarifa_id) || {};
  const cambios: Record<string, unknown> = {
    envio_id: e.id || fila.envio_id, guia: e.guia || fila.guia, etiqueta_url: e.etiqueta || fila.etiqueta_url, rastreo_url: e.rastreo || fila.rastreo_url,
    costo: e.total ?? fila.costo, error: null,
  };
  if (e.etiqueta) Object.assign(cambios, { estado: 'comprada', comprada_en: fila.comprada_en || new Date().toISOString(), comprada_por: fila.comprada_por || quien });
  const { data: nueva, error } = await adm.from('envios_skydrop').update(cambios).eq('id', fila.id).select().single();
  if (error) throw error;
  if (nueva.guia) {
    await adm.from('asignaciones').update({
      paqueteria: fila.paqueteria || elegida.paqueteria || e.paqueteria, guia: nueva.guia, costo_envio: nueva.costo,
      peso_kg: fila.peso_kg, medidas: `${fila.largo}×${fila.ancho}×${fila.alto}`,
    }).eq('id', fila.asignacion_id).neq('estado', 'enviada');
  }
  if (e.etiqueta && fila.estado !== 'comprada') {
    // Aviso al Supervisor: la guía ya está comprada y lista para imprimir
    await adm.from('avisos').insert({
      tipo: 'caja', clave: `guia-comprada:${fila.id}`,
      titulo: `🖨️ Guía lista para imprimir · ${corto((fila.destino && fila.destino.company) || '', 40)}`,
      cuerpo: corto(`${nueva.paqueteria || ''} ${nueva.servicio || ''} · guía ${nueva.guia || ''} · $${Number(nueva.costo || 0).toFixed(2)} · la autorizó ${String(quien).split('@')[0]}. Ábrela en Cajas → Falta guía.`, 200),
      url: `index.html#/salida/${fila.asignacion_id}`, para_rol: 'supervisor',
    });
  }
  return nueva;
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'metodo' }, 405);

  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const adm = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } });
  let c: any = {};
  try { c = await req.json(); } catch { return json({ error: 'DATOS', mensaje: 'Solicitud incompleta.' }); }
  const accion = String(c.accion || '');

  try {
    const cfg = await config(adm);

    // Diagnóstico al instalar (sin cuenta de persona): solo consultas y cotización suelta, nunca compra.
    const llave = req.headers.get('x-llave-prueba') || '';
    if (llave) {
      if (!cfg.llave_prueba || llave !== cfg.llave_prueba) return json({ error: 'sin_acceso' });
      if (accion === 'estado') return json({ listo: !!(ID && SECRETO), host: HOST, ...(ID && SECRETO ? await saldo() : {}), origen: ID && SECRETO ? await origen(adm, cfg) : null });
      if (accion === 'plantillas') return json((await sky('GET', '/api/v1/address_templates?per_page=20')).d);
      if (accion === 'catalogo') {
        const q = c.codigo ? `consignment_note=${encodeURIComponent(c.codigo)}` : `description=${encodeURIComponent(String(c.descripcion || 'ropa'))}`;
        return json({ carta_porte: (await sky('GET', `/api/v1/shipments/consignment_notes?per_page=20&${q}`)).d, empaques: (await sky('GET', '/api/v1/shipments/packagings?per_page=20')).d });
      }
      if (accion === 'cotizar_prueba') {
        const de = await origen(adm, cfg);
        return json(await cotizarSky(de, c.para, paquete(c)));
      }
      return json({ error: 'sin_acceso' });
    }

    const sb = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }, auth: { persistSession: false },
    });
    const { data: rol } = await sb.rpc('mi_rol');
    if (!rol || !PUEDEN.includes(rol)) return json({ error: 'SIN_PERMISO', mensaje: 'Solo el Supervisor o una Dueña pueden cotizar guías.' });
    const { data: u } = await sb.auth.getUser();
    const quien = corto(c.usuario, 80) || (u && u.user && u.user.email) || rol;

    if (accion === 'estado') {
      if (!ID || !SECRETO) return json({ listo: false });
      return json({ listo: true, ...(await saldo()) });
    }

    if (accion === 'cotizar') {
      const { a, c: clienta } = await cajaPorEnviar(adm, String(c.asignacion || ''));
      const { data: viva } = await adm.from('envios_skydrop').select('id').eq('asignacion_id', a.id).in('estado', ['comprando', 'comprada']).limit(1);
      if (viva && viva.length) throw new Aviso('YA_COMPRADA', 'Este pedido ya tiene una guía comprada. Actualiza la pantalla.');
      const p = paquete(c);
      const de = await origen(adm, cfg);
      const para = destino(clienta, cfg, de);
      const q = await cotizarSky(de, para, p);
      if (!q.tarifas.length) throw new Aviso('SIN_TARIFAS', q.completa ? 'Ninguna paquetería dio precio para ese domicilio, peso y medidas. Revisa el código postal y la colonia.' : 'Skydrop tardó en responder. Intenta cotizar de nuevo.');
      const { data: fila, error } = await adm.from('envios_skydrop').insert({
        asignacion_id: a.id, estado: 'cotizada', cotizacion_id: q.id, tarifas: q.tarifas,
        peso_kg: p.peso_kg, largo: p.largo, ancho: p.ancho, alto: p.alto, destino: para, cotizada_por: quien,
      }).select('id').single();
      if (error) throw error;
      await adm.from('envios_skydrop').delete().eq('asignacion_id', a.id).eq('estado', 'cotizada').neq('id', fila.id);
      if (rol !== AUTORIZA) {
        await adm.from('avisos').insert({
          tipo: 'caja', clave: `guia-autorizar:${fila.id}`,
          titulo: `🧾 Guía por autorizar · ${corto(para.company, 40)}`,
          cuerpo: corto(`${q.tarifas.length} ${q.tarifas.length === 1 ? 'opción' : 'opciones'} desde $${q.tarifas[0].total.toFixed(2)} · ${p.peso_kg} kg, ${p.largo}×${p.ancho}×${p.alto} cm · cotizó ${String(quien).split('@')[0]}. Elige la paquetería en Cajas.`, 200),
          url: `index.html#/salida/${a.id}`, para_rol: AUTORIZA,
        });
      }
      return json({ envio: fila.id, tarifas: q.tarifas, completa: q.completa, ...(await saldo()) });
    }

    if (accion === 'comprar') {
      if (rol !== AUTORIZA) throw new Aviso('SOLO_DUENA', 'La compra de la guía la autoriza una Dueña.');
      const { data: fila } = await adm.from('envios_skydrop').select('*').eq('id', String(c.envio || '')).maybeSingle();
      if (!fila) throw new Aviso('NO_EXISTE', 'Esa cotización ya no existe. Cotiza de nuevo.');
      const t = (fila.tarifas || []).find((x: any) => x.id === String(c.tarifa || ''));
      if (!t) throw new Aviso('DATOS', 'Elige una de las opciones de la cotización.');
      if (c.total == null || Math.abs(Number(c.total) - t.total) > 0.005) throw new Aviso('PRECIO', 'El precio cambió. Cotiza de nuevo.');
      if (Date.now() - new Date(fila.cotizada_en).getTime() > HORAS_TARIFA * 3600_000) throw new Aviso('VENCIDA', 'Esa cotización ya venció. Cotiza de nuevo.');
      if (!cfg.carta_porte) throw new Aviso('SIN_CONFIGURAR', 'Falta terminar la configuración de Skydrop (código del contenido). Avísale a quien administra el sistema.');
      await cajaPorEnviar(adm, fila.asignacion_id);
      const de = await origen(adm, cfg);

      // Candado: solo una solicitud pasa de "cotizada" a "comprando" (y solo una guía viva por caja)
      const { data: tomada, error: eToma } = await adm.from('envios_skydrop')
        .update({ estado: 'comprando', tarifa_id: t.id, paqueteria: t.paqueteria, servicio: t.servicio, dias: t.dias, costo: t.total, comprada_por: quien, comprada_en: new Date().toISOString() })
        .eq('id', fila.id).eq('estado', 'cotizada').select().maybeSingle();
      if (eToma || !tomada) throw new Aviso('YA_COMPRADA', 'Este pedido ya tiene una guía comprada o en proceso. Actualiza la pantalla.');

      const { address_template_id, postal_code: _cp, area_level1: _a1, area_level2: _a2, area_level3: _a3, country_code: _cc, ...remitente } = de;
      const { postal_code: _p, area_level1: _b1, area_level2: _b2, area_level3: _b3, country_code: _pc, ...destinatario } = fila.destino;
      let r;
      try {
        r = await sky('POST', '/api/v1/shipments/', {
          shipment: {
            rate_id: t.id, unique_shipment: true, printing_format: cfg.formato,
            address_from: { ...(address_template_id ? { address_template_id } : {}), ...remitente },
            address_to: destinatario,
            packages: [{ package_number: '1', package_protected: false, consignment_note: cfg.carta_porte, package_type: cfg.tipo_empaque }],
          },
        });
      } catch (x) {
        // Se cortó la comunicación: no se sabe si Skydrop recibió la compra. Queda "en proceso" para revisarla.
        console.error('skydrop compra sin respuesta:', x);
        throw new Aviso('EN_PROCESO', 'Se cortó la comunicación con Skydrop y no se supo si la compra pasó. Toca "Revisar" en un minuto antes de intentar otra vez.');
      }
      if (!r.ok) {
        const motivo = errorSky(r);
        // 409: Skydrop sigue procesando una solicitud igual; no se sabe si cobró → se deja "comprando" para revisarla
        if (r.status !== 409) await adm.from('envios_skydrop').update({ estado: 'fallida', error: motivo }).eq('id', fila.id);
        throw new Aviso('SKYDROP', /fondos|insuf|saldo|credit/i.test(motivo) ? `No alcanza el saldo de Skydrop para esta guía. ${motivo}` : motivo);
      }
      let e = datosEnvio(r.d);
      await adm.from('envios_skydrop').update({ envio_id: e.id }).eq('id', fila.id);
      if (!e.etiqueta && e.id && !FALLO.test(e.estado)) e = await esperarGuia(e.id, 18);
      if (FALLO.test(e.estado) || e.error) {
        await adm.from('envios_skydrop').update({ estado: 'fallida', error: e.error || `Skydrop no generó la guía (${e.estado}).`, envio_id: e.id }).eq('id', fila.id);
        throw new Aviso('SKYDROP', e.error || 'La paquetería no generó la guía. No se hizo el cobro o Skydrop lo regresa: revisa tu saldo.');
      }
      const nueva = await guardarCompra(adm, { ...tomada, envio_id: e.id }, e, quien);
      return json({ envio: nueva, ...(await saldo()) });
    }

    if (accion === 'revisar') {
      const { data: fila } = await adm.from('envios_skydrop').select('*').eq('id', String(c.envio || '')).maybeSingle();
      if (!fila || !['comprando', 'comprada'].includes(fila.estado)) throw new Aviso('NO_EXISTE', 'No hay una guía en proceso para revisar.');
      if (!fila.envio_id) {
        // La compra se cortó antes de saber si Skydrop la recibió: se suelta para poder cotizar otra vez
        if (Date.now() - new Date(fila.comprada_en || fila.cotizada_en).getTime() < 2 * 60_000) throw new Aviso('ESPERA', 'La compra sigue en proceso. Espera un minuto y vuelve a revisar.');
        await adm.from('envios_skydrop').update({ estado: 'fallida', error: 'No se supo si Skydrop recibió la compra. Revisa en Skydrop si aparece la guía antes de comprar otra.' }).eq('id', fila.id);
        throw new Aviso('REVISA_SKYDROP', 'No se supo si Skydrop recibió la compra. Entra a Skydrop y revisa si la guía aparece antes de comprar otra.');
      }
      const e = await esperarGuia(fila.envio_id, 4);
      if (FALLO.test(e.estado) || e.error) {
        await adm.from('envios_skydrop').update({ estado: 'fallida', error: e.error || `Skydrop no generó la guía (${e.estado}).` }).eq('id', fila.id);
        throw new Aviso('SKYDROP', e.error || 'La paquetería no generó la guía.');
      }
      return json({ envio: await guardarCompra(adm, fila, e, quien) });
    }

    if (accion === 'cancelar') {
      if (rol !== AUTORIZA) throw new Aviso('SOLO_DUENA', 'Solo una Dueña puede cancelar una guía comprada.');
      const { data: fila } = await adm.from('envios_skydrop').select('*').eq('id', String(c.envio || '')).maybeSingle();
      if (!fila || fila.estado !== 'comprada' || !fila.envio_id) throw new Aviso('NO_EXISTE', 'No hay una guía comprada que cancelar.');
      const { data: a } = await adm.from('asignaciones').select('estado, guia').eq('id', fila.asignacion_id).maybeSingle();
      if (a && a.estado === 'enviada') throw new Aviso('YA_ENVIADA', 'Ese pedido ya se marcó como enviado: la guía ya no se cancela desde aquí.');
      const r = await sky('POST', `/api/v1/shipments/${fila.envio_id}/cancellations`, { reason: corto(c.motivo || 'Ya no es necesario', 120), shipment_id: fila.envio_id });
      if (!r.ok || r.d.success === false) throw new Aviso('SKYDROP', `Skydrop no aceptó la cancelación: ${errorSky(r)}`);
      await adm.from('envios_skydrop').update({ estado: 'cancelada', cancelada_en: new Date().toISOString(), cancelada_por: quien }).eq('id', fila.id);
      if (a && a.guia === fila.guia) {
        await adm.from('asignaciones').update({ paqueteria: null, guia: null, costo_envio: null, guia_impresa_en: null, guia_impresa_por: null, guia_pegada_en: null, guia_pegada_por: null, entrega: null })
          .eq('id', fila.asignacion_id).neq('estado', 'enviada');
      }
      return json({ cancelada: true, estado_skydrop: r.d.status || null, ...(await saldo()) });
    }

    return json({ error: 'DATOS', mensaje: 'Acción desconocida.' });
  } catch (e) {
    if (e instanceof Aviso) return json({ error: e.codigo, mensaje: e.message });
    console.error('skydrop:', e);
    return json({ error: 'FALLA', mensaje: 'No se pudo completar. Intenta de nuevo.' });
  }
});
