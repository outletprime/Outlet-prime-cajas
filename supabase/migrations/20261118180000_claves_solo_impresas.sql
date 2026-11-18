-- =====================================================================
-- Solo se aparta con una clave que exista en las etiquetas impresas.
--
-- Regla del negocio: si una clienta escribe mal la clave y otra la escribe bien, la prenda es de
-- quien la escribió bien, aunque la otra haya comentado antes.
-- Antes, una clave bien formada pero inexistente (por ejemplo AN84 en vez de AB84) se daba de
-- alta sola al comentarla y la clienta quedaba con una prenda que no existe. Ahora las prendas
-- solo se dan de alta al mandar a imprimir sus etiquetas (etiquetas_lotes): una clave que no
-- está en ningún lote impreso no existe, y ese comentario no aparta nada.
-- =====================================================================
create or replace function public.prenda_asegurar(p integer) returns void
language plpgsql set search_path = public as $$
begin
  -- Dos letras: números internos 2278 … 52371. Dos números: del 10 al 98.
  if p is null or p <= 2277 or not clave_valida(p) or (p - 2278) % 99 + 1 < 10 then return; end if;
  -- Solo claves de etiquetas que ya se mandaron a imprimir
  if not exists (select 1 from etiquetas_lotes l where p between l.desde and l.hasta) then return; end if;
  begin
    insert into prendas (numero, precio, registrada_por)
    values (p, coalesce((select precio from live_config limit 1), 89), 'comentario')
    on conflict (numero) do nothing;
  exception when insufficient_privilege then
    null;   -- quien no puede dar de alta prendas la verá como "no existe", igual que antes
  end;
end $$;
