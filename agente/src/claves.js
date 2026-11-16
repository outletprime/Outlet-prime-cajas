// Claves de prenda: de A1 a ZY98 (igual que en la base de datos, funciones clave_a_num / num_a_clave).
//   · letras sin O, I, L ni Ñ          · dos letras siempre distintas (AB sí, AA no)
//   · números 1 a 98 sin dígitos repetidos (11, 22 … 88 y 99 no existen)
// Cada clave equivale a un número interno 1..52371 (prendas.numero).

const LETRAS = 'ABCDEFGHJKMNPQRSTUVWXYZ';

export function claveANum(texto) {
  const s = String(texto ?? '').toUpperCase().replace(/[\s#-]/g, '');
  const m = s.match(/^([A-Z]{1,2})([0-9]{1,2})$/);
  if (!m) return null;
  const n = parseInt(m[2], 10);
  if (n < 1 || n > 98 || n % 11 === 0) return null;
  const a = LETRAS.indexOf(m[1][0]);
  if (a < 0) return null;
  if (m[1].length === 1) return a * 99 + n;
  let b = LETRAS.indexOf(m[1][1]);
  if (b < 0 || b === a) return null;
  if (b > a) b -= 1;
  return 2277 + (a * 22 + b) * 99 + n;
}

export function numAClave(p) {
  if (!Number.isInteger(p) || p < 1 || p > 52371) return null;
  if (p <= 2277) return LETRAS[Math.floor((p - 1) / 99)] + ((p - 1) % 99 + 1);
  let k = p - 2278;
  const n = (k % 99) + 1;
  k = Math.floor(k / 99);
  const a = Math.floor(k / 22);
  let b = k % 22;
  if (b >= a) b += 1;
  return LETRAS[a] + LETRAS[b] + n;
}

// Claves escritas en un texto ("A23", "ab7", "AB-7"); con espacio ("ab 12") solo si es todo el texto.
// Devuelve [{ clave: 'AB7', num: 2284, texto: 'ab7' }] sin repetir, en el orden en que aparecen.
export function clavesEnTexto(texto) {
  const t = String(texto ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '');
  const out = [];
  const agregar = (letras, digitos, crudo) => {
    const num = claveANum(letras + digitos);
    if (num && !out.some(x => x.num === num)) out.push({ clave: numAClave(num), num, texto: crudo });
  };
  for (const m of t.matchAll(/(?<![\p{L}\p{N}_])([A-Za-z]{1,2})-?([0-9]{1,2})(?![\p{L}\p{N}_])/gu)) agregar(m[1], m[2], m[0]);
  if (!out.length) {
    const m = t.match(/^[^\p{L}\p{N}]*([A-Za-z]{1,2})\s+([0-9]{1,2})[^\p{L}\p{N}]*$/u);
    if (m) agregar(m[1], m[2], m[0].trim());
  }
  return out;
}
