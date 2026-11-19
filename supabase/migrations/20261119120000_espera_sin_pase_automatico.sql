-- Con el live ya cerrado, las prendas que se liberan solas (pedido vencido o reserva "Pide DM" vencida)
-- ya NO pasan automáticamente a la siguiente clienta de la lista de espera: quedan libres, se avisa a las
-- Dueñas quién las esperaba y ellas deciden si se la dan (Prendas → Buscar → "Dársela a quien espera").
-- Durante el live todo sigue igual: la lista de espera avanza sola.
-- "Liberar" y "Se arrepintió" (acciones de una persona, con confirmación) siguen pasando a la siguiente.

-- Quiénes esperan una prenda, en orden
create or replace function public.live_espera_nombres(p_prenda integer) returns text
language sql stable set search_path = public as $$
  select string_agg(split_part(cl.nombre, ' ', 1) || coalesce(' ' || split_part(cl.apellidos, ' ', 1), ''), ', ' order by e.mensaje_en, e.creado_en)
    from live_apartados e join clientas cl on cl.id = e.clienta_id
   where e.prenda = p_prenda and e.estado = 'espera'
$$;

-- Aviso a las Dueñas cuando vence un pedido y alguna de sus prendas tenía lista de espera
create or replace function public.live_vencida_espera_aviso(p_cuenta uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  c live_cuentas;
  v_lista text;
begin
  select * into c from live_cuentas where id = p_cuenta;
  select string_agg(live_num(a.prenda) || ' → ' || live_espera_nombres(a.prenda), '; ' order by a.prenda) into v_lista
    from live_apartados a
   where a.cuenta_id = c.id and a.estado = 'liberada' and a.prenda is not null and live_espera_nombres(a.prenda) is not null;
  if v_lista is null then return; end if;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('espera', 'espera-vencida:' || c.id || ':' || extract(epoch from now())::bigint,
          format('🕐 Venció %s: prendas con lista de espera', live_folio(c.folio)),
          format('Las esperaban: %s. No se le pasaron solas a nadie. Para dársela a la primera: Prendas → Buscar la clave → "Dársela a quien espera".', v_lista),
          'live.html#prendas', 'duena')
  on conflict (clave) do nothing;
end $$;

-- Reserva "Pide DM" que se suelta o vence: durante el live pasa a la siguiente; con el live cerrado, solo se avisa
create or replace function public.live_espera_auto(p_prenda integer) returns void
language plpgsql security definer set search_path = public as $$
declare
  e live_apartados;
begin
  select * into e from live_apartados where prenda = p_prenda and estado = 'espera' order by mensaje_en, creado_en limit 1;
  if not found then return; end if;
  if exists (select 1 from lives where id = e.live_id and estado = 'activo') then
    perform live_ofrecer_espera(p_prenda);
    return;
  end if;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('espera', 'espera-libre:' || p_prenda || ':' || extract(epoch from now())::bigint,
          format('🕐 %s quedó libre y tiene lista de espera', live_num(p_prenda)),
          format('La esperaban: %s. No se le pasó sola a nadie. Para dársela a la primera: Prendas → Buscar %s → "Dársela a quien espera".',
                 live_espera_nombres(p_prenda), live_num(p_prenda)),
          'live.html#prendas', 'duena')
  on conflict (clave) do nothing;
end $$;

do $$
declare def text; nuevo text;
begin
  -- Pedido vencido: ya no se reparte a la lista de espera
  select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'live_revisar_vencimientos';
  if position('live_ofrecer_espera' in def) > 0 then
    nuevo := regexp_replace(def, 'for v_prenda in select prenda from live_apartados.*?perform live_ofrecer_espera\(v_prenda\);\s*end loop;',
                            'perform live_vencida_espera_aviso(c.id);');
    if position('live_ofrecer_espera' in nuevo) > 0 or position('live_vencida_espera_aviso' in nuevo) = 0 then
      raise exception 'No se pudo cambiar live_revisar_vencimientos.';
    end if;
    execute nuevo;
  end if;
  -- Reserva de clienta nueva que vence o se suelta
  select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'live_soltar_reserva';
  if position('live_espera_auto' in def) = 0 then
    if position('perform live_ofrecer_espera(r.prenda);' in def) = 0 then raise exception 'No se pudo cambiar live_soltar_reserva.'; end if;
    execute replace(def, 'perform live_ofrecer_espera(r.prenda);', 'perform live_espera_auto(r.prenda);');
  end if;
end $$;

-- La Dueña decide dársela a la primera en espera
create or replace function public.live_espera_dar(p_prenda integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_est text;
  v_cl uuid;
  a live_apartados;
begin
  if not es_duena() then raise exception 'Solo una Dueña puede dar una prenda de la lista de espera.'; end if;
  select estado into v_est from prendas where numero = p_prenda;
  if v_est is distinct from 'disponible' then raise exception 'Esa prenda no está libre.'; end if;
  if live_espera_nombres(p_prenda) is null then raise exception 'Nadie está en espera de esa prenda.'; end if;
  v_cl := live_ofrecer_espera(p_prenda);
  if v_cl is null then raise exception 'No se pudo pasar la prenda. Intenta de nuevo.'; end if;
  select * into a from live_apartados where prenda = p_prenda and clienta_id = v_cl and estado = 'apartada';
  return jsonb_build_object('clave', live_num(p_prenda),
    'clienta', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = v_cl),
    'casillero', coalesce(a.casillero, (select casillero from live_cuentas where id = a.cuenta_id)),
    'folio', (select live_folio(folio) from live_cuentas where id = a.cuenta_id));
end $$;
revoke all on function public.live_espera_dar(integer) from public, anon;
grant execute on function public.live_espera_dar(integer) to authenticated, service_role;
