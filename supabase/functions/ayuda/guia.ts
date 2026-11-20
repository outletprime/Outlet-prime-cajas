// Guía del equipo de Outlet Prime: es todo lo que "sabe" el asistente de la burbuja de ayuda.
// Para corregir o ampliar una respuesta, se edita este texto y se vuelve a publicar la función `ayuda`.
// Escríbela como se le explicaría a una persona nueva del equipo: con los nombres que se ven en el panel.

export const GUIA = `# Guía del equipo · Outlet Prime (panel del live)

## Qué es cada cosa
- **Panel del live**: la aplicación del equipo. Abajo tiene pestañas: En vivo, Casilleros, Acomodo, Prendas, WhatsApp y Ajustes. Cada nivel ve solo las suyas.
- **Cajas**: la otra aplicación (ícono de caja arriba a la derecha del panel). Ahí está la caja fija de cada clienta, sus pedidos y envíos.
- **Agente**: programa que corre en la computadora de la tienda. Lee los comentarios del live de TikTok y aparta solo. Se enciende con el ícono "Iniciar agente" del Escritorio de esa computadora.
- **Clave**: lo que trae la etiqueta colgada de cada prenda: dos letras y dos números, por ejemplo AB23. No hay que registrarla a mano: queda dada de alta desde que se manda a imprimir su etiqueta (Prendas → Imprimir etiquetas) y se aparta en cuanto alguien la comenta. Cada prenda cuesta lo que diga Ajustes → Precio por prenda.
- **Casillero**: espacio temporal donde se juntan las prendas de una clienta durante el live, hasta que paga. En cada casillero caben 10 prendas: cuando el casillero de una clienta llega a 10, la siguiente prenda se le asigna al siguiente casillero libre (el aviso dice a cuál llevarla, por ejemplo "📦 AB23 → B5"). Una clienta puede ocupar varios casilleros pero sigue siendo un solo pedido, un solo cobro y una sola caja. Si ya no hay ningún casillero libre, la prenda va al **CARRO**: el aviso dice "📦 AB23 → CARRO" y abajo el nombre de la clienta (o su usuario si todavía no está registrada), y se deja en el carro con ese nombre. En la lista de la clienta aparece "→ CARRO" junto a esa prenda. Hay 30, y se llaman por su posición: la columna (A a F) y la fila (1 a 5), de A1 a F5. Por ejemplo, B3 es el casillero de la columna B, fila 3, y su etiqueta dice "CASILLERO B3". Ojo: las cajas fijas de la app de Cajas también se llaman con letra y número (A1, B3…). Por eso los avisos de pago dicen la palabra completa: "Mover casillero A1 → caja B3" quiere decir sacar las prendas del casillero A1 y pasarlas a la caja fija B3.
- **Caja fija** (o caja de resguardo): la caja permanente de la clienta en la app de Cajas. Las prendas pasan del casillero a la caja fija cuando paga completo. Hay 50: A1 a H5 de hasta 30 prendas y las grandes I1 a J5 de hasta 40. Su etiqueta tiene una franja negra que dice "CAJA DE RESGUARDO" y un QR.
- **Pide DM**: aviso de que una clienta nueva (que el sistema todavía no conoce) fue la primera en pedir una prenda. Hay que pedirle al aire que mande mensaje directo.
- **Charola de pendientes**: donde se dejan las prendas que pidió una clienta nueva mientras se registra.
- **Lista de espera**: si una prenda ya estaba apartada, las siguientes que la piden quedan en espera en orden de comentario. Durante el live, si la prenda se libera pasa sola a la primera en espera. Con el live ya cerrado, si un pedido vence o una reserva de clienta nueva se cae, la prenda NO pasa sola a nadie: queda libre y una Dueña decide si se la da a la primera en espera (Prendas → Buscar la clave → **Dársela a quien espera**). "Liberar" y "Se arrepintió" sí la pasan a la siguiente, porque lo decide una persona.
- **Resurtir**: reponer en los racks de la sala las prendas que ya se vendieron. Una prenda cuenta como vendida cuando su pago queda completo. Por ahora hay una sola sala: Sala 1.

## Cómo funciona un live, de principio a fin
1. Se enciende el agente en la computadora de la tienda y se inicia el live en En vivo (si el agente detecta el live, lo inicia solo).
2. La clienta comenta la clave en TikTok ("AB23", "la ab23 porfa").
3. Si la clienta **ya está registrada** con ese usuario: la prenda se le aparta al momento y se le asigna casillero. A quien hace el acomodo le llega "📦 AB23 → B2 · Ana".
4. Si la clienta es **nueva**: la prenda queda provisional (10 minutos, o lo que diga Ajustes → Minutos para registrarse) y sale el aviso "🙋 Pide DM a @usuaria". Quien presenta le pide al aire que mande DM. La prenda se deja en la charola de pendientes.
5. La clienta nueva manda DM. Se le contesta con "Copiar mensaje" (le pide su nombre y por lo menos un apellido; ya no se le pide WhatsApp por TikTok). Cuando manda su nombre, el Supervisor (o una Dueña u Operación) la registra en En vivo → Pide DM → "Registrar a mano" con su nombre y apellido. En cuanto queda ligada, lo que pidió pasa a su casillero y de ahí en adelante todo lo que comente cae solo, en este live y en los siguientes.
6. Si no se registra a tiempo, la prenda pasa a la siguiente en espera (durante el live) o vuelve a estar disponible.
7. Al terminar: En vivo → "Cerrar live". Ya no se puede apartar. Todavía NO se cobra: los pedidos quedan "En revisión".
8. Revisión: se toca cada casillero (en Casilleros o en Acomodo → "Revisar pedidos") y se abre su lista de prendas. Cada prenda se busca en físico y se marca **Encontrada**, **No encontrada** o **No vendible** (dañada o con defecto). Cuando todas están encontradas aparece "Confirmar pedido completo". Si alguna no se encontró o no se puede vender, el pedido queda como "Incompleto · faltan N"; si de verdad no aparece, se toca "Cerrar pedido sin las faltantes": se quitan, el total se ajusta y la nota de cobro sale solo con lo que sí se cobra. En los dos casos sale un recuadro con las prendas, el precio de cada una y el total a pagar, y quien revisa debe tocar el botón para confirmar.
9. Cobro: en Casilleros el pedido confirmado dice "Listo para cobrar". Una Dueña toca "Mandar nota de cobro": se abre WhatsApp con la nota ya escrita (total, CLABE y folio OP-001…). En ese momento empieza a correr el plazo de pago de esa clienta.
10. Pago: una Dueña lo registra en Casilleros → "Registrar pago". Con el pago completo, las prendas pasan solas a su caja fija y se crea el pedido en Cajas.
11. Sin pago: recordatorio, luego límite de pago y luego se libera solo. Los tiempos cuentan desde que se mandó la nota (Ajustes → Tiempos después de cerrar el live). El panel avisa "Regresar a racks".

## Niveles de acceso (qué puede cada quien)
- **Dueña**: todo. Es la única que registra pagos, cambia Ajustes (CLABE, precios, tiempos), programa Prime Live, borra, y da o quita accesos.
- **Supervisor**: ve todo. Puede editar los datos de las clientas en la app de Cajas (Clientas → su ficha → "Editar datos"). Además: registra a las clientas nuevas, ya sea desde un aviso "Pide DM" (Registrar a mano) o en Ajustes → Agregar clienta, con su usuario, nombre y apellido (le llega al celular el aviso "📝 Registrar a @usuario"), y genera el PDF de las etiquetas de prendas y de las cajas de resguardo para imprimirlas (pestaña Prendas). También ve los pedidos ya pagados con las claves de sus prendas y saca su PDF (Casilleros → Pedidos pagados).
- **Operación**: opera el live: inicia y cierra lives, captura comentarios a mano, libera prendas, liga clientas, marca acomodo. No registra pagos, no cambia Ajustes y no borra.
- **Operación live (acomodo)**: lleva las prendas a los casilleros y, cuando un pedido ya está pagado, las pasa a su caja de resguardo y lo marca con **Ya está en la caja** (pestaña Casilleros). Ve En vivo, Casilleros, Acomodo, Prendas y Ajustes. No ve la pestaña WhatsApp ni los datos de las clientas. A la app de Cajas entra solo a consultar y a agregar videos: con el botón **Cajas** de arriba a la derecha del panel, o escaneando el QR de una caja. Ahí ve las cajas, de quién es cada una (solo el nombre), sus pedidos y prendas, y puede agregar el video de un pedido que no lo tiene; no puede registrar pedidos, enviar ni reasignar cajas, ni ver clientas, reportes o ajustes.
- **Presentadora**: solo ve la pestaña Pide DM y Ajustes. No ve clientas, pagos ni casilleros.
- **Resurtido**: solo ve la pestaña Resurtir y Ajustes. Sabe cuántas prendas pagadas hay que reponer en la sala y lo anota cuando ya lo hizo. No ve clientas, pagos, casilleros ni el live.
- Una Dueña que conduce el live puede tener sus avisos en "solo Pide DM": en su celular solo le llegan esos avisos, pero en el panel sigue viendo todo.
Si un botón no aparece o sale "Tu nivel de acceso no permite hacer esto", es por el nivel: hay que pedírselo a una Dueña u Operación.

## Pestaña En vivo
- Sin live: botón para iniciar (el nombre es opcional). Si dice "Falta la CLABE para cobrar", una Dueña debe ponerla en Ajustes antes de cerrar.
- Con live: contadores (Apartadas, Clientas, Total, En espera), la lista "Apartados al momento" y los avisos "🙋 Pide DM".
- "El agente que lee los comentarios no está encendido": hay que abrir "Iniciar agente" en la computadora de la tienda. Mientras tanto se captura a mano.
- **Capturar comentario a mano** (plan B si el agente o TikTok fallan): se escribe el usuario y la clave o claves, y "Apartar". Se aparta igual que si lo hubiera leído el agente.
- **Quitar / Liberar** una prenda apartada: se le quita a esa clienta; si hay alguien en espera, pasa a la primera.
- **Pantalla host**: vista grande con a quién pedirle DM y los últimos apartados, para tenerla a la vista de quien presenta.
- **Cerrar live**: está justo debajo de los avisos "Pide DM". Después de cerrar ya no se puede apartar. No manda cobros: eso se hace después, pedido por pedido.

## Avisos "🙋 Pide DM" (clientas nuevas)
En cada aviso hay estas acciones:
- **Ya se lo pedí**: marca que ya se le pidió al aire que mande DM.
- **Copiar mensaje**: copia el mensaje para contestarle por DM; le pide su nombre y por lo menos un apellido.
- **Registrar a mano**: cuando la clienta ya mandó su nombre por DM. Se escribe su nombre y su apellido (el WhatsApp es opcional; si se pone y ya era clienta, se liga a la que ya existe). Lo que pidió pasa a su casillero y a Operación live le llega el aviso para acomodarlo.
- **Soltar**: se le quita lo que tenía provisional; las prendas vuelven a estar disponibles o pasan a la siguiente en espera.
Quién puede registrar: Dueña, Operación y Supervisor. Operación live y Presentadora no. Al Supervisor le llega al celular "📝 Registrar a @usuario" por cada clienta nueva, para que esté atento a su DM.
Si un usuario quedó ligado a la clienta equivocada: Ajustes → Usuarios de redes ligados → buscarla → "Quitar". La próxima vez que comente se le pedirá DM otra vez.

## Pestaña Pide DM (Presentadora)
Salen las clientas nuevas que fueron las primeras en pedir una prenda. Se les pide al aire que manden DM y se toca la tarjeta cuando ya se les pidió. Si dice "Tu celular todavía no recibe los avisos", hay que activarlos en Ajustes. "Nadie pendiente 👌" significa que no hay nada que hacer.

## Pestaña Acomodo (Operación live)
- **Llevar a su casillero**: cada renglón dice la clave y el casillero (AB23 → B2). Se lleva la prenda y se toca ✓.
- **✕ (código equivocado)**: junto al ✓ de cada prenda. Se toca cuando la clave no corresponde (no aparece esa etiqueta o no es la prenda). Sale un recuadro "Código equivocado" para confirmar; al aceptar, la prenda sale de la lista, aparece en "Hechas recientemente" como código equivocado (con Deshacer) y al equipo le llega el aviso "⚠️ Código equivocado: AB23" para revisarlo con la clienta. No se le quita la prenda a nadie: eso lo decide una Dueña u Operación (si pidió otra clave, se quita del pedido y se captura la correcta).
- **Se arrepintió**: botón debajo del nombre de la clienta en cada prenda de Acomodo (y también en la lista de prendas de cada pedido). Es para cuando la clienta ya no quiere esa prenda. Pide dos confirmaciones: primero "¿Se arrepintió?" (dice a quién pasa) y luego "Confírmalo otra vez". Al confirmar, se le quita de su pedido y pasa sola a la primera en espera (llega el aviso "🔁" para cambiarla de casillero); si nadie la esperaba, va a "Regresar al rack". Solo prendas sin pagar. No se puede deshacer desde el panel. Lo pueden hacer Operación live, Operación y Dueña; al equipo le llega el aviso "↩️ AB23: Ana se arrepintió".
- **Regresar al rack**: prendas que se liberaron (no pagaron o se quitaron). Se sacan del casillero, se regresan al rack y se toca ✓.
- **En la charola de pendientes**: prendas de clientas nuevas que aún no se registran. Se dejan en la charola; cuando la clienta se registra aparecen arriba con su casillero, y si no, se liberan solas.
- Si se palomeó una por error: "Deshacer". "Todo acomodado 👌" significa que no hay nada pendiente.
- **Revisar pedidos** (aparece cuando el live ya cerró): cada renglón es un casillero con su clienta y cuántas prendas lleva encontradas. Al tocarlo se abre la lista de sus prendas, cada una con tres botones lado a lado: **Encontrada** (verde), **No encontrada** (rojo) y **No vendible** (naranja, para una prenda dañada o con defecto). Se busca cada prenda en el casillero y se marca. Si te equivocas, vuelve a tocar el mismo botón y la marca se quita. Arriba dice cuántas van ("6 de 8 encontradas · 2 no se cobran"). 
  - Si todas están encontradas aparece **Confirmar pedido completo**. Al tocarlo sale un recuadro con cada prenda, su precio y el **total a pagar**; quien revisa toca **Sí, confirmar pedido** y ya se le puede mandar su nota de cobro.
  - Si alguna quedó como No encontrada o No vendible, el pedido queda **Incompleto**. Si aparece después, se abre otra vez y se marca Encontrada. Si de verdad no está, se toca **Cerrar pedido sin las faltantes**: sale un recuadro con las prendas que sí se cobran, las que se quitan (tachadas) y el nuevo total; al tocar **Sí, cerrar pedido** se quitan del pedido, el total se ajusta y la nota de cobro sale por el nuevo monto. Las no encontradas quedan como disponibles (si aparecen se pueden volver a vender) y las no vendibles se dan de baja. Si no queda ninguna prenda, el pedido se cancela y el casillero queda libre. Lo pueden hacer Dueña, Operación y Operación live.
Avisos que llegan al celular de acomodo: "📦 AB23 → B2 · Ana" (llevarla), "🔁 AB23: de B2 a D2" (cambió de clienta: moverla al otro casillero) y "↩️ Regresar AB23 al rack".

## Pestaña Resurtir (nivel Resurtido)
- Arriba sale un número grande: las prendas ya pagadas que faltan por reponer en Sala 1. Solo cuentan las que ya se pagaron completas; las apartadas que todavía no se pagan no aparecen. Las de ensayo tampoco cuentan.
- **Ya resurtí las N**: se toca cuando ya se repusieron todas. Se anota a nombre de quien lo hizo y el contador vuelve a cero.
- **Solo resurtí una parte**: se escribe cuántas se repusieron; las demás se quedan pendientes.
- "Todo repuesto 👌" significa que no hay nada por reponer.
- Abajo salen "Pagadas por live" (cuántas prendas se pagaron de cada live) y "Últimos resurtidos" (cuántas se repusieron, cuándo y quién).
- Al celular llega el aviso "🧺 Van N prendas por resurtir" cada vez que se completa un pago. Este nivel no recibe ningún otro aviso.
- No hay botón para deshacer: si se anotó un resurtido por error, hay que avisarle a una Dueña.
- Dueña, Operación y Supervisor ven el mismo número en la pestaña Prendas, en el renglón "Por resurtir en Sala 1"; al tocarlo se abre el detalle. Dueña y Operación también pueden anotar el resurtido; Supervisor solo lo ve.

## Pestaña Casilleros
Lista de casilleros con la clienta, sus prendas, su total y en qué va. El número rojo en la pestaña son los que tienen algo pendiente. Después de cerrar el live, cada pedido pasa por estos pasos:
- Si una clienta ocupa varios casilleros, la tarjeta dice "Ocupa los casilleros D1, B5 y C5" y, al abrirla, cada prenda dice a qué casillero va ("AB23 → B5").
- **En revisión**: al tocar la tarjeta (o el botón **Revisar prendas**) se abre la lista de prendas para marcarlas una por una como Encontrada, No encontrada o No vendible. Aún no se cobra.
- **Incompleto · faltan N**: hay prendas marcadas como No encontrada o No vendible; la tarjeta dice cuáles. No se cobra hasta que aparezcan o se cierre el pedido sin ellas (botón **Cerrar pedido sin las faltantes** dentro de la lista). El filtro **Incompletos** arriba muestra solo esos.
- **Todo encontrado**: todas las prendas están; falta tocar Confirmar pedido completo dentro de la lista.
- **Listo para cobrar**: pedido confirmado. Una Dueña toca **Mandar nota de cobro**, confirma, y aparece la nota con dos botones: "Abrir WhatsApp" (abre el chat de la clienta con la nota ya escrita; solo falta enviar) y "Copiar nota". Al mandarla empieza a correr su plazo de pago. Abajo, solo para la Dueña, está **Nota en PDF**: "Descargar PDF" (y en el celular "Compartir PDF", para mandarla directo por WhatsApp). El PDF trae el logo, el folio, el nombre de la clienta, a qué live corresponde con su fecha, la host, el casillero, la clave y el precio de cada prenda, el total a pagar (o lo que falta si ya pagó una parte), el banco, a nombre de quién, la CLABE, el concepto (su folio) y la hora límite para pagar. No trae caja de resguardo porque todavía no paga. La nota de texto de WhatsApp también dice el live, la host y el casillero.
- **Pendiente de pago** (con la hora límite): la nota ya se mandó y se espera el pago. "Ver nota de cobro" la muestra otra vez para reenviarla; no reinicia el plazo.
- **Registrar pago** (solo Dueña): monto recibido y referencia opcional. Si el pago queda incompleto, avisa cuánto falta.
- **Sin pago** (pedido vencido): la tarjeta dice "Regresar las prendas a racks". Al vencer, sus prendas quedan libres: ya NO pasan solas a la lista de espera. Si alguna tenía clientas en espera, a las Dueñas les llega el aviso "🕐 Venció OP-0xx: prendas con lista de espera" con quién las esperaba. **Pago tardío** (solo Dueña): si la clienta paga después del plazo, en esa tarjeta se toca **Pago tardío**. Sale la lista de sus prendas: las que se recuperan, las que una Dueña ya le dio a otra clienta de la lista de espera que todavía no paga (con una casilla para quitárselas y devolvérselas) y las que ya no se pueden recuperar porque otra clienta ya las pagó. Muestra el total, se confirma dos veces y el pedido queda pagado: dice a qué caja de resguardo llevar las prendas. El pago tardío siempre es por el total. Si el pedido ya se había regresado al rack, está al final de Casilleros en "Sin pago, ya regresados al rack" (últimos 7 días). Operación, Supervisor y Operación live no ven este botón.
- Con el pago completo las prendas pasan a su caja fija; la tarjeta dice "Pagado · Mover a la caja B2". Quien pasa las prendas del casillero a esa caja de resguardo toca **Ya está en la caja**, confirma, y el casillero queda libre. Lo pueden hacer Dueña, Operación y Operación live. Si dice que no hay cajas libres, hay que crear más en la app de Cajas.
- **Pedidos pagados** (solo Dueña y Supervisor): al final de Casilleros, la sección "Pedidos pagados" se abre al tocarla. Trae los pedidos pagados de los últimos 30 días, del más reciente al más antiguo: clienta, folio, fecha de pago, cuántas prendas, total, a qué caja de resguardo van y las claves de todas sus prendas. El botón **PDF** arma el pedido con el mismo diseño de la nota de cobro, pero como "PEDIDO PAGADO": logo, folio, clienta, a qué live corresponde con su fecha, la host, el casillero, cada clave con su precio, total pagado, fecha de pago y la caja de resguardo (la caja solo sale aquí, porque ya está pagado). Se puede descargar o, en el celular, "Compartir o imprimir".

## Pestaña Prendas
- **Buscar una prenda**: se escribe la clave y dice si está disponible, apartada o vendida, y quién la tiene o está en espera. Si la prenda está libre y tiene clientas en espera, a la Dueña le sale el botón **Dársela a quien espera**: se la pasa a la primera de la fila (se suma a su pedido de ese live o, si ya había pagado, se le abre un pedido nuevo para revisar y cobrar aparte).
- No hay que registrar prendas ni rangos: las etiquetas que se mandaron a imprimir ya están en el sistema como disponibles. Si al buscar una clave dice "Sin etiqueta", esa clave no se ha impreso o está mal escrita.
- Aviso amarillo "prendas apartadas con una clave que no está en las etiquetas impresas": una clienta pidió una clave que no corresponde a ninguna etiqueta impresa, casi siempre por un error al escribirla. Hay que revisar la etiqueta física de esa prenda; si la clave real es otra o la prenda no existe, una Dueña la quita del pedido.
- **Imprimir etiquetas** (solo Supervisor y Dueña): se escribe cuántas etiquetas se necesitan, siempre en múltiplos de 6 porque cada hoja trae 6 (por ejemplo 60 etiquetas son 10 hojas; de 6 a 600 por vez). Se toca "Generar etiquetas" y después "Descargar PDF". El sistema sigue desde la última clave impresa, así que nunca se repite una clave. Las claves generadas quedan anotadas como impresas, por eso hay que imprimirlas todas. Si la descarga o la impresión falló, en "Lotes anteriores" está "Descargar otra vez". Se imprimen en etiquetas Janel J-5164 (hoja carta de 6), al 100 % o "Tamaño real", nunca "Ajustar a la página".
- **Etiquetas de cajas de resguardo** (solo Supervisor y Dueña, en la misma pestaña Prendas): en "¿Cuáles cajas?" se deja vacío para todas o se escriben algunas (por ejemplo A1, B3, J2, para reponer una etiqueta dañada). Se toca "Generar etiquetas de cajas" y salen "Descargar etiquetas" y "Descargar mapa" (en el celular también "Compartir etiquetas"). Cada etiqueta trae la franja negra "CAJA DE RESGUARDO", el QR de la caja (el mismo de la app de Cajas: al escanearlo se abre esa caja), el logo, la posición en grande y cuántas prendas caben. Hay 50 cajas: A1 a H5 de hasta 30 prendas y las grandes I1 a J5 de hasta 40. Se imprimen en hojas Janel J-5164 al 100 %; el mapa va en papel normal.

## Pestaña WhatsApp (simulador y mensajes)
- **Simulador**: sirve para practicar. Se escribe como si uno fuera clienta y el bot responde, sin que salga nada a ningún teléfono. Las clientas de prueba usan números que empiezan con 00.
- **Simular comentario del live**: como si alguien comentara (el live debe estar iniciado).
- **Borrar datos de prueba**: quita las clientas de prueba y todo lo suyo. Las clientas reales no se tocan.
- **Mensajes reales por enviar**: mientras el bot no tenga número de WhatsApp conectado, los mensajes para clientas reales se quedan ahí y no salen solos.

## Ajustes
- **Avisos en el celular**: botón "🔔 Activar avisos en este teléfono", "Mandar aviso de prueba" y "Desactivar aquí".
- **Equipo y niveles de acceso** (solo Dueña): cambiar el nivel de cada persona y ver el historial de cambios.
- **Cobro** (solo Dueña): CLABE (18 dígitos), banco y a nombre de quién.
- **Host de los lives** (solo Dueña): el nombre de quien presenta. Sale en las notas de cobro y de pedido pagado. Cada live nuevo empieza con esa host; si un día presenta otra persona, se escribe al iniciar el live o se cambia en En vivo → **Host: … Cambiar** (Dueña y Operación).
- Tiempos después de cerrar el live, precio por prenda, máximo por clienta, mensaje de bienvenida del DM, WhatsApp del bot, minutos para registrarse.
- **Agregar clienta** (solo Dueña y Supervisor): con los datos que mandó por DM se escribe la red (TikTok), su usuario, su nombre y por lo menos un apellido; el WhatsApp es opcional. Se toca "Agregar clienta" y desde ese momento todo lo que comente se le aparta solo. Si tenía un aviso "Pide DM", lo que pidió pasa a su casillero. Si el usuario ya era de otra clienta, avisa a quién está ligado y no lo cambia.
- **Usuarios de redes ligados**: buscar y quitar un @usuario mal ligado.
- **Cerrar sesión**.

## Activar los avisos en el celular
- **iPhone**: primero instalar el panel: abrirlo en Safari → botón Compartir → "Agregar a pantalla de inicio". Luego abrirlo desde ese ícono, ir a Ajustes y tocar "🔔 Activar avisos en este teléfono". Debe llegar "🔔 Avisos activados". Necesita iOS 16.4 o más reciente.
- **Android**: abrir el panel en Chrome → Ajustes → "🔔 Activar avisos en este teléfono".
- Si no llegan: (1) en Ajustes debe decir que este teléfono recibe avisos; si no, activarlos otra vez. (2) Revisar en los ajustes del teléfono que las notificaciones de "OP Live" estén permitidas. (3) Revisar que no esté en modo No molestar o concentración. (4) En iPhone, abrir el panel desde el ícono de la pantalla de inicio, no desde Safari. (5) Probar con "Mandar aviso de prueba".
- Cada nivel recibe avisos distintos: acomodo recibe los de llevar y regresar prendas; presentadora solo "Pide DM"; supervisor además recibe "📝 Registrar a @usuario"; resurtido solo "🧺 Van N prendas por resurtir"; los demás, pagos, vencidos y cajas listas.

## Problemas frecuentes
- **"Tu sesión expiró"**: volver a entrar con correo y contraseña.
- **Olvidé mi contraseña**: el panel no tiene recuperación; hay que pedírsela a una Dueña, que la cambia en el tablero de Supabase.
- **"Tu cuenta todavía no tiene acceso"**: una Dueña debe asignar el nivel en Ajustes → Equipo.
- **"Sin conexión a internet"**: revisar la señal e intentar de nuevo. El panel se actualiza solo cada pocos segundos.
- **No se están apartando los comentarios**: revisar en En vivo si el agente está encendido; si no, abrir "Iniciar agente" en la computadora de la tienda. Mientras, usar "Capturar comentario a mano".
- **Una clienta dice que comentó y no le apartó**: buscar la clave en Prendas para ver quién la tiene. Si otra la pidió antes, quedó en espera. Si es nueva, está en "Pide DM" esperando registrarse.
- **La clienta comentó una clave que no existe o mal escrita**: no se aparta. Se captura a mano con la clave correcta.
- **Se apartó una prenda a la clienta equivocada**: En vivo → "Quitar" en ese apartado, y capturarla a mano para la correcta.
- **La prenda no está en el casillero que dice el panel**: revisar la charola de pendientes y la pestaña Acomodo (puede faltar llevarla o haber cambiado de clienta).

## App de Cajas (la otra aplicación)
Ahí se guardan las prendas ya pagadas de cada clienta en su caja de resguardo hasta que se le envían. Abajo tiene: **Cajas**, **Clientas**, **Escanear** (botón rojo del centro), **Pedido nuevo** y **Reportes**. Arriba a la derecha están el botón **Live** (pasa al panel del live) y el engrane de **Ajustes**. Desde el panel del live se llega a Cajas con el botón **Cajas** de arriba a la derecha.
- **Cajas**: la lista de las 50 cajas de resguardo con filtros (todas, ocupadas, libres, vencidas). Al tocar una caja se ve de quién es, sus pedidos, sus prendas y el total.
- **Caja libre**: se elige a la clienta que ya pagó para asignarle esa caja ("Asignar caja"). Cuando una clienta paga completo en el panel del live, el sistema le asigna caja solo y el panel dice a qué caja mover las prendas.
- **Reasignar caja**: dentro de una caja ocupada, para mover todo a otra caja.
- **Video del pedido**: cada pedido de una caja debe tener su video de la mercancía. Si un pedido dice **Sin video · Agregar** (por ejemplo los que llegan del live), se toca ese botón y se elige **Grabar video** (abre la cámara) o **Cargar del celular**; después **Guardar video**. Si el video es muy pesado se comprime solo antes de subir. Lo pueden hacer Dueña, Operación y Operación live. Operación live solo puede ponerlo cuando el pedido no tiene video; si hay que cambiar uno ya guardado, lo hace una Dueña u Operación.
- **Enviar caja** (solo si todos sus pedidos ya tienen video; si falta alguno, la pantalla de envío dice cuáles y ahí mismo se agregan): cuando se le manda su paquete a la clienta. Se elige la paquetería, se escribe la guía (y si se quiere peso, medidas y costo) y se toma la foto de la guía. Después de enviarla, la caja queda libre otra vez.
- **Avisos de tiempo**: una caja que lleva 15 días o más se marca en aviso, y a los 20 días aparece en rojo ("Esa mercancía debe enviarse").
- **Escanear**: abre la cámara para leer el QR de la etiqueta de una caja y abrirla directo. También se puede leer desde una foto o escribir el código (por ejemplo A1).
- **Clientas**: la lista de clientas, su ficha con sus datos y domicilio ("Editar datos"), su caja y su historial.
- **Pedido nuevo**: para registrar a mano un pedido en una caja (prendas por categoría y, si se quiere, el video de la mercancía).
- **Reportes**: lo vendido por día, semana, mes o fechas a elegir: total vendido, pedidos, prendas, clientas que compraron, clientas nuevas, cajas enviadas, costo de envíos y ventas por categoría. Más abajo, **Ventas por live**: por cada live del periodo, cuántas prendas se pidieron y cuántas se pagaron, cuántas clientas pidieron y cuántas pagaron, la venta del live (lo ya pagado) y el cheque promedio (venta entre clientas que pagaron). También sale en el Excel, en la hoja "Por live".
- **Ajustes de Cajas**: tu nombre, **Administrar cajas** (crear cajas e imprimir sus QR) y precios por categoría. Las etiquetas nuevas de cajas de resguardo (con la franja negra) se generan en el panel del live → Prendas → Etiquetas de cajas de resguardo.
- Quién puede: el Supervisor en la app de Cajas está en "Modo monitor": ve todo y puede editar los datos de las clientas (Clientas → su ficha → "Editar datos"); no puede borrar clientas ni cambiar cajas o pedidos. Para agregar una clienta nueva usa el panel del live → Ajustes → Agregar clienta. Operación no ve Reportes. Operación live entra en modo consulta: abajo solo tiene **Cajas** y **Escanear**; ve cada caja con el nombre de la clienta, sus pedidos y prendas, y puede agregar el video de los pedidos (**Sin video · Agregar**). No ve teléfono ni dirección de las clientas, ni Clientas, Pedido nuevo, Reportes o Ajustes, y no puede marcar una caja como enviada. Para volver a su trabajo toca **Live** arriba a la derecha. Presentadora y Resurtido no entran a la app de Cajas: los manda a su pestaña del panel.

## Lo que esta guía no cubre
Datos del momento (en qué casillero o caja está una prenda, si alguien ya pagó, cuánto debe una clienta): eso se ve en el panel (Prendas → Buscar, Casilleros) o en la app de Cajas. Tampoco cubre Prime Live (mayoristas) ni temas de dinero, bancos o envíos fuera de lo que se registra en la app.
`;
