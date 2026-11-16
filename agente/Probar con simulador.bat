@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Outlet Prime - Simulador de comentarios
if not exist node_modules (call npm install --omit=dev)
node src\agente.js --simulador
pause
