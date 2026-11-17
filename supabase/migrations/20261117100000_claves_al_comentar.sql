-- =====================================================================
-- Las prendas se dan de alta solas al momento de comentarlas.
--   Ya no hace falta "Registrar rango": la primera vez que alguien comenta (o manda al bot)
--   una clave de etiqueta, la prenda se crea como disponible y se aparta ahí mismo.
--   Solo valen las claves de las etiquetas impresas: DOS letras y DOS números
--   (AB10 … ZY98; letras sin O, I, L ni Ñ, distintas entre sí; números sin 11, 22 … 88).
--   Las demás claves (A23, AB7) siguen saliendo como "no existe", salvo que se registren a mano.
-- Se puede pegar varias veces sin dañar nada.
-- =====================================================================

create or replace function public.prenda_asegurar(p integer) returns void
language plpgsql set search_path = public as $$
begin
  -- Dos letras: números internos 2278 … 52371. Dos números: del 10 al 98.
  if p is null or p <= 2277 or not clave_valida(p) or (p - 2278) % 99 + 1 < 10 then return; end if;
  begin
    insert into prendas (numero, precio, registrada_por)
    values (p, coalesce((select precio from live_config limit 1), 89), 'comentario')
    on conflict (numero) do nothing;
  exception when insufficient_privilege then
    null;   -- quien no puede dar de alta prendas la verá como "no existe", igual que antes
  end;
end $$;

-- live_comentario (comentarios de las redes) y live_apartar (clientas registradas y bot de WhatsApp):
-- antes de buscar la prenda, se asegura de que exista.
do $do$
declare
  f text;
  def text;
  buscar constant text := 'select * into v_pr from prendas where numero = v_n for update;';
begin
  foreach f in array array['live_comentario', 'live_apartar'] loop
    select pg_get_functiondef(p.oid) into strict def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = f;
    if position('prenda_asegurar' in def) = 0 then
      if position(buscar in def) = 0 then
        raise exception 'No encontré dónde busca la prenda la función %: revisar a mano.', f;
      end if;
      execute replace(def, buscar, 'perform prenda_asegurar(v_n);' || E'\n    ' || buscar);
    end if;
  end loop;
end $do$;
