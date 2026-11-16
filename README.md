# Outlet Prime · Cajas y Live

Dos apps web que comparten **una sola base de datos** (Supabase, proyecto **outlet-prime**)
y **una sola lista de clientas** (una clienta = un número de WhatsApp):

| App | Archivo | Para qué |
|---|---|---|
| **Cajas** | `index.html` | Caja fija de cada clienta, pedidos por categoría, QR, envíos y reportes. |
| **Panel del live** (equipo) | `live.html` | Lives de redes (comentarios + WhatsApp) y Prime Live (mayoristas), avisos "pide DM", pantalla para la host, casilleros, cobros y paso automático a la caja fija. |
| **Agente del live** | `agente/` | Programa para la computadora de la tienda: lee los comentarios de TikTok, Instagram, Facebook y YouTube con IA y aparta. Ver [`agente/LEEME.md`](agente/LEEME.md). |
| **Prime Live** (mayoristas) | `prime.html` | Página exclusiva donde cada mayorista invitada entra con su contraseña y aparta con un botón. |

### Dos canales, una sola base de clientas

| | Lives en redes (TikTok / Facebook) | Prime Live |
|---|---|---|
| Para quién | Público: captación de clientas nuevas | Solo mayoristas invitadas |
| Cómo apartan | **Comentan el número en el live** (el agente lo lee). También pueden mandarlo al bot de WhatsApp: gana quien llegue primero | Botón **Apartar** sobre la foto de cada prenda, en `prime.html` |
| Acceso | Cualquiera: la primera vez se registra por WhatsApp con su @usuario | Contraseña única por mayorista, válida solo para ese live |
| Cobro, casilleros, 3 h para pagar, caja fija | Igual | Igual (categoría **Prime Live** en Cajas) |

Las mayoristas **no tienen usuario de Supabase**: su contraseña solo les deja ver las prendas
de ese live y su propio carrito (funciones `prime_acceso`, `prime_estado` y `prime_apartar`).
Nunca ven datos de otras clientas.

Publicadas en GitHub Pages: https://outletprime.github.io/Outlet-prime-cajas/
(el panel del live está en `…/live.html`, o desde Cajas → Ajustes → Panel del live).
Las dos usan el mismo correo y contraseña de Supabase → Authentication → Users.

### Niveles de acceso del equipo

| Puede… | Dueña | Supervisor | Operación | Operación live (acomodo) | Presentadora |
|---|---|---|---|---|---|
| Ver live, casilleros y prendas | ✅ | ✅ | ✅ | ✅ | ❌ |
| Recibir avisos de pagos, vencidos y cajas | ✅ | ✅ | ✅ | ✅ | ❌ |
| Recibir el aviso **"🙋 Pide DM a @usuaria"** (la primera que pidió una prenda) y marcar "ya se lo pedí" | ver en panel | ver en panel | ✅ en panel | ❌ | ✅ **en su celular** |
| Marcar prendas acomodadas en su casillero o regresadas al rack (pestaña **Acomodo**) | ✅ | ❌ | ✅ | ✅ | ❌ |
| Ver clientas, teléfonos y la app de Cajas | ✅ | ✅ | ✅ | ❌ | ❌ |
| **Ligar a mano** a una clienta que mandó su WhatsApp por DM | ✅ | ✅ | ✅ | ❌ | ❌ |
| Ver reportes de ventas | ✅ | ✅ | ❌ | ❌ | ❌ |
| Iniciar/cerrar lives, capturar, liberar, registrar clientas y pedidos | ✅ | ❌ | ✅ | ❌ | ❌ |
| Registrar pagos | ✅ | ❌ | ❌ | ❌ | ❌ |
| Programar Prime Live e invitar mayoristas | ✅ | ❌ | ❌ | ❌ | ❌ |
| Cambiar CLABE, precios, tiempos y categorías | ✅ | ❌ | ❌ | ❌ | ❌ |
| Borrar cualquier cosa | ✅ | ❌ | ❌ | ❌ | ❌ |
| Dar o quitar accesos | ✅ | ❌ | ❌ | ❌ | ❌ |

**Presentadora**: solo le llegan notificaciones "🙋 Pide DM a @usuaria · fue la primera en pedir la 0023"
(no las de quien quedó en espera, ni pagos ni cajas). En el panel solo tiene la pestaña **Pide DM**, con la
lista y el botón "ya se lo pedí", y Ajustes para activar sus avisos. No ve clientas, pagos ni casilleros.

**Supervisor** solo ve, con una excepción: atiende los DMs. Cuando una clienta nueva le manda su
WhatsApp por mensaje directo, en el aviso "Pide DM" toca **Ligar con su WhatsApp**, escribe el número (y el
nombre si es nueva) y listo: lo que pidió pasa a su casillero y le llega la confirmación por WhatsApp.

**Acomodo** (para quien lleva las prendas del live a los casilleros): lista "Llevar a su casillero"
(`0023 → C-007`), "Regresar al rack" (prendas liberadas) y "Charola de pendientes" (clientas nuevas que
aún no se registran). Cada prenda se palomea con ✓; si se equivoca, puede deshacer.

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
| `supabase/migrations/` | Cambios a la base, en orden: `…_sistema_lives.sql` (bot y casilleros), `…_prime_live.sql` (mayoristas), `…_avisos_equipo.sql` (avisos), `…_niveles_acceso.sql` (niveles) y `…_comentarios_live.sql` (comentarios y pide DM). |
| `agente/` | Agente que lee los comentarios del live (Node.js). Instrucciones en `agente/LEEME.md`. |
| `supabase/functions/whatsapp/` | Conector con WhatsApp Business (se activa cuando haya número del bot). |
| `supabase/functions/avisos/` | Envía los avisos al celular del equipo (notificaciones). |
| `sw.js`, `manifest.webmanifest` | Permiten instalar el panel como app y recibir notificaciones. |
| `docs/WHATSAPP.md` | Pasos para conectar el número de WhatsApp del bot. |

## Cómo funciona el live con comentarios (agente con IA)

1. **La clienta comenta el número** en el live ("23", "la 23 porfa", "me llevo la veintitrés").
2. **El agente lo lee** y busca su @usuario en Supabase:
   - **Registrada** → la prenda se le aparta al momento y va a **su casillero**. Si ya estaba apartada,
     queda en espera con su lugar según la hora del comentario.
   - **Nueva** → la prenda queda **provisional 10 minutos** y en el panel sale **"🙋 Pide DM a @usuaria"**.
     La host le pide mensaje directo. La respuesta automática del DM (Ajustes → Mensaje de bienvenida
     del DM) le da el WhatsApp del bot.
3. **La clienta escribe al bot**: *"Soy Ana López, mi usuario es @ana_23, quiero la 23"*. El bot la
   registra y liga **@usuario ↔ WhatsApp ↔ clienta**. El provisional se vuelve definitivo y va a su casillero.
4. **Lo que comente después** (en este live y en los siguientes) cae solo en su casillero.
5. Si no se registra en 10 minutos, la prenda pasa a la siguiente en espera o vuelve a estar disponible.
   Desde el aviso, el equipo puede darle más tiempo, ligarla a mano con su WhatsApp o soltarla.
6. Cerrar, cobrar, pagar, caja fija y avisos: igual que siempre (abajo).

En el panel:
- **Pantalla host** (En vivo → Pantalla host) muestra en grande a quién pedirle DM y los últimos apartados.
- **Capturar comentario a mano** es el plan B si una red falla.
- **Ajustes → Usuarios de redes ligados** sirve para corregir un usuario mal ligado.
- El simulador (pestaña WhatsApp) también simula comentarios.

## Cómo funciona el live (cobro y caja)

1. **Etiquetar.** Cada prenda tiene un número fijo (Prendas → Registrar rango, p. ej. 3001–3200), a $89.
2. **Iniciar live** en el panel.
3. **Apartar.** La clienta comenta el número en el live (ver arriba) o lo manda por WhatsApp (`23` o
   `23 45 310`). Gana el primero; si ya está apartada, queda en lista de espera con su lugar.
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
