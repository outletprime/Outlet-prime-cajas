@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Outlet Prime - Agente del live
where node >nul 2>nul || (echo Falta instalar Node.js: https://nodejs.org ^(version LTS^) & pause & exit /b)
if not exist node_modules (echo Instalando por primera vez, espera un momento... & call npm install --omit=dev)
if not exist config.json (echo Falta config.json: copia config.ejemplo.json como config.json y llenalo. Ver LEEME.md & pause & exit /b)
node src\agente.js %*
pause
