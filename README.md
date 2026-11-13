# Outlet Prime Cajas

Aplicación web para controlar las cajas de Outlet Prime: asignar cajas a clientas,
registrar pedidos por categoría (Target, Costco, Cremas, Perfumes, Calzado),
escanear el código QR de cada caja, imprimir etiquetas y ver reportes.

## Contenido

| Archivo / carpeta | Qué es |
|---|---|
| `index.html` | La aplicación completa (diseño, lógica y pantallas en un solo archivo). |
| `icons/` | Logos de Outlet Prime (claro y oscuro). |
| `cp/` | Catálogo de códigos postales de México (SEPOMEX), un archivo por los dos primeros dígitos del C.P. Sirve para llenar estado, ciudad y colonia automáticamente. |

## Cómo abrirla

La app usa `fetch` para leer los códigos postales, así que necesita servirse desde
un servidor web (no basta con hacer doble clic en `index.html`):

```bash
python3 -m http.server 8000
# luego abre http://localhost:8000
```

También se puede publicar tal cual en GitHub Pages, Netlify, Vercel o Hostinger.

## Modo prueba y modo real

En `index.html` está la configuración `APP_CONFIG`:

- Si `supabaseUrl` y `supabaseAnonKey` están vacíos, la app funciona en **modo prueba**:
  los datos se guardan solo en el navegador del dispositivo.
- Si se llenan con los datos de un proyecto de Supabase, la app usa la **base de datos
  compartida** (tablas `cajas`, `categorias`, `clientas`, `asignaciones`, `pedidos` y el
  bucket de almacenamiento `archivos`).

No subas aquí contraseñas ni la llave `service_role` de Supabase; la llave `anon` sí es pública.

## Origen

Este código se descargó del artifact "Outlet Prime Cajas" en claude.ai
(https://claude.ai/artifact/XCQHxE3Yn48fhrJrHdNAok).
