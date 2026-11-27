-- Guías con seguro (decisión de la dueña, 27 nov 2026): la cuenta de Skydrop tiene la protección obligatoria.
-- Cada guía se cotiza y se compra asegurada por el total de los pedidos del paquete.
alter table public.envios_skydrop add column if not exists valor_declarado numeric;
