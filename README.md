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

## Dónde vive cada cosa

| Qué | Dónde | Se pierde al actualizar la app? |
|---|---|---|
| El programa (código) | Este repositorio de GitHub | No: cada cambio queda guardado como una versión nueva. |
| Los datos (cajas, clientas, pedidos, fotos, videos) | Supabase, proyecto **outlet-prime** | No: el código solo los lee y escribe, actualizarlo no los toca. |

La app está **conectada a Supabase** (ver `APP_CONFIG` al inicio de `index.html`).
Para entrar se usa el correo y la contraseña de un usuario creado en
Supabase → Authentication → Users.

### Reglas para no perder datos

- Cambia el código aquí en GitHub con toda libertad: los datos siguen en Supabase.
- **No borres ni cambies** las tablas `cajas`, `categorias`, `clientas`, `asignaciones`,
  `pedidos` ni el bucket `archivos` desde el panel de Supabase.
- No pongas en `vistaPrevia: true`: eso activa el modo de demostración.
- La llave `anon` que está en `index.html` es pública y es seguro que esté aquí.
  **Nunca** subas la llave `service_role` ni contraseñas.
- La carpeta `supabase/esquema.sql` guarda la estructura de la base (sin datos),
  por si algún día hay que reconstruirla en otro proyecto.

## Origen

Este código se descargó del artifact "Outlet Prime Cajas" en claude.ai
(https://claude.ai/artifact/XCQHxE3Yn48fhrJrHdNAok).
