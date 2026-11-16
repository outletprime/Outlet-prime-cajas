// Decide si un comentario del live es un pedido y qué prendas pide (claves A1 … ZY98).
//
// 1. Reglas (al instante): comentarios claros como "A23", "la A23 porfa", "quiero AB7 y C15", "#B5".
// 2. IA (Claude): lo que no es tan claro ("me llevo la A veintitrés", "¿la A23 qué talla es?",
//    "ya no quiero la B5"). Solo se le pregunta si el comentario trae una clave o algo parecido.
// 3. Todo lo demás ("hola", "qué bonito") se ignora sin gastar.
import { claveANum, clavesEnTexto } from './claves.js';

const RELLENO = new Set([
  'la', 'el', 'las', 'los', 'lo', 'yo', 'quiero', 'quisiera', 'me', 'llevo', 'mia', 'mio', 'mias', 'mios',
  'porfa', 'porfavor', 'por', 'favor', 'pf', 'plis', 'pls', 'please', 'aparta', 'apartame', 'apartar',
  'aparto', 'apartado', 'apartada', 'dame', 'pido', 'y', 'e', 'tambien', 'clave', 'claves', 'numero', 'num',
  'prenda', 'prendas', 'mi', 'si', 'sii', 'siii', 'va', 'ok', 'ya', 'ahi', 'aqui', 'a', 'de', 'del', 'para',
  'gracias', 'hola', 'amiga', 'reina', 'hermosa', 'bella', 'linda', 'guapa', 'nena',
]);

const NUMEROS_LETRA = /\b(uno|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce|trece|catorce|quince|dieci\w*|veint\w*|treinta|cuarenta|cincuenta|sesenta|setenta|ochenta|noventa)\b/;

export function normalizar(texto) {
  return String(texto ?? '')
    .toLowerCase()
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

export function tieneNumeroConLetra(texto) {
  return NUMEROS_LETRA.test(normalizar(texto));
}

// { tipo: 'apartar' | 'ignorar' | 'dudoso' | 'sin_clave', prendas: [números internos], claves: ['A23'] }
export function interpretarReglas(texto) {
  const t = normalizar(texto);
  if (!t) return { tipo: 'ignorar', prendas: [], claves: [] };
  const encontradas = clavesEnTexto(t);

  if (encontradas.length === 0) {
    // ¿Algo que parece clave pero no es válida (A11, O5, AA3) o una clave dicha con palabras?
    // (una letra suelta + número, "a 23", sí puede ser clave; "la 23" no)
    const parecida = [...t.matchAll(/(?<![a-z0-9])([a-z]{1,2})(\s?-?)(\d{1,3})(?![a-z0-9])/g)]
      .some(m => m[1].length === 1 || !m[2].includes(' ') || !RELLENO.has(m[1]));
    if (parecida || tieneNumeroConLetra(t)) {
      return { tipo: 'dudoso', prendas: [], claves: [] };
    }
    // Solo números ("23"): le faltó la letra
    if (/\d/.test(t)) return { tipo: 'sin_clave', prendas: [], claves: [] };
    return { tipo: 'ignorar', prendas: [], claves: [] };
  }
  const resultado = { prendas: encontradas.map(x => x.num).slice(0, 10), claves: encontradas.map(x => x.clave).slice(0, 10) };

  // Preguntas, precios, tallas, horas, teléfonos, cancelaciones: que lo vea la IA
  if (/[?¿$]|talla|cuanto|cuesta|precio|hora|whats|tel|cel|\d\s*:\s*\d|\d{6,}|\bno\b|cancel|ya no|otra|otro|para mi (hija|mama|hermana|amiga)|(^|\s)x\s?\d/.test(t)) {
    return { tipo: 'dudoso', ...resultado };
  }
  // ¿Todo lo que queda, quitando las claves, son palabras de relleno o emojis?
  let resto = t;
  for (const x of encontradas) resto = resto.replaceAll(x.texto.toLowerCase(), ' ');
  const tokens = resto.replace(/[#,;.!¡+&/\-_*()"'“”]/g, ' ').replace(/[^\p{L}\p{N}\s]/gu, ' ').split(' ').filter(Boolean);
  const claro = tokens.every(w => RELLENO.has(w) || /^(j|a|e)+$/.test(w));
  return claro ? { tipo: 'apartar', ...resultado } : { tipo: 'dudoso', ...resultado };
}

// Lo que diga la IA solo vale si la clave está escrita en el comentario (o venía dicha con palabras):
// así un comentario tramposo no puede apartar prendas que no escribió.
export function validarRespuestaIA(texto, respuesta) {
  if (!respuesta || respuesta.tipo !== 'apartar' || !Array.isArray(respuesta.claves)) return [];
  const compacto = normalizar(texto).toUpperCase().replace(/[\s#.\-_]/g, '');
  const conPalabras = tieneNumeroConLetra(texto);
  const ok = [];
  for (const c of respuesta.claves) {
    const num = claveANum(c);
    if (!num || ok.includes(num)) continue;
    const clave = String(c).toUpperCase().replace(/[\s#-]/g, '');
    const letras = clave.replace(/[0-9]/g, '');
    const escrita = compacto.includes(clave);
    const letrasSueltas = new RegExp(`(^|[^a-z])${letras.toLowerCase()}([^a-z]|$)`).test(normalizar(texto));
    if (escrita || (conPalabras && letrasSueltas)) ok.push(num);
  }
  return ok.slice(0, 10);
}
