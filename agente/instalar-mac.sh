#!/bin/bash
# Outlet Prime · Instalador del agente del live para Mac
#
# Se usa pegando en la Terminal:
#   curl -fsSL https://raw.githubusercontent.com/outletprime/Outlet-prime-cajas/claude/outlet-prime-cajas-github-o5jydp/agente/instalar-mac.sh | bash
#
# Hace todo: instala Node.js (si falta), descarga el agente en Documentos/OutletPrime-agente,
# pregunta los datos (correo y contraseña del agente, llave de la IA, usuario de TikTok),
# instala lo necesario, revisa que todo funcione y deja "Iniciar agente" en el Escritorio.
# Se puede volver a correr para actualizar: conserva los datos ya escritos.
set -e

REPO="outletprime/Outlet-prime-cajas"
RAMA="claude/outlet-prime-cajas-github-o5jydp"
DESTINO="$HOME/Documents/OutletPrime-agente"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rosa() { printf '\033[95m\033[1m%s\033[0m\n' "$1"; }
verde() { printf '\033[32m%s\033[0m\n' "$1"; }
rojo() { printf '\033[31m%s\033[0m\n' "$1"; }
pregunta() { # pregunta "Texto" variable [secreto]
  local r
  while true; do
    if [ "$3" = "secreto" ]; then read -r -s -p "$1: " r </dev/tty; echo; else read -r -p "$1: " r </dev/tty; fi
    [ -n "$r" ] && break
    echo "   (no puede quedar vacío)"
  done
  eval "$2=\$r"
}

rosa ""
rosa "  Outlet Prime · Instalación del agente del live"
rosa ""

# 1. Node.js -----------------------------------------------------------------
version_node() { command -v node >/dev/null 2>&1 && node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }
if [ "$(version_node)" -lt 20 ]; then
  echo "1/5 · Instalando Node.js. La Mac te pedirá TU contraseña de la computadora (no se ve al escribirla)."
  PKG="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt | awk '/\.pkg$/ {print $2}' | head -1)"
  SUMA="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt | awk -v f="$PKG" '$2 == f {print $1}')"
  [ -n "$PKG" ] || { rojo "No pude encontrar Node.js para descargar. Revisa el internet e intenta otra vez."; exit 1; }
  curl -fSL --progress-bar "https://nodejs.org/dist/latest-v22.x/$PKG" -o "$TMP/$PKG"
  if [ "$(shasum -a 256 "$TMP/$PKG" | awk '{print $1}')" != "$SUMA" ]; then rojo "La descarga de Node.js llegó dañada. Intenta otra vez."; exit 1; fi
  sudo installer -pkg "$TMP/$PKG" -target / >/dev/null
  export PATH="/usr/local/bin:$PATH"
  verde "   ✓ Node.js $(node -v) instalado"
else
  verde "1/5 · Node.js $(node -v) ya estaba instalado"
fi

# 2. Descargar el agente -----------------------------------------------------
echo "2/5 · Descargando el agente…"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$RAMA" -o "$TMP/repo.tgz"
tar -xzf "$TMP/repo.tgz" -C "$TMP"
ORIGEN="$(ls -d "$TMP"/*/agente | head -1)"
[ -d "$ORIGEN" ] || { rojo "No encontré la carpeta del agente en la descarga."; exit 1; }
ANON="$(sed -n "s/.*supabaseAnonKey: *'\([^']*\)'.*/\1/p" "$(dirname "$ORIGEN")/config.js")"
URL="$(sed -n "s/.*supabaseUrl: *'\([^']*\)'.*/\1/p" "$(dirname "$ORIGEN")/config.js")"
mkdir -p "$DESTINO"
[ -f "$DESTINO/config.json" ] && cp "$DESTINO/config.json" "$TMP/config.guardado.json"
rm -rf "$DESTINO/src" "$DESTINO/prueba"
cp -R "$ORIGEN"/. "$DESTINO"/
[ -f "$TMP/config.guardado.json" ] && cp "$TMP/config.guardado.json" "$DESTINO/config.json"
chmod +x "$DESTINO"/*.command
verde "   ✓ Agente en Documentos/OutletPrime-agente"

# 3. Datos -------------------------------------------------------------------
cd "$DESTINO"
if [ -f config.json ]; then
  verde "3/5 · Ya tenías tus datos guardados; los conservo."
else
  echo "3/5 · Tus datos (se guardan solo en esta Mac, en config.json):"
  pregunta "   Correo del usuario del agente en Supabase" CORREO
  pregunta "   Contraseña de ese usuario (no se ve al escribir)" CONTRASENA secreto
  pregunta "   Llave de la IA de Anthropic, empieza con sk-ant (no se ve al escribir)" LLAVE secreto
  pregunta "   Usuario de TikTok de la tienda (sin @)" TIKTOK
  CORREO="$CORREO" CONTRASENA="$CONTRASENA" LLAVE="$LLAVE" TIKTOK="${TIKTOK#@}" ANON="$ANON" URL="$URL" node -e '
    const fs = require("fs");
    const c = JSON.parse(fs.readFileSync("config.ejemplo.json", "utf8"));
    c.supabase = { url: process.env.URL, anonKey: process.env.ANON, correo: process.env.CORREO.trim(), contrasena: process.env.CONTRASENA };
    c.ia.apiKey = process.env.LLAVE.trim();
    c.redes.tiktok.usuario = process.env.TIKTOK.trim();
    fs.writeFileSync("config.json", JSON.stringify(c, null, 2) + "\n", { mode: 0o600 });'
  verde "   ✓ Datos guardados"
fi

# 4. Instalar lo que usa el agente -------------------------------------------
echo "4/5 · Instalando lo que usa el agente (1–2 minutos)…"
NPM_CONFIG_UPDATE_NOTIFIER=false npm install --omit=dev --no-audit --no-fund --loglevel=error >/dev/null
verde "   ✓ Listo"

# 5. Acceso en el Escritorio y revisión ---------------------------------------
cat > "$HOME/Desktop/Iniciar agente.command" <<EOF
#!/bin/bash
cd "$DESTINO" && ./"Iniciar agente.command"
EOF
chmod +x "$HOME/Desktop/Iniciar agente.command"
echo "5/5 · Revisando que todo funcione…"
echo
if node src/agente.js --verificar; then
  echo
  rosa "Instalación terminada. En el Escritorio quedó \"Iniciar agente\": dale doble clic antes de cada live."
else
  echo
  rojo "La instalación quedó, pero hay algo por corregir (arriba). Para cambiar tus datos borra"
  rojo "Documentos/OutletPrime-agente/config.json y vuelve a pegar el comando de instalación."
fi
