-- 1. Clientas que compran muchas prendas: al pagar, si necesitan caja nueva, se les da una GRANDE (40 prendas, I–J)
--    cuando hay una libre. "Muchas" = entre todo lo que ha pagado (su historial de pedidos) y este pedido suma
--    live_config.clienta_grande_prendas o más (30 al inicio). Las demás siguen recibiendo la caja más chica donde quepan.
-- 2. Cuando una caja chica (menos de 40) está por llenarse con pedidos ya pagados —le quedan
--    live_config.caja_aviso_faltan lugares o menos (5 al inicio)—, se avisa al equipo UNA vez para pasarla a una de 40
--    (app de Cajas → la caja → "Reasignar a otra caja"). El aviso dice qué cajas de 40 están libres.

alter table public.live_config add column if not exists clienta_grande_prendas integer not null default 30
  constraint live_config_clienta_grande_check check (clienta_grande_prendas > 0);
alter table public.live_config add column if not exists caja_aviso_faltan integer not null default 5
  constraint live_config_caja_aviso_check check (caja_aviso_faltan >= 0);

create or replace function public.caja_para_pedido(
  p_clienta uuid, p_prendas integer, p_excluir uuid default null, p_desde timestamptz default null
) returns public.asignaciones
language plpgsql set search_path = public as $$
declare
  a asignaciones;
  v_caja text;
  v_grande boolean;
begin
  -- 1) Una de sus cajas donde todavía quepa (y que no esté ya lista para guía o para recoger)
  select x.* into a
    from asignaciones x join cajas k on k.id = x.caja
   where x.clienta_id = p_clienta and x.estado = 'activa' and x.lista_guia_en is null
     and (p_excluir is null or x.id <> p_excluir)
     and coalesce((select sum(p.prendas) from pedidos p where p.asignacion_id = x.id), 0) + p_prendas <= k.capacidad
   order by x.asignada_en desc
   limit 1;
  if found then return a; end if;

  -- 2) Una caja libre. Clienta de muchas prendas: la más grande. Las demás: la más chica donde quepa.
  v_grande := coalesce((select sum(p.prendas) from pedidos p where p.clienta_id = p_clienta), 0) + p_prendas
              >= coalesce((select clienta_grande_prendas from live_config limit 1), 30);
  select k.id into v_caja from cajas k
   where not exists (select 1 from asignaciones x where x.caja = k.id and x.estado = 'activa')
   order by (k.capacidad >= p_prendas) desc,
            case when v_grande or k.capacidad < p_prendas then -k.capacidad else k.capacidad end,
            substring(k.id from '^[^0-9]*'), nullif(substring(k.id from '[0-9]+'), '')::integer nulls first, k.id
   limit 1
   for update skip locked;
  if v_caja is null then return null; end if;

  insert into asignaciones (caja, clienta_id, estado, asignada_en, asignada_por, movimientos)
  values (v_caja, p_clienta, 'activa', coalesce(p_desde, now()), 'Sistema de lives', '[]'::jsonb)
  returning * into a;
  return a;
end $$;

-- Aviso "pásala a una caja de 40": al entrar un pedido a una caja chica que queda casi llena
create or replace function public.pedidos_aviso_caja_casi_llena() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  a asignaciones;
  v_cap integer;
  v_n integer;
  v_faltan integer;
  v_cl text;
  v_libres text;
begin
  select * into a from asignaciones where id = new.asignacion_id and estado = 'activa';
  if not found then return new; end if;
  select capacidad into v_cap from cajas where id = a.caja;
  if v_cap is null or v_cap >= 40 then return new; end if;
  select coalesce(sum(prendas), 0) into v_n from pedidos where asignacion_id = a.id;
  v_faltan := coalesce((select caja_aviso_faltan from live_config limit 1), 5);
  if v_n < v_cap - v_faltan then return new; end if;

  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;
  select string_agg(k.id, ', ' order by substring(k.id from '^[^0-9]*'), nullif(substring(k.id from '[0-9]+'), '')::integer) into v_libres
    from cajas k
   where k.capacidad >= 40 and not exists (select 1 from asignaciones x where x.caja = k.id and x.estado = 'activa');
  perform avisos_encolar('caja', 'cambiar-caja:' || a.id,
    format('📦 Caja %s casi llena · %s', a.caja, v_cl),
    format('Lleva %s de %s prendas ya pagadas. Pásala a una caja de 40: %s En Cajas → caja %s → "Reasignar a otra caja".',
           v_n, v_cap,
           case when v_libres is null then 'ahora no hay cajas de 40 libres (hay que enviar o liberar una).'
                else 'libres ' || v_libres || '.' end, a.caja),
    'index.html#/caja/' || a.caja);
  return new;
end $$;

create or replace trigger aviso_caja_casi_llena after insert or update of asignacion_id, prendas on public.pedidos
  for each row execute function public.pedidos_aviso_caja_casi_llena();
