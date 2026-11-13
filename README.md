# Outlet Prime · Cajas y Live

Dos apps web que comparten **una sola base de datos** (Supabase, proyecto **outlet-prime**)
y **una sola lista de clientas** (una clienta = un número de WhatsApp):

| App | Archivo | Para qué |
|---|---|---|
| **Cajas** | `index.html` | Caja fija de cada clienta, pedidos por categoría, QR, envíos y reportes. |
| **Panel del live** (equipo) | `live.html` | Lives de redes (bot de WhatsApp) y Prime Live (mayoristas), casilleros, cobros y paso automático a la caja fija. |
| **Prime Live** (mayoristas) | `prime.html` | Página exclusiva donde cada mayorista invitada entra con su contraseña y aparta con un botón. |

### Dos canales, una sola base de clientas

| | Lives en redes (TikTok / Facebook) | Prime Live |
|---|---|---|
| Para quién | Público: captación de clientas nuevas | Solo mayoristas invitadas |
| Cómo apartan | Mandan el número de la etiqueta al **bot de WhatsApp** | Botón **Apartar** sobre la foto de cada prenda, en `prime.html` |
| Acceso | Cualquiera con WhatsApp | Contraseña única por mayorista, válida solo para ese live |
| Cobro, casilleros, 3 h para pagar, caja fija | Igual | Igual (categoría **Prime Live** en Cajas) |

Las mayoristas **no tienen usuario de Supabase**: su contraseña solo les deja ver las prendas
de ese live y su propio carrito (funciones `prime_acceso`, `prime_estado` y `prime_apartar`).
Nunca ven datos de otras clientas.

Publicadas en GitHub Pages: https://outletprime.github.io/Outlet-prime-cajas/
(el panel del live está en `…/live.html`, o desde Cajas → Ajustes → Panel del live).
Las dos usan el mismo correo y contraseña de Supabase → Authentication → Users.

### Niveles de acceso del equipo

| Puede… | Dueña | Supervisor (monitor) | Operación |
|---|---|---|---|
| Ver live, casilleros, cajas y clientas; recibir avisos | ✅ | ✅ | ✅ |
| Ver reportes de ventas | ✅ | ✅ | ❌ |
| Iniciar/cerrar lives, capturar, liberar, mover prendas, registrar clientas y pedidos | ✅ | ❌ | ✅ |
| Registrar pagos | ✅ | ❌ | ❌ |
| Programar Prime Live e invitar mayoristas | ✅ | ❌ | ❌ |
| Cambiar CLABE, precios, tiempos y categorías | ✅ | ❌ | ❌ |
| Borrar cualquier cosa | ✅ | ❌ | ❌ |
| Dar o quitar accesos | ✅ | ❌ | ❌ |

- Las reglas están **en la base de datos** (`…_niveles_acceso.sql`); esconder botones es solo comodidad.
- Para agregar a alguien: Supabase → Authentication → Users → **Add user** (Auto Confirm) y después
  **Panel → Ajustes → Equipo** para asignarle nivel. Sin nivel no ve nada.
- Siempre queda al menos una dueña. Pagos, cambios de ajustes, borrados y cambios de nivel quedan
  en la **bitácora** (Panel → Ajustes → Equipo → Historial de cambios).
- Operación sí ve teléfono y dirección de las clientas porque los necesita para empacar y enviar.

## Contenido

| Archivo / carpeta | Qué es |
|---|---|
| `index.html` | App de Cajas. |
| `live.html` | Panel del live (con simulador de WhatsApp). |
| `config.js` | Conexión con Supabase, compartida por las dos apps. |
| `icons/` | Logos de Outlet Prime. |
| `cp/` | Catálogo de códigos postales de México (SEPOMEX). |
| `supabase/esquema.sql` | Estructura original de la base de Cajas (referencia, sin datos). |
| `supabase/migrations/` | Cambios a la base, en orden: `…_sistema_lives.sql` (bot y casilleros) y `…_prime_live.sql` (mayoristas). |
| `supabase/functions/whatsapp/` | Conector con WhatsApp Business (se activa cuando haya número del bot). |
| `supabase/functions/avisos/` | Envía los avisos al celular del equipo (notificaciones). |
| `sw.js`, `manifest.webmanifest` | Permiten instalar el panel como app y recibir notificaciones. |
| `docs/WHATSAPP.md` | Pasos para conectar el número de WhatsApp del bot. |

## Cómo funciona el live

1. **Etiquetar.** Cada prenda tiene un número fijo (Prendas → Registrar rango, p. ej. 3001–3200), a $89.
2. **Iniciar live** en el panel.
3. **Apartar.** La clienta manda el número por WhatsApp (`23` o `23 45 310`). Gana el primer mensaje;
   si ya está apartada, queda en lista de espera con su lugar. Si es nueva, se registra sola con su número.
4. **Casillero.** Al primer apartado se le asigna un casillero (C-001 a C-100). El panel muestra
   `0023 → C-007` y el ayudante deja ahí la prenda.
5. **Cerrar live.** El bot manda a cada clienta su total, la CLABE y su folio.
6. **Pago.** Se registra en Casilleros (a mano por ahora; automático cuando haya CLABE por pedido).
   Al pagar completo, las prendas pasan solas a su **caja fija** y se crea el pedido en Cajas
   (categoría **Live**). Si no tenía caja, se le asigna la primera libre.
7. **Sin pago.** Recordatorio a la hora, límite a las 2 h y a las 3 h se libera solo; la prenda pasa
   a la primera de la lista de espera. El panel indica "Regresar a racks".

## Cómo funciona Prime Live

1. **Programar** (Panel → En vivo → Prime Live): nombre, fecha, precio por prenda y máximo por mayorista.
2. **Invitar**: agrega mayoristas (nombre, WhatsApp, correo) e invítalas. Cada una recibe una contraseña
   única para ese live; se la mandas con los botones **WhatsApp** o **Correo**.
3. **Iniciar** y **capturar**: el equipo toma la foto de cada prenda y la publica (talla opcional).
   A todas les aparece al mismo tiempo; tras unos segundos se activa **Apartar** y gana la primera.
4. **Cerrar**: cada mayorista ve en su página su total, la CLABE y su folio. Lo demás (registrar pago,
   caja fija, liberar a las 3 h) es igual que en redes.

## Avisos al celular del equipo

Sin abrir el panel, le llega una notificación al equipo cuando:
- ✅ se registra un **pago** → "Mover C-007 → caja B3 · piezas 0023, 0310"
- ⚠️ un **pago está incompleto** → "Faltan $89 · revisar con la clienta"
- ⏰ un **apartado vence** → "Regresar 0932 a racks"
- 📦 una **caja está lista** → a los 20 días (como Cajas) o al llegar a N prendas (Ajustes del panel)

Cada persona lo activa una vez en **Panel → Ajustes → Activar avisos**. En iPhone primero hay que
agregar el panel a la pantalla de inicio (Safari → Compartir → Agregar a pantalla de inicio) y abrirlo
desde ese ícono (iOS 16.4 o más reciente).

Toda la lógica vive en la base de datos (funciones `bot_mensaje`, `live_cerrar`, `live_registrar_pago`,
`live_revisar_vencimientos`…), así que el bot real y el simulador se comportan igual.

### Simulador

En el panel, pestaña **WhatsApp**: escribes como si fueras una clienta y el bot responde.
Las clientas de prueba usan números que empiezan con `00`, nunca se manda nada a un teléfono,
y el botón **Borrar datos de prueba** las quita junto con sus apartados, cobros, cajas y pedidos.

## Dónde vive cada cosa

| Qué | Dónde | ¿Se pierde al actualizar la app? |
|---|---|---|
| El programa (código) | Este repositorio de GitHub | No: cada cambio queda guardado como una versión nueva. |
| Los datos (clientas, cajas, pedidos, prendas, lives, mensajes) | Supabase, proyecto **outlet-prime** | No: el código solo los lee y escribe. |

### Reglas para no perder datos

- Cambia el código aquí con toda libertad: los datos siguen en Supabase.
- **No borres ni cambies** tablas desde el panel de Supabase. Los cambios a la base van como archivo
  nuevo en `supabase/migrations/`.
- La llave `anon` de `config.js` es pública y es seguro que esté aquí.
  **Nunca** subas la llave `service_role`, tokens de WhatsApp ni contraseñas.
- El plan gratis de Supabase no guarda respaldos descargables: haz un respaldo cada semana.

## Cómo abrirla en tu computadora

```bash
python3 -m http.server 8000
# luego abre http://localhost:8000 (Cajas) o http://localhost:8000/live.html (Live)
```

## Origen

La app de Cajas se descargó del artifact "Outlet Prime Cajas" en claude.ai
(https://claude.ai/artifact/XCQHxE3Yn48fhrJrHdNAok). El sistema del live sigue la propuesta
"Outlet Prime · Sistema de lives automatizado" (https://claude.ai/artifact/8dvF4iTgDER9NyZS2CYyZD).
