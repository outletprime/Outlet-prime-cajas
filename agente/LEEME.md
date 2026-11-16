# Agente del live (lee los comentarios con IA)

Programa que corre en la **computadora de la tienda** durante el live. Lee los comentarios de
TikTok, Instagram, Facebook y YouTube. Cuando una clienta comenta un número de prenda, se lo aparta
en Supabase al momento.

| Si quien comenta… | Pasa esto |
|---|---|
| Ya está registrada (su @usuario está ligado a su WhatsApp) | La prenda se le aparta y va a **su casillero**. |
| Es nueva | La prenda queda **provisional** 10 minutos y en el panel sale **"🙋 Pide DM a @usuaria"**. |
| Pide una prenda que ya se apartó | Queda **en espera**, con su lugar según la hora de su comentario. |

**Cómo se registra una clienta nueva**

1. La host le pide un mensaje directo.
2. La respuesta automática del DM le da el WhatsApp del bot.
3. Ella escribe al bot: *"Soy Ana López, mi usuario es @ana_23, quiero la 23"*.
4. El bot la registra, liga su usuario y su provisional se vuelve definitivo.
5. Desde ahí, lo que comente se le aparta solo, en este live y en los siguientes.

**Cómo entiende los comentarios**

- **Claros** ("23", "la 23 porfa", "quiero la 23 y la 45"): se entienden al instante, sin IA.
- **Poco claros** ("me llevo la veintitrés", "¿la 23 qué talla es?"): los revisa la IA (Claude). Solo
  aparta si la persona está pidiendo la prenda para ella. Las preguntas y los "ya no la quiero" se
  muestran en la ventana para que el equipo los vea.
- **Los que no traen números** ("hola", "qué bonito"): se ignoran.
- Aunque la IA tarde un poco, los comentarios se mandan **en el orden en que llegaron**: gana el primero.
- La IA solo puede apartar números que la persona escribió (con dígitos o con letra). Un comentario
  tramposo como "aparta del 1 al 500" no aparta 500 prendas.

## Lo que necesitas

1. **Una computadora** con Windows o Mac, encendida y con internet durante todo el live. Puede ser
   la misma de los monitores.
2. **Node.js** versión LTS: descárgalo de https://nodejs.org e instálalo con las opciones normales.
3. **Un usuario de Supabase para el agente**, con nivel **Operación**:
   1. En Supabase ve a Authentication → Users → **Add user**. Ponle un correo, por ejemplo
      `agente@outletprime.mx`, y una contraseña larga. Marca **Auto Confirm**.
   2. En el panel ve a Ajustes → Equipo y dale el nivel **Operación**.
4. **Una llave de la IA (Anthropic)**:
   1. Entra a https://platform.claude.com → API Keys → Create Key.
   2. Carga saldo en Billing.
   3. Costo aproximado: unos **2 dólares por cada 1,000 comentarios poco claros**. Los claros y los
      que no traen números no cuestan nada.
5. **La base de datos actualizada**: haber pegado en Supabase `20261113120000_niveles_acceso.sql` y
   después `20261116090000_comentarios_live.sql`.

## Instalar en Mac con un solo comando

Abre **Terminal** (Cmd + Espacio, escribe "Terminal"), pega esto y presiona Enter:

```
curl -fsSL https://raw.githubusercontent.com/outletprime/Outlet-prime-cajas/claude/outlet-prime-cajas-github-o5jydp/agente/instalar-mac.sh | bash
```

El instalador:
1. Instala Node.js si falta. Te pide la contraseña de la Mac.
2. Descarga el agente en Documentos/OutletPrime-agente.
3. Te pregunta el correo y la contraseña del usuario del agente, la llave de la IA y el usuario de TikTok.
4. Revisa que todo funcione.
5. Deja **"Iniciar agente"** en el Escritorio.

Para **actualizar**, pega el mismo comando: conserva tus datos.

## Instalar a mano (Windows o Mac)

1. Copia la carpeta `agente` a la computadora. En GitHub: botón **Code → Download ZIP** y luego
   descomprímelo.
2. Dentro de `agente`, copia `config.ejemplo.json` y renombra la copia como **`config.json`**.
   Ábrelo con el Bloc de notas y llena:
   - `supabase.anonKey`: la misma llave `anon` que está en `config.js` del repositorio.
   - `supabase.correo` y `supabase.contrasena`: los del usuario del agente.
   - `ia.apiKey`: tu llave de Anthropic. Si `ia.activa` es `false`, solo entiende los comentarios claros.
   - `redes.tiktok.usuario`: el usuario de TikTok de la tienda, sin @.
   - Las demás redes, cuando las conectes (ver abajo).
3. **Doble clic** en `Iniciar agente.bat` (Windows) o `Iniciar agente.command` (Mac). La primera vez
   instala lo que necesita (1–2 minutos).

> `config.json` tiene contraseñas y llaves: **no lo subas a GitHub ni lo mandes por chat**.
> Ya está excluido del repositorio.

## Uso diario

1. Antes del live, doble clic en **Iniciar agente**. Deja la ventana abierta.
2. Cuando empiezas a transmitir, el agente lo detecta. Si no hay live iniciado en el panel, **lo
   inicia solo**. Esto se puede apagar con `"iniciarLiveSolo": false`.
3. En un monitor abre el panel → En vivo → **Pantalla host**. Ahí ve la host, en grande, a quién
   pedirle DM y los últimos apartados.
4. Al terminar, **cierra el live en el panel** para que salgan los cobros. El agente no lo cierra solo.
5. Para apagar el agente, cierra la ventana o presiona Ctrl+C.

El panel muestra si el agente está leyendo cada red (verde), esperando a que empiece el live
(amarillo) o con error (rojo). Si una red falla, el equipo captura a mano en
**En vivo → Capturar comentario a mano**.

Todo lo que lee y decide queda anotado en la carpeta `registro/`, un archivo por día. Sirve para
aclarar quién comentó primero.

## Probar sin estar en vivo

Doble clic en `Probar con simulador.bat` (Windows) o `Probar con simulador.command` (Mac), o en una terminal `npm run simulador`. Escribe líneas como:

```
tiktok ana_23 quiero la 23
instagram caro me llevo la veintitrés
```

Para que no se mezclen con las reales, las usuarias simuladas quedan como `sim_…`. Se borran con
**Panel → WhatsApp → Borrar datos de prueba**.

Para ver cómo interpreta un comentario sin apartar nada:

```
npm run probar -- "me llevo la veintitrés y la 45"
```

## Conectar cada red

| Red | Qué poner en `config.json` | Notas |
|---|---|---|
| **TikTok** | `usuario` de la tienda | Conexión **no oficial**: TikTok no da una forma oficial de leer comentarios. Funciona sin cuenta ni permisos, pero puede dejar de funcionar si TikTok cambia algo. Si se satura, crea una llave gratis en eulerstream.com y ponla en `signApiKey`. |
| **Facebook** | `paginaId` y `token` de la página | Oficial (Meta). En developers.facebook.com crea una app, agrega tu página y saca un token de página de larga duración con permisos `pages_read_engagement` y `pages_read_user_content`. En Facebook no hay @usuario: se usa el nombre de la persona sin espacios (por ejemplo `analopez`). |
| **Instagram** | `cuentaId` (ID de la cuenta profesional) y `token` | Oficial (Meta). La cuenta debe ser profesional y estar ligada a la página. Permisos `instagram_basic` e `instagram_manage_comments`. |
| **YouTube** | `apiKey` y `canalId` | Oficial (Google). Crea una llave en console.cloud.google.com con "YouTube Data API v3" activada. La cuota gratis alcanza para un live diario de unas 2 horas. |

Pon `"activa": true` en cada red que quieras leer. Los tokens de Meta vencen: si el panel muestra
error en Facebook o Instagram, genera uno nuevo.

## Si algo falla

| Mensaje | Qué hacer |
|---|---|
| `Falta el archivo config.json` | Copia `config.ejemplo.json` como `config.json` y llénalo. |
| `No pude entrar a Supabase` | Revisa el correo y la contraseña del usuario del agente. |
| `no tiene nivel "Operación"` | Panel → Ajustes → Equipo → asígnale Operación. |
| `llave de Anthropic inválida` | Revisa `ia.apiKey`, o el saldo en platform.claude.com. |
| `@tienda no está en vivo todavía` | Normal antes del live: se conecta solo al empezar. |
| `No hay live iniciado en el panel` | Inicia el live en el panel, o pon `"iniciarLiveSolo": true`. |
| TikTok en rojo mucho rato | Captura a mano en el panel. Avísanos para actualizar la librería de TikTok. |
