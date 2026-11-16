-- =====================================================================
-- Avisos al celular de "Operación live" (acomodo)
--   📦 A23 → C-007 · Ana López            (prenda apartada: llevarla a su casillero)
--   🔁 A23: de C-007 a C-009               (se liberó y pasó a la siguiente en espera)
--   ↩️ Regresar A23 al rack · estaba en C-007   (se liberó y nadie la esperaba)
-- Solo le llegan a quien tiene nivel Operación live. Los de pagos, vencidos y cajas listas
-- le siguen llegando como al resto del equipo (menos a la presentadora).
-- Se puede pegar varias veces sin dañar nada.
-- =====================================================================

create or replace function public.avisos_acomodo() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  a live_apartados;
  c live_cuentas;
  v_cl text;
  v_prueba text := '';
  v_et text;
  v_antes text;
  v_otra boolean;
begin
  select * into a from live_apartados where id = new.id;      -- estado final de la operación
  if not found then return null; end if;
  select trim(nombre || coalesce(' ' || apellidos, '')), case when telefono like '00%' then ' (prueba)' else '' end
    into v_cl, v_prueba from clientas where id = a.clienta_id;
  v_et := coalesce(live_num(a.prenda), '#' || (select num from prime_prendas where id = a.prime_prenda));
  select * into c from live_cuentas where id = a.cuenta_id;

  if a.estado = 'apartada' and a.acomodada_en is null then
    -- ¿Viene de otro casillero? (se liberó y la tomó la siguiente en espera)
    select k.casillero into v_antes
      from live_apartados x join live_cuentas k on k.id = x.cuenta_id
     where x.id <> a.id and x.estado = 'liberada'
       and ((a.prenda is not null and x.prenda = a.prenda) or (a.prime_prenda is not null and x.prime_prenda = a.prime_prenda))
       and k.casillero is not null and k.casillero is distinct from c.casillero
     order by x.actualizado_en desc limit 1;
    insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
    values ('acomodo', 'acomodo:' || a.id || ':' || coalesce(a.cuenta_id::text, '-'),
            case when v_antes is not null then format('🔁 %s: de %s a %s%s', v_et, v_antes, coalesce(c.casillero, 'sin casillero'), v_prueba)
                 else format('📦 %s → %s%s', v_et, coalesce(c.casillero, '⚠️ sin casillero'), v_prueba) end,
            case when v_antes is not null then format('Ahora es de %s · cámbiala de casillero', v_cl)
                 else format('%s · llévala a su casillero', v_cl) end,
            'live.html#acomodo', 'live')
    on conflict (clave) do nothing;

  elsif a.estado = 'liberada' and a.regresada_en is null and tg_op = 'UPDATE' and old.estado = 'apartada' then
    -- Si la tomó otra clienta, el aviso de arriba ya dice a dónde va. Si la cuenta venció,
    -- ya llega el aviso general de vencidos con todas sus prendas.
    select exists (select 1 from live_apartados x where x.id <> a.id and x.estado in ('apartada', 'pagada')
                    and ((a.prenda is not null and x.prenda = a.prenda) or (a.prime_prenda is not null and x.prime_prenda = a.prime_prenda)))
      into v_otra;
    if not v_otra and coalesce(c.estado, '') <> 'vencida' then
      insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
      values ('acomodo', 'rack:' || a.id,
              format('↩️ Regresar %s al rack%s', v_et, v_prueba),
              format('Estaba en %s (%s)', coalesce(c.casillero, 'su casillero'), v_cl),
              'live.html#acomodo', 'live')
      on conflict (clave) do nothing;
    end if;
  end if;
  return null;
end $$;

drop trigger if exists avisos_acomodo on public.live_apartados;
create constraint trigger avisos_acomodo after insert or update of estado, cuenta_id on public.live_apartados
  deferrable initially deferred for each row execute function public.avisos_acomodo();

-- Texto del aviso de prueba según el nivel
create or replace function public.avisos_prueba() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not es_del_equipo() then raise exception 'Tu cuenta todavía no tiene nivel de acceso.'; end if;
  insert into avisos (tipo, titulo, cuerpo, url, usuario_id)
  values ('prueba', '🔔 Avisos activados',
          case mi_rol()
            when 'presentadora' then 'Así te llegará a quién pedirle DM durante el live.'
            when 'live' then 'Así te llegará cada prenda que hay que llevar a su casillero o regresar al rack.'
            else 'Así te llegarán los pagos, vencimientos y cajas listas.' end,
          case mi_rol() when 'presentadora' then 'live.html#dm' when 'live' then 'live.html#acomodo' else 'live.html#ajustes' end,
          auth.uid());
end $$;

revoke all on function public.avisos_acomodo(), public.avisos_prueba() from public, anon;
grant execute on function public.avisos_prueba() to authenticated, service_role;
