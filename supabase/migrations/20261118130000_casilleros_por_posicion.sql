-- =====================================================================
-- Casilleros nombrados por su posición física.
--
-- Hay 30 casilleros en tránsito: 6 columnas (A a F) por 5 filas (1 a 5), 10 prendas cada uno.
-- Antes se llamaban C-001 … C-030; ahora C-A1 … C-F5 (columna + fila), para ubicarlos de un vistazo.
-- Llevan "C-" delante porque las cajas de resguardo de la app de Cajas ya se llaman A1 … H5:
-- sin el prefijo, "Mover A1 → caja A1" no se entendería.
-- Se llenan por filas (C-A1, C-B1 … C-F1, luego la fila 2), igual que antes: el orden no cambia.
-- Los C-031 … C-100 siguen existiendo, apagados, por si se agregan más casilleros.
-- =====================================================================
update public.casilleros
   set id = 'C-' || chr(65 + (orden - 1) % 6) || ((orden - 1) / 6 + 1)
 where orden between 1 and 30
   and id = 'C-' || lpad(orden::text, 3, '0');
