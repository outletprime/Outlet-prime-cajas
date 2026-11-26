-- Flujo de la guía con autorización:
-- Operación marca "lista para generar guía" → el Supervisor pesa, mide y cotiza → una Dueña elige y compra
-- → el Supervisor imprime ("guía impresa") → Operación la pega ("guía pegada").

alter table public.asignaciones
  add column if not exists guia_impresa_en timestamptz,
  add column if not exists guia_impresa_por text;

-- El peso y las medidas siempre se escriben a mano: ya no hay estimado
drop function if exists public.envio_sugerido(uuid);

-- Guía impresa (Supervisor o Dueña): avisa a Operación para que la pegue
create or replace function public.caja_guia_impresa(p_asignacion uuid, p_impresa boolean default true, p_paqueteria text default null, p_guia text default null, p_usuario text default null)
returns public.asignaciones language plpgsql security definer set search_path = public as $$
declare
  a asignaciones;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
  v_cl text;
  v_pren integer;
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'supervisor')) then
    raise exception 'Solo el Supervisor o una Dueña pueden marcar la guía como impresa.';
  end if;
  select * into a from asignaciones where id = p_asignacion for update;
  if not found or a.estado = 'enviada' then raise exception 'Ese pedido ya se envió o cambió. Revisa de nuevo.'; end if;

  if not coalesce(p_impresa, true) then
    if a.guia_pegada_en is not null then raise exception 'La guía ya está pegada: primero deshaz la guía pegada.'; end if;
    update asignaciones set guia_impresa_en = null, guia_impresa_por = null where id = a.id returning * into a;
    return a;
  end if;
  if a.lista_guia_en is null then raise exception 'Primero hay que marcar la caja como lista para generar guía.'; end if;
  if a.lista_para = 'tienda' then raise exception 'Este pedido es para recoger en tienda: no lleva guía.'; end if;
  if a.guia_impresa_en is not null then return a; end if;

  update asignaciones set
    guia_impresa_en = now(), guia_impresa_por = v_por,
    paqueteria = coalesce(nullif(trim(p_paqueteria), ''), paqueteria),
    guia = coalesce(nullif(trim(p_guia), ''), guia)
  where id = a.id returning * into a;

  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;
  select coalesce(sum(prendas), 0) into v_pren from pedidos where asignacion_id = a.id;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('caja', 'guia-impresa:' || a.id || ':' || extract(epoch from now())::bigint,
          format('🖨️ Guía de %s lista para pegar', v_cl),
          concat_ws(' · ', format('%s %s', v_pren, case when v_pren = 1 then 'prenda' else 'prendas' end),
                    nullif(concat_ws(' ', a.paqueteria, a.guia), ''),
                    'Pégala en su paquete y márcala en Cajas → Falta guía.'),
          'index.html#/salida/' || a.id, 'operacion')
  on conflict (clave) do nothing;
  return a;
end $$;
revoke all on function public.caja_guia_impresa(uuid, boolean, text, text, text) from public, anon;
grant execute on function public.caja_guia_impresa(uuid, boolean, text, text, text) to authenticated;

-- Guía pegada: ahora también la marca Operación (cuando la guía ya está impresa). Avisa a Dueñas y a Operación.
create or replace function public.caja_guia_pegada(p_asignacion uuid, p_entrega text, p_paqueteria text default null, p_guia text default null, p_usuario text default null)
returns public.asignaciones language plpgsql security definer set search_path = public as $$
declare
  a asignaciones;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
  v_rol text := (select rol from equipo where usuario_id = auth.uid());
  v_cl text;
  v_pren integer;
  v_cuando text := extract(epoch from now())::bigint::text;
begin
  if v_rol is null or v_rol not in ('duena', 'supervisor', 'operacion') then
    raise exception 'Tu nivel de acceso no permite marcar la guía como pegada.';
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
  if v_rol = 'operacion' and a.guia_impresa_en is null then
    raise exception 'Todavía no está impresa la guía. Falta que el Supervisor la imprima.';
  end if;

  update asignaciones set
    guia_pegada_en = now(), guia_pegada_por = v_por, entrega = p_entrega,
    paqueteria = coalesce(nullif(trim(p_paqueteria), ''), paqueteria),
    guia = coalesce(nullif(trim(p_guia), ''), guia)
  where id = a.id returning * into a;

  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;
  select coalesce(sum(prendas), 0) into v_pren from pedidos where asignacion_id = a.id;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  select 'caja', 'guia-pegada:' || a.id || ':' || v_cuando || case when r = 'duena' then '' else ':' || r end,
         format('📦 %s con guía pegada · %s', v_cl,
                case when a.entrega = 'recoleccion' then 'listo para recolección' else 'listo para llevar a paquetería' end),
         concat_ws(' · ', format('%s %s', v_pren, case when v_pren = 1 then 'prenda' else 'prendas' end),
                   nullif(concat_ws(' ', a.paqueteria, a.guia), ''),
                   'La marcó ' || split_part(coalesce(v_por, v_rol), '@', 1)),
         'index.html#/salida/' || a.id, r
    from unnest(array['duena', 'operacion']) r
  on conflict (clave) do nothing;
  return a;
end $$;

-- Lista para generar guía: el aviso al Supervisor ya dice qué sigue; al deshacer se limpia lo de la guía
create or replace function public.caja_lista_para_guia(p_asignacion uuid, p_lista boolean default true, p_usuario text default null)
returns public.asignaciones language plpgsql security definer set search_path = public as $$
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
    if exists (select 1 from envios_skydrop e where e.asignacion_id = a.id and e.estado in ('comprando', 'comprada')) then
      raise exception 'Este pedido ya tiene una guía comprada en Skydrop. Una Dueña debe cancelarla antes de deshacer.';
    end if;
    if a.estado = 'por_entregar' and exists (select 1 from asignaciones x where x.caja = a.caja and x.estado = 'activa') then
      raise exception 'La caja % ya la ocupa otra clienta: ya no se puede deshacer. Si hace falta, una Dueña u Operación le asigna otra caja.', a.caja;
    end if;
    delete from envios_skydrop where asignacion_id = a.id and estado = 'cotizada';
    update asignaciones set estado = 'activa', lista_guia_en = null, lista_guia_por = null, guia_impresa_en = null, guia_impresa_por = null
     where id = a.id returning * into a;
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
          format('%s %s en %s %s. Ya salió de la caja %s (quedó libre). Falta su guía: ábrelo en Cajas → Falta guía.',
                 v_pren, case when v_pren = 1 then 'prenda' else 'prendas' end,
                 v_ped, case when v_ped = 1 then 'pedido' else 'pedidos' end, a.caja),
          'index.html#/salida/' || a.id, 'supervisor')
  on conflict (clave) do nothing;
  return a;
end $$;
