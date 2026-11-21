-- "La clienta la recoge en tienda" libera la caja de resguardo en ese momento.
--   · Al elegir la opción, las prendas se sacan de la caja y se apartan con el nombre de la clienta:
--     la asignación deja de ocupar la caja (estado 'enviada', paquetería 'Recoge en tienda') y queda
--     "por recoger" (recogida_en vacío) hasta que la clienta pasa.
--   · Cuando pasa, Dueña u Operación tocan "Entregada a la clienta en tienda" (recogida_en). Ahí se exige
--     el video de cada pedido, igual que en un envío.
--   · Se pueden liberar de una vez varias cajas de la misma clienta.

alter table public.asignaciones
  add column if not exists recogida_en timestamptz,
  add column if not exists recogida_por text;

-- Las que ya se habían entregado en tienda con el flujo anterior
update public.asignaciones set recogida_en = enviada_en, recogida_por = enviada_por
 where estado = 'enviada' and lista_para = 'tienda' and recogida_en is null;

-- El video se exige al enviar por paquetería y al entregar en tienda; no al liberar la caja para recoger
create or replace function public.asignaciones_envio_con_video() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_faltan int;
begin
  if (new.estado = 'enviada' and old.estado is distinct from 'enviada' and (new.lista_para is distinct from 'tienda' or new.recogida_en is not null))
     or (new.recogida_en is not null and old.recogida_en is null) then
    select count(*) into v_faltan from pedidos where asignacion_id = new.id and coalesce(trim(video), '') = '';
    if v_faltan > 0 then
      raise exception 'FALTA_VIDEO: % sin video', v_faltan using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

-- Una o varias cajas de la misma clienta pasan a "recoge en tienda": quedan libres en ese momento
create or replace function public.caja_recoge_en_tienda(p_asignaciones uuid[], p_usuario text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a asignaciones;
  v_id uuid;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
  v_clienta uuid;
  v_cl text;
  v_cajas text[] := '{}';
  v_ped integer := 0;
  v_pren integer := 0;
  n_ped integer;
  n_pren integer;
  v_falta text;
  v_txt text;
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion', 'live')) then
    raise exception 'Tu nivel de acceso no permite marcar la caja para recoger en tienda.';
  end if;
  if coalesce(array_length(p_asignaciones, 1), 0) = 0 then raise exception 'Falta decir qué caja.'; end if;

  for v_id in select x from unnest(p_asignaciones) x group by x order by min(x::text) loop
    select * into a from asignaciones where id = v_id for update;
    if not found or a.estado <> 'activa' then raise exception 'Esa caja ya se entregó o cambió. Revisa de nuevo.'; end if;
    if v_clienta is null then v_clienta := a.clienta_id;
    elsif a.clienta_id <> v_clienta then raise exception 'Las cajas son de clientas distintas.'; end if;
    if a.guia_pegada_en is not null then raise exception 'La caja % ya tiene la guía pegada: deshaz esa marca primero.', a.caja; end if;

    select count(*), coalesce(sum(prendas), 0) into n_ped, n_pren from pedidos where asignacion_id = a.id;
    if n_ped = 0 then raise exception 'La caja % todavía no tiene pedidos.', a.caja; end if;
    select string_agg(live_folio(c.folio), ', ' order by c.folio) into v_falta
      from live_cuentas c
     where c.asignacion_id = a.id and c.estado = 'pagada' and c.pedido_id is not null and c.en_caja_en is null;
    if v_falta is not null then
      raise exception 'Todavía falta pasar a la caja %: %. Márcalo con "Ya está en la caja" en el panel del live → Casilleros.', a.caja, v_falta;
    end if;

    update asignaciones
       set estado = 'enviada', enviada_en = now(), enviada_por = v_por, paqueteria = 'Recoge en tienda', guia = null,
           lista_guia_en = now(), lista_guia_por = v_por, lista_para = 'tienda', recogida_en = null, recogida_por = null
     where id = a.id;
    v_cajas := v_cajas || a.caja;
    v_ped := v_ped + n_ped;
    v_pren := v_pren + n_pren;
  end loop;

  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = v_clienta;
  v_txt := case when array_length(v_cajas, 1) = 1 then 'Se liberó la caja ' || v_cajas[1]
                else 'Se liberaron las cajas ' || array_to_string(v_cajas[1:array_length(v_cajas, 1) - 1], ', ') || ' y ' || v_cajas[array_length(v_cajas, 1)] end;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('caja', 'recoge-tienda:' || p_asignaciones[1] || ':' || extract(epoch from now())::bigint,
          format('🛍️ %s recoge en tienda', v_cl),
          format('%s %s en %s %s. %s: sus prendas se apartan con su nombre. Avísale que ya puede pasar. Lo marcó %s.',
                 v_pren, case when v_pren = 1 then 'prenda' else 'prendas' end,
                 v_ped, case when v_ped = 1 then 'pedido' else 'pedidos' end, v_txt, split_part(coalesce(v_por, 'el equipo'), '@', 1)),
          'index.html#/clienta/' || v_clienta, 'duena')
  on conflict (clave) do nothing;
  return jsonb_build_object('cajas', to_jsonb(v_cajas), 'clienta', v_cl, 'clienta_id', v_clienta, 'pedidos', v_ped, 'prendas', v_pren);
end $$;

-- Marcar una caja (p_lista = true) o deshacerlo (p_lista = false)
create or replace function public.caja_lista_para_tienda(p_asignacion uuid, p_lista boolean default true, p_usuario text default null)
returns public.asignaciones
language plpgsql security definer set search_path = public as $$
declare
  a asignaciones;
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion', 'live')) then
    raise exception 'Tu nivel de acceso no permite marcar la caja para recoger en tienda.';
  end if;

  if coalesce(p_lista, true) then
    perform caja_recoge_en_tienda(array[p_asignacion], p_usuario);
    select * into a from asignaciones where id = p_asignacion;
    return a;
  end if;

  -- Deshacer
  select * into a from asignaciones where id = p_asignacion for update;
  if not found then raise exception 'Esa caja ya se entregó o cambió. Revisa de nuevo.'; end if;
  if a.lista_para is distinct from 'tienda' then return a; end if;
  if a.estado = 'activa' then   -- marcada con el flujo anterior: la caja seguía ocupada
    update asignaciones set lista_guia_en = null, lista_guia_por = null where id = a.id returning * into a;
    return a;
  end if;
  if a.recogida_en is not null then raise exception 'Ese pedido ya se le entregó a la clienta: ya no se puede deshacer.'; end if;
  if exists (select 1 from asignaciones x where x.caja = a.caja and x.estado = 'activa') then
    raise exception 'La caja % ya la ocupa otra clienta: ya no se puede deshacer. Si la clienta ya no pasa por su pedido, una Dueña u Operación le asigna otra caja.', a.caja;
  end if;
  update asignaciones
     set estado = 'activa', enviada_en = null, enviada_por = null, paqueteria = null, lista_guia_en = null, lista_guia_por = null
   where id = a.id returning * into a;
  return a;
end $$;

-- La clienta ya pasó por su pedido (Dueña u Operación). Exige el video de cada pedido.
create or replace function public.caja_entregada_en_tienda(p_asignacion uuid, p_usuario text default null)
returns public.asignaciones
language plpgsql security definer set search_path = public as $$
declare
  a asignaciones;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion')) then
    raise exception 'Solo una Dueña u Operación pueden marcar el pedido como entregado.';
  end if;
  select * into a from asignaciones where id = p_asignacion for update;
  if not found then raise exception 'Esa caja ya se entregó o cambió. Revisa de nuevo.'; end if;
  if a.lista_para is distinct from 'tienda' then raise exception 'Esta caja no está marcada para recoger en tienda.'; end if;
  if a.recogida_en is not null then raise exception 'Ese pedido ya se había entregado a la clienta.'; end if;
  update asignaciones
     set estado = 'enviada', enviada_en = now(), enviada_por = coalesce(enviada_por, v_por), paqueteria = 'Recoge en tienda',
         recogida_en = now(), recogida_por = v_por, notas_envio = coalesce(notas_envio, 'Entregada a la clienta en tienda')
   where id = a.id returning * into a;
  return a;
end $$;

revoke all on function public.caja_recoge_en_tienda(uuid[], text) from public, anon;
revoke all on function public.caja_lista_para_tienda(uuid, boolean, text) from public, anon;
revoke all on function public.caja_entregada_en_tienda(uuid, text) from public, anon;
grant execute on function public.caja_recoge_en_tienda(uuid[], text) to authenticated, service_role;
grant execute on function public.caja_lista_para_tienda(uuid, boolean, text) to authenticated, service_role;
grant execute on function public.caja_entregada_en_tienda(uuid, text) to authenticated, service_role;

-- La burbuja de ayuda distingue "por recoger en tienda" de un envío
do $$
declare def text;
begin
  select pg_get_functiondef('public.ayuda_consulta(text, text, date, date)'::regprocedure) into def;
  if position('por_recoger_en_tienda' in def) = 0 then
    def := replace(def,
      '''cajas_enviadas'', nullif((select count(*) from asignaciones e where e.clienta_id = h.id and e.estado = ''enviada''), 0),',
      '''cajas_enviadas'', nullif((select count(*) from asignaciones e where e.clienta_id = h.id and e.estado = ''enviada'' and not (e.lista_para is not distinct from ''tienda'' and e.recogida_en is null)), 0),
             ''por_recoger_en_tienda'', nullif((select count(*) from asignaciones e where e.clienta_id = h.id and e.estado = ''enviada'' and e.lista_para = ''tienda'' and e.recogida_en is null), 0),');
    if position('por_recoger_en_tienda' in def) = 0 then raise exception 'No se encontró dónde cambiar ayuda_consulta.'; end if;
    def := replace(def,
      'from asignaciones a where a.estado = ''enviada'' and (a.enviada_en at time zone v_tz)::date between p_desde and p_hasta)',
      'from asignaciones a where a.estado = ''enviada'' and not (a.lista_para is not distinct from ''tienda'' and a.recogida_en is null) and (a.enviada_en at time zone v_tz)::date between p_desde and p_hasta)');
    execute def;
  end if;
end $$;
