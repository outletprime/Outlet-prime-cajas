#!/bin/bash
# Doble clic en Mac: conecta el agente a la página de Facebook de la tienda
cd "$(dirname "$0")"
[ -d node_modules ] || npm install --omit=dev
node src/conectar-facebook.js
echo; read -r -p "Presiona Enter para cerrar…"
