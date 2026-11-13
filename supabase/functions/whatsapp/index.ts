// Conector entre WhatsApp Business (Cloud API de Meta) y el bot del live.
//
// - GET  : verificación del webhook que hace Meta al configurarlo.
// - POST : Meta avisa cada mensaje nuevo → se llama a bot_mensaje() en la base → se envían las respuestas.
// - POST ?enviar=1 con el encabezado x-clave-envio : solo envía la cola (cobros, recordatorios).
//
// Secretos que hay que guardar en Supabase (Edge Functions → Secrets) al conectar el número:
//   WHATSAPP_TOKEN            token permanente del usuario de sistema de Meta
//   WHATSAPP_PHONE_NUMBER_ID  identificador del número del bot
//   WHATSAPP_VERIFY_TOKEN     palabra secreta que tú inventas y pones igual en Meta
//   WHATSAPP_APP_SECRET       "App secret" de la app de Meta (para validar que el aviso viene de Meta)
//   ENVIO_SECRETO             palabra secreta para el envío programado de la cola
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY ya existen solos dentro de las Edge Functions.

import { createClient } from 'npm:@supabase/supabase-js@2.49.4';

const env = (k: string) => Deno.env.get(k) ?? '';
const sb = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const GRAPH = 'https://graph.facebook.com/v21.0';
const MINUTOS_MAXIMOS = 30; // un mensaje que no salió en 30 minutos ya no se manda

function igualesSeguro(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

async function firmaDeMetaValida(cuerpo: string, encabezado: string | null) {
  const secreto = env('WHATSAPP_APP_SECRET');
  if (!secreto || !encabezado?.startsWith('sha256=')) return false;
  const llave = await crypto.subtle.importKey('raw', new TextEncoder().encode(secreto), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const firma = new Uint8Array(await crypto.subtle.sign('HMAC', llave, new TextEncoder().encode(cuerpo)));
  const hex = [...firma].map(b => b.toString(16).padStart(2, '0')).join('');
  return igualesSeguro(hex, encabezado.slice(7));
}

function textoDelMensaje(m: any): string {
  switch (m.type) {
    case 'text': return m.text?.body ?? '';
    case 'button': return m.button?.text ?? '';
    case 'interactive': return m.interactive?.button_reply?.title ?? m.interactive?.list_reply?.title ?? '';
    default: return ''; // audio, sticker, foto: el bot contesta con la ayuda
  }
}

async function enviarUno(telefono: string, texto: string) {
  const r = await fetch(`${GRAPH}/${env('WHATSAPP_PHONE_NUMBER_ID')}/messages`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${env('WHATSAPP_TOKEN')}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ messaging_product: 'whatsapp', to: '52' + telefono, type: 'text', text: { body: texto, preview_url: false } }),
  });
  if (!r.ok) throw new Error(`Meta respondió ${r.status}: ${(await r.text()).slice(0, 300)}`);
}

async function enviarPendientes() {
  const corte = new Date(Date.now() - MINUTOS_MAXIMOS * 60_000).toISOString();
  await sb.from('wa_mensajes').update({ estado: 'caducado' }).eq('estado', 'pendiente').lt('creado_en', corte);

  const { data: cola, error } = await sb.from('wa_mensajes')
    .select('id, telefono, texto').eq('estado', 'pendiente').order('creado_en', { ascending: true }).limit(80);
  if (error) throw error;

  let enviados = 0;
  for (const m of cola ?? []) {
    // Se "aparta" el mensaje antes de mandarlo, para que dos envíos simultáneos no lo dupliquen
    const { data: tomado } = await sb.from('wa_mensajes')
      .update({ estado: 'enviado', enviado_en: new Date().toISOString() })
      .eq('id', m.id).eq('estado', 'pendiente').select('id');
    if (!tomado?.length) continue;
    try {
      await enviarUno(m.telefono, m.texto);
      enviados++;
    } catch (e) {
      await sb.from('wa_mensajes').update({ estado: 'error', error: String(e).slice(0, 500) }).eq('id', m.id);
      console.error('No se pudo enviar', m.id, e);
    }
  }
  return enviados;
}

Deno.serve(async req => {
  const url = new URL(req.url);

  // 1. Meta verifica el webhook al configurarlo
  if (req.method === 'GET') {
    const ok = url.searchParams.get('hub.mode') === 'subscribe'
      && env('WHATSAPP_VERIFY_TOKEN') !== ''
      && url.searchParams.get('hub.verify_token') === env('WHATSAPP_VERIFY_TOKEN');
    return ok ? new Response(url.searchParams.get('hub.challenge') ?? '') : new Response('No autorizado', { status: 403 });
  }
  if (req.method !== 'POST') return new Response('Método no permitido', { status: 405 });

  // 2. Envío programado de la cola (cobros, recordatorios, avisos de lista de espera)
  if (url.searchParams.get('enviar') === '1') {
    const clave = req.headers.get('x-clave-envio') ?? '';
    if (!env('ENVIO_SECRETO') || !igualesSeguro(clave, env('ENVIO_SECRETO'))) return new Response('No autorizado', { status: 401 });
    const enviados = await enviarPendientes();
    return Response.json({ enviados });
  }

  // 3. Mensajes nuevos de las clientas
  const cuerpo = await req.text();
  if (!(await firmaDeMetaValida(cuerpo, req.headers.get('x-hub-signature-256')))) {
    return new Response('Firma inválida', { status: 401 });
  }
  let aviso: any;
  try { aviso = JSON.parse(cuerpo); } catch { return new Response('JSON inválido', { status: 400 }); }

  for (const entrada of aviso.entry ?? []) {
    for (const cambio of entrada.changes ?? []) {
      const v = cambio.value ?? {};
      const nombres: Record<string, string> = Object.fromEntries((v.contacts ?? []).map((c: any) => [c.wa_id, c.profile?.name ?? '']));
      for (const m of v.messages ?? []) {
        const { error } = await sb.rpc('bot_mensaje', {
          p_telefono: m.from,
          p_texto: textoDelMensaje(m),
          p_nombre: nombres[m.from] || null,
          p_wa_id: m.id,
          p_recibido: new Date(Number(m.timestamp) * 1000).toISOString(),
        });
        if (error) console.error('bot_mensaje falló', m.id, error.message);
      }
    }
  }

  try { await enviarPendientes(); } catch (e) { console.error('Envío de la cola falló', e); }
  // A Meta siempre se le contesta 200 para que no reintente sin fin; los errores quedan en el registro.
  return new Response('ok');
});
