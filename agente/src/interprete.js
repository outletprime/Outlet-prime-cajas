// Decide si un comentario del live es un pedido y qué números de prenda pide.
//
// 1. Reglas (al instante): comentarios claros como "23", "la 23", "quiero la 23 y 45", "#0310 porfa".
// 2. IA (Claude): lo que no es tan claro ("me llevo la veintitrés", "yo la 45 y la de al lado no",
//    "¿la 23 qué talla es?"). Solo se le pregunta si el comentario trae números o números con letra.
// 3. Todo lo demás ("hola", "qué bonito") se ignora sin gastar.

const RELLENO = new Set([
  'la', 'el', 'las', 'los', 'lo', 'yo', 'quiero', 'quisiera', 'me', 'llevo', 'mia', 'mio', 'mias', 'mios',
  'porfa', 'porfavor', 'por', 'favor', 'pf', 'plis', 'pls', 'please', 'aparta', 'apartame', 'apartar',
  'aparto', 'apartado', 'apartada', 'dame', 'pido', 'y', 'e', 'tambien', 'numero', 'num', 'nro',
  'prenda', 'prendas', 'mi', 'si', 'sii', 'siii', 'va', 'ok', 'ya', 'ahi', 'aqui', 'a', 'de', 'del', 'para',
  'gracias', 'hola', 'amiga', 'reina', 'hermosa', 'bella', 'linda', 'guapa', 'nena',
]);

const NUMEROS_LETRA = /\b(cero|uno|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce|trece|catorce|quince|dieci\w*|veint\w*|treinta|cuarenta|cincuenta|sesenta|setenta|ochenta|noventa|cien|ciento|\w+cientos|quinientos|setecientos|novecientos|mil)\b/;

export function normalizar(texto) {
  return String(texto ?? '')
    .toLowerCase()
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

// Números de 1 a 5 cifras que aparecen escritos con dígitos (sin teléfonos ni cantidades enormes)
export function numerosEnTexto(texto) {
  const t = normalizar(texto);
  const out = [];
  for (const m of t.matchAll(/(?<![0-9])([0-9]{1,5})(?![0-9])/g)) {
    const n = parseInt(m[1], 10);
    if (n >= 1 && n <= 99999 && !out.includes(n)) out.push(n);
  }
  return out;
}

export function tieneNumeroConLetra(texto) {
  return NUMEROS_LETRA.test(normalizar(texto));
}

// { tipo: 'apartar' | 'ignorar' | 'dudoso', prendas: [] }
export function interpretarReglas(texto) {
  const t = normalizar(texto);
  if (!t) return { tipo: 'ignorar', prendas: [] };
  const nums = numerosEnTexto(t);

  if (nums.length === 0) {
    return tieneNumeroConLetra(t) ? { tipo: 'dudoso', prendas: [] } : { tipo: 'ignorar', prendas: [] };
  }
  // Preguntas, precios, tallas, horas, teléfonos o cantidades: que lo vea la IA
  if (/[?¿$]|talla|cuanto|cuesta|precio|hora|whats|tel|cel|\d\s*:\s*\d|\d{6,}|x\s*\d|\d\s*(pz|piezas|pzas|kg|cm|mx|mxn|pesos)\b/.test(t)) {
    return { tipo: 'dudoso', prendas: [] };
  }
  // Separa "la23" → "la 23" y quita signos y emojis
  const tokens = t
    .replace(/([a-z])([0-9])/g, '$1 $2').replace(/([0-9])([a-z])/g, '$1 $2')
    .replace(/[#,;.!¡+&/\-_*()"'“”]/g, ' ')
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .split(' ').filter(Boolean);
  const claro = tokens.every(w => /^[0-9]{1,5}$/.test(w) || RELLENO.has(w) || /^(j|a|e)+$/.test(w));
  return claro ? { tipo: 'apartar', prendas: nums.slice(0, 10) } : { tipo: 'dudoso', prendas: [] };
}

// Lo que diga la IA solo vale si los números están en el comentario (o venían escritos con letra):
// así un comentario tramposo no puede apartar prendas que no escribió.
export function validarRespuestaIA(texto, respuesta) {
  if (!respuesta || respuesta.tipo !== 'apartar' || !Array.isArray(respuesta.prendas)) return [];
  const escritos = numerosEnTexto(texto);
  const conLetra = tieneNumeroConLetra(texto);
  const ok = [];
  for (const x of respuesta.prendas) {
    const n = Number(x);
    if (!Number.isInteger(n) || n < 1 || n > 99999 || ok.includes(n)) continue;
    if (escritos.includes(n) || conLetra) ok.push(n);
  }
  return ok.slice(0, 10);
}
