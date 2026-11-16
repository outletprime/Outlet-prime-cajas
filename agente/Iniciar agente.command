#!/bin/bash
# Doble clic en Mac para encender el agente del live
cd "$(dirname "$0")"
command -v node >/dev/null || { echo "Falta instalar Node.js: https://nodejs.org (versión LTS)"; read -r; exit 1; }
[ -d node_modules ] || { echo "Instalando por primera vez, espera un momento..."; npm install --omit=dev; }
[ -f config.json ] || { echo "Falta config.json: copia config.ejemplo.json como config.json y llénalo (ver LEEME.md)."; read -r; exit 1; }
node src/agente.js "$@"
