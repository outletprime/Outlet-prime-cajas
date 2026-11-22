-- La caja de resguardo se libera en cuanto se marca su salida, sea por guía o para recoger en tienda.
--   · Estado nuevo de la asignación: 'por_entregar' = sus prendas ya salieron de la caja (la caja queda libre)
--     y falta entregarlas: a la paquetería (lista_para 'guia') o a la clienta en tienda (lista_para 'tienda').
--   · "Caja lista para generar guía" y "La clienta la recoge en tienda" pasan la asignación a 'por_entregar'.
--   · La guía pegada y "Marcar como enviado" se hacen sobre el pedido por entregar; 'enviada' sigue siendo el final
--     (ahí se exige el video de cada pedido).

alter table public.asignaciones drop constraint if exists asignaciones_estado_check;
alter table public.asignaciones add constraint asignaciones_estado_check check (estado in ('activa', 'por_entregar', 'enviada'));
create index if not exists asignaciones_por_entregar on public.asignaciones (clienta_id) where estado = 'por_entregar';

-- El video se exige al quedar 'enviada' (envío por paquetería o entrega en tienda)
create or replace function public.asignaciones_envio_con_video() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_faltan int;
begin
  if new.estado = 'enviada' and old.estado is distinct from 'enviada'
     and not (old.estado = 'enviada') and not (new.lista_para is not distinct from 'tienda' and new.recogida_en is null) then
    select count(*) into v_faltan from pedidos where asignacion_id = new.id and coalesce(trim(video), '') = '';
    if v_faltan > 0 then
      raise exception 'FALTA_VIDEO: % sin video', v_faltan using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

-- Lo que ya estaba "por recoger en tienda" con el esquema anterior ('enviada' sin recogida_en)
update public.asignaciones
   set estado = 'por_entregar', enviada_en = null, enviada_por = null, paqueteria = null
 where estado = 'enviada' and lista_para = 'tienda' and recogida_en is null;

-- Las cajas que ya estaban marcadas (lista para guía, guía pegada o recoge en tienda) quedan libres
update public.asignaciones
   set estado = 'por_entregar', lista_para = coalesce(lista_para, 'guia')
 where estado = 'activa' and lista_guia_en is not null;

-- Lista para generar guía: la caja queda libre y se avisa al Supervisor. p_lista = false lo deshace.
create or replace function public.caja_lista_para_guia(p_asignacion uuid, p_lista boolean default true, p_usuario text default null)
returns public.asignaciones
language plpgsql security definer set search_path = public as $$
declare
  a asignaciones;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
  v_cl text;
  v_ped integer;
  v_pren integer;
  v_falta text;
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion', 'live')) then
    raise exception 'Tu nivel de acceso no permite marcar la caja como lista para guía.';
  end if;
  select * into a from asignaciones where id = p_asignacion for update;
  if not found or a.estado = 'enviada' then raise exception 'Esa caja ya se envió o cambió. Revisa de nuevo.'; end if;

  if not coalesce(p_lista, true) then
    if a.lista_guia_en is null or a.lista_para = 'tienda' then return a; end if;
    if a.guia_pegada_en is not null then raise exception 'La guía ya está pegada: ya no se puede deshacer aquí.'; end if;
    if a.estado = 'por_entregar' and exists (select 1 from asignaciones x where x.caja = a.caja and x.estado = 'activa') then
      raise exception 'La caja % ya la ocupa otra clienta: ya no se puede deshacer. Si hace falta, una Dueña u Operación le asigna otra caja.', a.caja;
    end if;
    update asignaciones set estado = 'activa', lista_guia_en = null, lista_guia_por = null where id = a.id returning * into a;
    return a;
  end if;
  if a.lista_guia_en is not null then return a; end if;

  select count(*), coalesce(sum(prendas), 0) into v_ped, v_pren from pedidos where asignacion_id = a.id;
  if v_ped = 0 then raise exception 'Esta caja todavía no tiene pedidos.'; end if;
  select string_agg(live_folio(c.folio), ', ' order by c.folio) into v_falta
    from live_cuentas c
   where c.asignacion_id = a.id and c.estado = 'pagada' and c.pedido_id is not null and c.en_caja_en is null;
  if v_falta is not null then
    raise exception 'Todavía falta pasar a la caja: %. Márcalo con "Ya está en la caja" en el panel del live → Casilleros.', v_falta;
  end if;

  update asignaciones set estado = 'por_entregar', lista_guia_en = now(), lista_guia_por = v_por, lista_para = 'guia'
   where id = a.id returning * into a;
  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('caja', 'lista-guia:' || a.id || ':' || extract(epoch from now())::bigint,
          format('🏷️ %s · listo para generar guía', v_cl),
          format('%s %s en %s %s. Ya salió de la caja %s (quedó libre). Genera la guía, pégala en el paquete y márcala en Cajas → Falta guía.',
                 v_pren, case when v_pren = 1 then 'prenda' else 'prendas' end,
                 v_ped, case when v_ped = 1 then 'pedido' else 'pedidos' end, a.caja),
          'index.html#/salida/' || a.id, 'supervisor')
  on conflict (clave) do nothing;
  return a;
end $$;

-- Guía pegada (Supervisor o Dueña): ahora sobre el pedido que ya salió de su caja
create or replace function public.caja_guia_pegada(p_asignacion uuid, p_entrega text, p_paqueteria text default null, p_guia text default null, p_usuario text default null)
returns public.asignaciones
language plpgsql security definer set search_path = public as $$
declare
  a asignaciones;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
  v_cl text;
  v_pren integer;
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'supervisor')) then
    raise exception 'Solo el Supervisor o una Dueña pueden marcar la guía como pegada.';
  end if;
  select * into a from asignaciones where id = p_asignacion for update;
  if not found or a.estado = 'enviada' then raise exception 'Ese pedido ya se envió o cambió. Revisa de nuevo.'; end if;

  if p_entrega is null then
    update asignaciones set guia_pegada_en = null, guia_pegada_por = null, entrega = null where id = a.id returning * into a;
    return a;
  end if;
  if p_entrega not in ('recoleccion', 'sucursal') then raise exception 'Elige recolección o llevar a sucursal.'; end if;
  if a.lista_guia_en is null then raise exception 'Primero hay que marcar la caja como lista para generar guía.'; end if;
  if a.lista_para = 'tienda' then raise exception 'Este pedido es para recoger en tienda: no lleva guía.'; end if;

  update asignaciones set
    guia_pegada_en = now(), guia_pegada_por = v_por, entrega = p_entrega,
    paqueteria = coalesce(nullif(trim(p_paqueteria), ''), paqueteria),
    guia = coalesce(nullif(trim(p_guia), ''), guia)
  where id = a.id returning * into a;

  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;
  select coalesce(sum(prendas), 0) into v_pren from pedidos where asignacion_id = a.id;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('caja', 'guia-pegada:' || a.id || ':' || extract(epoch from now())::bigint,
          format('📦 %s con guía pegada · %s', v_cl,
                 case when a.entrega = 'recoleccion' then 'listo para recolección' else 'para llevar a sucursal' end),
          concat_ws(' · ', format('%s %s', v_pren, case when v_pren = 1 then 'prenda' else 'prendas' end),
                    nullif(concat_ws(' ', a.paqueteria, a.guia), ''),
                    'La marcó ' || split_part(coalesce(v_por, 'supervisor'), '@', 1)),
          'index.html#/salida/' || a.id, 'duena')
  on conflict (clave) do nothing;
  return a;
end $$;

-- Recoge en tienda: una o varias cajas de la misma clienta (o un pedido que ya estaba por enviar con guía sin pegar)
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
    if not found or a.estado = 'enviada' or (a.estado = 'por_entregar' and a.lista_para = 'tienda') then
      raise exception 'Esa caja ya se entregó o cambió. Revisa de nuevo.';
    end if;
    if v_clienta is null then v_clienta := a.clienta_id;
    elsif a.clienta_id <> v_clienta then raise exception 'Las cajas son de clientas distintas.'; end if;
    if a.guia_pegada_en is not null then raise exception 'Lo de la caja % ya tiene la guía pegada: deshaz esa marca primero.', a.caja; end if;

    select count(*), coalesce(sum(prendas), 0) into n_ped, n_pren from pedidos where asignacion_id = a.id;
    if n_ped = 0 then raise exception 'La caja % todavía no tiene pedidos.', a.caja; end if;
    select string_agg(live_folio(c.folio), ', ' order by c.folio) into v_falta
      from live_cuentas c
     where c.asignacion_id = a.id and c.estado = 'pagada' and c.pedido_id is not null and c.en_caja_en is null;
    if v_falta is not null then
      raise exception 'Todavía falta pasar a la caja %: %. Márcalo con "Ya está en la caja" en el panel del live → Casilleros.', a.caja, v_falta;
    end if;

    update asignaciones
       set estado = 'por_entregar', lista_guia_en = now(), lista_guia_por = v_por, lista_para = 'tienda',
           paqueteria = null, guia = null, recogida_en = null, recogida_por = null
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
          'index.html#/salida/' || p_asignaciones[1], 'duena')
  on conflict (clave) do nothing;
  return jsonb_build_object('cajas', to_jsonb(v_cajas), 'clienta', v_cl, 'clienta_id', v_clienta, 'pedidos', v_ped, 'prendas', v_pren);
end $$;

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

  -- Deshacer: sus prendas regresan a la misma caja, si sigue libre
  select * into a from asignaciones where id = p_asignacion for update;
  if not found then raise exception 'Esa caja ya se entregó o cambió. Revisa de nuevo.'; end if;
  if a.lista_para is distinct from 'tienda' then return a; end if;
  if a.estado = 'enviada' and a.recogida_en is not null then raise exception 'Ese pedido ya se le entregó a la clienta: ya no se puede deshacer.'; end if;
  if a.estado <> 'activa' and exists (select 1 from asignaciones x where x.caja = a.caja and x.estado = 'activa') then
    raise exception 'La caja % ya la ocupa otra clienta: ya no se puede deshacer. Si la clienta ya no pasa por su pedido, una Dueña u Operación le asigna otra caja.', a.caja;
  end if;
  update asignaciones set estado = 'activa', enviada_en = null, enviada_por = null, paqueteria = null, lista_guia_en = null, lista_guia_por = null
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
  if a.lista_para is distinct from 'tienda' then raise exception 'Este pedido no está marcado para recoger en tienda.'; end if;
  if a.recogida_en is not null then raise exception 'Ese pedido ya se había entregado a la clienta.'; end if;
  update asignaciones
     set estado = 'enviada', enviada_en = now(), enviada_por = v_por, paqueteria = 'Recoge en tienda',
         recogida_en = now(), recogida_por = v_por, notas_envio = coalesce(notas_envio, 'Entregada a la clienta en tienda')
   where id = a.id returning * into a;
  return a;
end $$;

-- La burbuja de ayuda: lo que ya salió de su caja y falta entregar
do $$
declare def text;
begin
  select pg_get_functiondef('public.ayuda_consulta(text, text, date, date)'::regprocedure) into def;
  if position('e.estado = ''por_entregar''' in def) = 0 then
    def := replace(def,
      '(select count(*) from asignaciones e where e.clienta_id = h.id and e.estado = ''enviada'' and e.lista_para = ''tienda'' and e.recogida_en is null)',
      '(select count(*) from asignaciones e where e.clienta_id = h.id and e.estado = ''por_entregar'' and e.lista_para = ''tienda'')');
    def := replace(def,
      '''por_recoger_en_tienda'', nullif(',
      '''por_enviar_con_guia'', nullif((select count(*) from asignaciones e where e.clienta_id = h.id and e.estado = ''por_entregar'' and e.lista_para is distinct from ''tienda''), 0),
             ''por_recoger_en_tienda'', nullif(');
    if position('e.estado = ''por_entregar''' in def) = 0 then raise exception 'No se encontró dónde cambiar ayuda_consulta.'; end if;
    execute def;
  end if;
end $$;
