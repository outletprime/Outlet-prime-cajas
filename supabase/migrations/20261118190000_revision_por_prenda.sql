-- =====================================================================
-- Revisión física prenda por prenda.
--
-- Después de cerrar el live, se abre cada casillero en el panel y cada prenda se marca como
-- "Encontrada" o "No encontrada". El pedido solo se puede confirmar (y cobrar) cuando todas sus
-- prendas están encontradas. Si falta alguna, queda como "pedido incompleto" con sus claves.
-- =====================================================================

alter table public.live_apartados add column if not exists revision text;
alter table public.live_apartados add column if not exists revision_en timestamptz;
alter table public.live_apartados add column if not exists revision_por text;
alter table public.live_apartados drop constraint if exists live_apartados_revision_check;
alter table public.live_apartados add constraint live_apartados_revision_check
  check (revision is null or revision in ('encontrada', 'no_encontrada'));
comment on column public.live_apartados.revision is 'Revisión física después del live: encontrada / no_encontrada (vacío = falta revisar)';

-- El tablero de casilleros trae el avance de la revisión (columnas nuevas al final)
create or replace view public.live_tablero with (security_invoker = true) as
 SELECT c.id,
    c.folio,
    c.live_id,
    c.clienta_id,
    c.casillero,
    c.estado,
    c.total,
    c.piezas,
    c.monto_pagado,
    c.clabe,
    c.proveedor,
    c.proveedor_ref,
    c.cobro_enviado_en,
    c.recordatorio_en,
    c.recordado_en,
    c.limite_pago,
    c.liberar_en,
    c.vencida_en,
    c.pagada_en,
    c.pagada_por,
    c.caja,
    c.asignacion_id,
    c.pedido_id,
    c.en_caja_en,
    c.casillero_liberado_en,
    c.casillero_liberado_por,
    c.creada_en,
    live_folio(c.folio) AS folio_txt,
    TRIM(BOTH FROM cl.nombre || COALESCE(' '::text || cl.apellidos, ''::text)) AS clienta,
    cl.telefono,
    ( SELECT COALESCE(array_agg(a.prenda ORDER BY a.prenda), '{}'::integer[]) AS "coalesce"
           FROM live_apartados a
          WHERE a.cuenta_id = c.id AND (a.estado = ANY (ARRAY['apartada'::text, 'pagada'::text])) AND a.prenda IS NOT NULL) AS prendas,
    l.estado AS live_estado,
    l.iniciado_en AS live_inicio,
    l.tipo,
    live_unir(live_etiquetas(c.id, ARRAY['apartada'::text, 'pagada'::text])) AS piezas_txt,
    r.encontradas AS rev_encontradas,
    r.no_encontradas AS rev_no_encontradas,
    r.pendientes AS rev_pendientes,
    r.faltantes AS rev_faltantes
   FROM live_cuentas c
     JOIN clientas cl ON cl.id = c.clienta_id
     JOIN lives l ON l.id = c.live_id
     CROSS JOIN LATERAL ( SELECT count(*) FILTER (WHERE a.revision = 'encontrada')::integer AS encontradas,
            count(*) FILTER (WHERE a.revision = 'no_encontrada')::integer AS no_encontradas,
            count(*) FILTER (WHERE a.revision IS NULL)::integer AS pendientes,
            live_unir(COALESCE(array_agg(COALESCE(live_num(a.prenda), '#' || a.prime_prenda::text) ORDER BY a.prenda)
                      FILTER (WHERE a.revision = 'no_encontrada'), '{}'::text[])) AS faltantes
           FROM live_apartados a
          WHERE a.cuenta_id = c.id AND a.estado = 'apartada') r;

-- Detalle de un pedido para revisarlo pieza por pieza
create or replace function public.live_pedido_detalle(p_cuenta uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c live_cuentas;
  v_live lives;
begin
  if not puede_ver() then raise exception 'Tu nivel de acceso no permite ver esto.'; end if;
  select * into c from live_cuentas where id = p_cuenta;
  if not found then raise exception 'No existe esa cuenta.'; end if;
  select * into v_live from lives where id = c.live_id;
  return jsonb_build_object(
    'id', c.id, 'folio', live_folio(c.folio), 'casillero', c.casillero, 'estado', c.estado,
    'clienta', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = c.clienta_id),
    'revisable', c.estado = 'abierta' and v_live.estado = 'cerrado',
    'piezas', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', a.id, 'clave', coalesce(live_num(a.prenda), '#' || pp.num), 'estado', a.estado,
                  'revision', a.revision, 'revision_por', a.revision_por, 'revision_en', a.revision_en)
                  order by a.prenda nulls last, pp.num), '[]'::jsonb)
                 from live_apartados a left join prime_prendas pp on pp.id = a.prime_prenda
                where a.cuenta_id = c.id and a.estado in ('apartada', 'pagada')));
end $$;

-- Marcar una prenda: 'encontrada', 'no_encontrada' o null (volver a "por revisar")
create or replace function public.live_revisar_prenda(p_apartado uuid, p_revision text default null, p_usuario text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a live_apartados;
  c live_cuentas;
  v_live lives;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
begin
  if not puede_confirmar_pedido() then raise exception 'Tu nivel de acceso no permite revisar pedidos.'; end if;
  if p_revision is not null and p_revision not in ('encontrada', 'no_encontrada') then raise exception 'Revisión inválida.'; end if;
  select * into a from live_apartados where id = p_apartado for update;
  if not found or a.estado <> 'apartada' then raise exception 'Esa prenda ya no está en el pedido.'; end if;
  select * into c from live_cuentas where id = a.cuenta_id;
  select * into v_live from lives where id = c.live_id;
  if c.estado <> 'abierta' or v_live.estado <> 'cerrado' then
    raise exception 'Este pedido no está en revisión (el live sigue abierto o ya se confirmó).';
  end if;
  update live_apartados set
    revision = p_revision,
    revision_en = case when p_revision is null then null else now() end,
    revision_por = case when p_revision is null then null else v_por end,
    -- encontrada en su casillero = acomodada
    acomodada_en = case when p_revision = 'encontrada' then coalesce(acomodada_en, now()) else acomodada_en end,
    acomodada_por = case when p_revision = 'encontrada' then coalesce(acomodada_por, v_por) else acomodada_por end
  where id = a.id;
  return live_pedido_detalle(c.id);
end $$;

-- Confirmar: todas las prendas del pedido deben estar marcadas como encontradas
create or replace function public.live_pedido_confirmar(p_cuenta uuid, p_usuario text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c live_cuentas;
  v_live lives;
  v_no text;
  v_pend text;
  v_nombre text;
begin
  if not puede_confirmar_pedido() then raise exception 'Tu nivel de acceso no permite confirmar pedidos.'; end if;
  select * into c from live_cuentas where id = p_cuenta for update;
  if not found then raise exception 'No existe esa cuenta.'; end if;
  select * into v_live from lives where id = c.live_id;
  if c.estado <> 'abierta' then raise exception 'Ese pedido ya estaba confirmado.'; end if;
  if v_live.estado = 'activo' then raise exception 'El live sigue en curso: primero hay que cerrarlo.'; end if;

  perform live_recalcular(c.id);
  select * into c from live_cuentas where id = p_cuenta;
  if c.piezas = 0 then
    update live_cuentas set estado = 'cancelada', casillero_liberado_en = now() where id = c.id;
    return jsonb_build_object('cancelada', true);
  end if;

  select live_unir(array_agg(coalesce(live_num(a.prenda), '#' || pp.num) order by a.prenda) filter (where a.revision = 'no_encontrada')),
         live_unir(array_agg(coalesce(live_num(a.prenda), '#' || pp.num) order by a.prenda) filter (where a.revision is null))
    into v_no, v_pend
    from live_apartados a left join prime_prendas pp on pp.id = a.prime_prenda
   where a.cuenta_id = c.id and a.estado = 'apartada';
  if coalesce(v_no, '') <> '' then
    raise exception 'Pedido incompleto: no se encontraron %. Márcalas como encontradas cuando aparezcan o quítalas del pedido.', v_no;
  end if;
  if coalesce(v_pend, '') <> '' then
    raise exception 'Falta revisar: %. Marca cada prenda como encontrada o no encontrada.', v_pend;
  end if;

  update live_cuentas set
    estado = 'por_pagar',
    clabe = coalesce(clabe, (select nullif(trim(clabe), '') from live_config limit 1)),
    revisada_en = now(),
    revisada_por = coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()))
  where id = c.id
  returning * into c;

  select trim(nombre || coalesce(' ' || apellidos, '')) into v_nombre from clientas where id = c.clienta_id;
  perform avisos_encolar('cobro', 'cobro:' || c.id,
    format('🧾 Pedido completo · %s', v_nombre),
    format('Casillero %s · %s %s · %s. Ya se puede mandar su nota de cobro.',
           coalesce(c.casillero, 'sin casillero'), c.piezas, case when c.piezas = 1 then 'prenda' else 'prendas' end, live_dinero(c.total)),
    'live.html#casilleros');
  return jsonb_build_object('confirmada', true, 'folio', live_folio(c.folio), 'piezas', c.piezas, 'total', c.total);
end $$;

revoke all on function public.live_pedido_detalle(uuid), public.live_revisar_prenda(uuid, text, text) from public, anon;
grant execute on function public.live_pedido_detalle(uuid), public.live_revisar_prenda(uuid, text, text) to authenticated, service_role;
