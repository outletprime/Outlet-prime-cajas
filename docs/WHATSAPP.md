# Conectar el número de WhatsApp del bot

Mientras no esté conectado, todo funciona con el **simulador** del panel y los mensajes reales
se quedan en la cola ("Mensajes reales por enviar"). Los de más de 30 minutos ya no se envían,
así que al conectar no les llegan mensajes viejos a las clientas.

## Lo que se necesita (Fase 1 de la propuesta)

1. **Chip y número nuevo**, que no tenga WhatsApp instalado (ni personal ni Business).
2. **Meta Business** verificado (business.facebook.com) a nombre de Outlet Prime.
3. En **developers.facebook.com**: crear una app tipo *Business* y agregar el producto **WhatsApp**.
4. Registrar el número nuevo en WhatsApp Manager y anotar su **Phone number ID**.
5. Crear un **usuario de sistema** con permiso `whatsapp_business_messaging` y generar un
   **token permanente**.
6. Anotar el **App secret** (Configuración de la app → Básica).

## Activar el conector (lo hace Claude o quien administre Supabase)

1. Guardar en Supabase → Edge Functions → Secrets (nunca en GitHub):
   `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_APP_SECRET`,
   `WHATSAPP_VERIFY_TOKEN` (una palabra secreta inventada) y `ENVIO_SECRETO` (otra).
2. Publicar la función `supabase/functions/whatsapp` con `verify_jwt = false`
   (ya está en `supabase/config.toml`).
3. En Meta → WhatsApp → Configuración → Webhook:
   - URL: `https://fjafsvirllfuzrzonovy.supabase.co/functions/v1/whatsapp`
   - Token de verificación: el mismo `WHATSAPP_VERIFY_TOKEN`
   - Suscribirse al campo **messages**.
4. Programar el envío de la cola cada minuto (cobros y recordatorios que no son respuesta inmediata)
   con `pg_net` + `pg_cron`, llamando a `…/functions/v1/whatsapp?enviar=1` con el encabezado
   `x-clave-envio: <ENVIO_SECRETO>`.
5. Probar con un teléfono propio durante un live de prueba y después **Borrar datos de prueba**
   (los números reales no se borran con ese botón: hay que quitar a mano la clienta de prueba).

## Ventana de 24 horas de WhatsApp

WhatsApp solo deja escribir libremente a una clienta dentro de las 24 h siguientes a su último mensaje.
El cobro, el recordatorio y la liberación caen dentro de esa ventana porque la clienta escribió
durante el live. Para avisos fuera de esa ventana (p. ej. "tu caja ya se envió" días después)
hay que dar de alta **plantillas** aprobadas por Meta.

## CLABE por pedido (más adelante)

Cuando se contrate Fintoc o Conekta, su aviso de pago llamará a `live_registrar_pago(cuenta, monto)`:
el resto (pasar a caja, crear el pedido, avisar a la clienta) ya está hecho.
