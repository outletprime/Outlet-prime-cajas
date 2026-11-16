#!/bin/bash
# Doble clic en Mac: escribe comentarios de prueba sin estar en vivo
cd "$(dirname "$0")"
[ -d node_modules ] || npm install --omit=dev
[ -f config.json ] || { echo "Falta config.json (ver LEEME.md)."; read -r; exit 1; }
node src/agente.js --simulador
