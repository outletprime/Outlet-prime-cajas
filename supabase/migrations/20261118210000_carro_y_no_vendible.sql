-- =====================================================================
-- 1. Sin casilleros libres → al CARRO (con el nombre de la clienta en el aviso).
-- 2. Revisión física: tercera opción "No vendible" (dañada o defectuosa).
-- 3. Cerrar un pedido sin las prendas no encontradas o no vendibles: se quitan del pedido,
--    se ajusta el total y la nota de cobro sale solo con lo que sí se va a cobrar.
--      - No encontrada → se le quita a la clienta y la prenda queda disponible (sin pasarla a
--        quien estaba en espera, porque físicamente no aparece).
--      - No vendible   → se le quita a la clienta y la prenda queda dada de baja.
-- =====================================================================

-- 1. El carro: un lugar más, que nunca se asigna como casillero libre y lo pueden compartir varias clientas
insert into public.casilleros (id, orden, activo) values ('CARRO', 9999, false)
on conflict (id) do nothing;

create or replace function public.live_apartado_casillero() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  c live_cuentas;
  v_max integer;
  v_cas text;
begin
  if new.estado not in ('apartada', 'pagada') or new.cuenta_id is null then return new; end if;
  if tg_op = 'UPDATE' and new.cuenta_id is not distinct from old.cuenta_id and new.casillero is not null then return new; end if;

  perform pg_advisory_xact_lock(hashtext('casilleros-de-' || new.cuenta_id));
  select * into c from live_cuentas where id = new.cuenta_id;
  v_max := coalesce((select prendas_por_casillero from live_config limit 1), 10);

  -- 1. Uno de sus casilleros que todavía tenga lugar
  select t.k into v_cas
    from unnest(live_casilleros_de(c.id)) with ordinality as t(k, n)
   where t.k <> 'CARRO'
     and (select count(*) from live_apartados x
           where x.cuenta_id = c.id and x.casillero = t.k and x.estado in ('apartada', 'pagada') and x.id <> new.id) < v_max
   order by n limit 1;

  -- 2. El siguiente casillero libre
  if v_cas is null then
    perform pg_advisory_xact_lock(hashtext('casilleros-libres'));
    select k.id into v_cas from casilleros k
     where k.activo and not live_casillero_ocupado(k.id)
     order by k.orden limit 1;
    if v_cas is not null and c.casillero is null then
      update live_cuentas set casillero = v_cas where id = c.id;
    end if;
  end if;

  -- 3. Ya no hay casilleros libres: al carro
  new.casillero := coalesce(v_cas, 'CARRO');
  return new;
end $$;

do $$
declare def text;
begin
  select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'avisos_acomodo';
  if position('va en el carro' in def) = 0 then
    if position('format(''%s · llévala a su casillero'', v_cl)' in def) = 0 then
      raise exception 'No se encontró el texto del aviso de acomodo.';
    end if;
    execute replace(def, 'format(''%s · llévala a su casillero'', v_cl)',
      'format(case when a.casillero = ''CARRO'' then ''%s · no hay casilleros libres: va en el carro'' else ''%s · llévala a su casillero'' end, v_cl)');
  end if;
end $$;

-- 2. No vendible
alter table public.live_apartados drop constraint if exists live_apartados_revision_check;
alter table public.live_apartados add constraint live_apartados_revision_check
  check (revision is null or revision in ('encontrada', 'no_encontrada', 'no_vendible'));

create or replace function public.live_revisar_prenda(p_apartado uuid, p_revision text default null, p_usuario text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a live_apartados;
  c live_cuentas;
  v_live lives;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
begin
  if not puede_confirmar_pedido() then raise exception 'Tu nivel de acceso no permite revisar pedidos.'; end if;
  if p_revision is not null and p_revision not in ('encontrada', 'no_encontrada', 'no_vendible') then raise exception 'Revisión inválida.'; end if;
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
    acomodada_en = case when p_revision = 'encontrada' then coalesce(acomodada_en, now()) else acomodada_en end,
    acomodada_por = case when p_revision = 'encontrada' then coalesce(acomodada_por, v_por) else acomodada_por end
  where id = a.id;
  return live_pedido_detalle(c.id);
end $$;

-- El detalle trae el precio de cada prenda (para mostrar el total a cobrar antes de confirmar)
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
    'id', c.id, 'folio', live_folio(c.folio), 'casillero', c.casillero, 'estado', c.estado, 'total', c.total,
    'casilleros', live_unir(live_casilleros_de(c.id)),
    'clienta', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = c.clienta_id),
    'revisable', c.estado = 'abierta' and v_live.estado = 'cerrado',
    'piezas', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', a.id, 'clave', coalesce(live_num(a.prenda), '#' || pp.num), 'estado', a.estado,
                  'casillero', coalesce(a.casillero, c.casillero), 'precio', a.precio,
                  'revision', a.revision, 'revision_por', a.revision_por, 'revision_en', a.revision_en)
                  order by coalesce(a.casillero, c.casillero), a.prenda nulls last, pp.num), '[]'::jsonb)
                 from live_apartados a left join prime_prendas pp on pp.id = a.prime_prenda
                where a.cuenta_id = c.id and a.estado in ('apartada', 'pagada')));
end $$;

-- 3. Confirmar el pedido; con p_quitar_faltantes = true se cierra sin las no encontradas / no vendibles
drop function if exists public.live_pedido_confirmar(uuid, text);
create or replace function public.live_pedido_confirmar(p_cuenta uuid, p_usuario text default null, p_quitar_faltantes boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c live_cuentas;
  v_live lives;
  v_no text;
  v_nv text;
  v_pend text;
  v_nombre text;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
  r record;
  v_quitadas text[] := '{}';
begin
  if not puede_confirmar_pedido() then raise exception 'Tu nivel de acceso no permite confirmar pedidos.'; end if;
  select * into c from live_cuentas where id = p_cuenta for update;
  if not found then raise exception 'No existe esa cuenta.'; end if;
  select * into v_live from lives where id = c.live_id;
  if c.estado <> 'abierta' then raise exception 'Ese pedido ya estaba confirmado.'; end if;
  if v_live.estado = 'activo' then raise exception 'El live sigue en curso: primero hay que cerrarlo.'; end if;

  select live_unir(array_agg(coalesce(live_num(a.prenda), '#' || pp.num) order by a.prenda) filter (where a.revision = 'no_encontrada')),
         live_unir(array_agg(coalesce(live_num(a.prenda), '#' || pp.num) order by a.prenda) filter (where a.revision = 'no_vendible')),
         live_unir(array_agg(coalesce(live_num(a.prenda), '#' || pp.num) order by a.prenda) filter (where a.revision is null))
    into v_no, v_nv, v_pend
    from live_apartados a left join prime_prendas pp on pp.id = a.prime_prenda
   where a.cuenta_id = c.id and a.estado = 'apartada';
  if coalesce(v_pend, '') <> '' then
    raise exception 'Falta revisar: %. Marca cada prenda como encontrada, no encontrada o no vendible.', v_pend;
  end if;
  if (coalesce(v_no, '') <> '' or coalesce(v_nv, '') <> '') and not coalesce(p_quitar_faltantes, false) then
    raise exception 'Pedido incompleto: %. Para cobrar sin ellas, cierra el pedido sin las faltantes.',
      concat_ws('; ', case when coalesce(v_no, '') <> '' then 'no se encontraron ' || v_no end,
                      case when coalesce(v_nv, '') <> '' then 'no vendibles ' || v_nv end);
  end if;

  -- Se quitan del pedido las no encontradas y las no vendibles
  for r in select a.id, a.prenda, a.revision from live_apartados a
            where a.cuenta_id = c.id and a.estado = 'apartada' and a.revision in ('no_encontrada', 'no_vendible')
            for update loop
    update live_apartados set estado = 'cancelada', actualizado_en = now() where id = r.id;
    if r.prenda is not null then
      update prendas set estado = case when r.revision = 'no_vendible' then 'baja' else 'disponible' end,
                         descripcion = coalesce(descripcion || ' · ', '') ||
                           case when r.revision = 'no_vendible' then 'No vendible (revisión del ' else 'No se encontró (revisión del ' end
                           || to_char(now() at time zone 'America/Mexico_City', 'DD/MM') || ')',
                         actualizada_en = now()
       where numero = r.prenda;
      -- Quien la esperaba no la recibe: físicamente no está o no se puede vender
      update live_apartados set estado = 'cancelada', actualizado_en = now()
       where prenda = r.prenda and estado = 'espera';
      v_quitadas := v_quitadas || live_num(r.prenda);
    end if;
  end loop;

  perform live_recalcular(c.id);
  select * into c from live_cuentas where id = p_cuenta;
  if c.piezas = 0 then
    update live_cuentas set estado = 'cancelada', casillero_liberado_en = now(), revisada_en = now(), revisada_por = v_por where id = c.id;
    return jsonb_build_object('cancelada', true, 'quitadas', to_jsonb(v_quitadas));
  end if;

  update live_cuentas set
    estado = 'por_pagar',
    clabe = coalesce(clabe, (select nullif(trim(clabe), '') from live_config limit 1)),
    revisada_en = now(),
    revisada_por = v_por
  where id = c.id
  returning * into c;

  select trim(nombre || coalesce(' ' || apellidos, '')) into v_nombre from clientas where id = c.clienta_id;
  perform avisos_encolar('cobro', 'cobro:' || c.id,
    format('🧾 Pedido %s · %s', case when cardinality(v_quitadas) > 0 then 'cerrado' else 'completo' end, v_nombre),
    format('%s · %s %s · %s.%s Ya se puede mandar su nota de cobro.',
           coalesce(live_casilleros_frase(c.id), 'sin casillero'), c.piezas, case when c.piezas = 1 then 'prenda' else 'prendas' end,
           live_dinero(c.total),
           case when cardinality(v_quitadas) > 0 then ' Sin ' || live_unir(v_quitadas) || '.' else '' end),
    'live.html#casilleros');
  return jsonb_build_object('confirmada', true, 'folio', live_folio(c.folio), 'piezas', c.piezas, 'total', c.total,
                            'quitadas', to_jsonb(v_quitadas));
end $$;

revoke all on function public.live_pedido_confirmar(uuid, text, boolean) from public, anon;
grant execute on function public.live_pedido_confirmar(uuid, text, boolean) to authenticated, service_role;

-- Tablero: también cuenta las no vendibles (columnas nuevas al final)
create or replace view public.live_tablero with (security_invoker = true) as
 SELECT c.id, c.folio, c.live_id, c.clienta_id, c.casillero, c.estado, c.total, c.piezas, c.monto_pagado, c.clabe,
    c.proveedor, c.proveedor_ref, c.cobro_enviado_en, c.recordatorio_en, c.recordado_en, c.limite_pago, c.liberar_en,
    c.vencida_en, c.pagada_en, c.pagada_por, c.caja, c.asignacion_id, c.pedido_id, c.en_caja_en,
    c.casillero_liberado_en, c.casillero_liberado_por, c.creada_en,
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
    r.faltantes AS rev_faltantes,
    live_unir(live_casilleros_de(c.id)) AS casilleros_txt,
    r.no_vendibles AS rev_no_vendibles,
    r.no_vendibles_txt AS rev_no_vendibles_txt
   FROM live_cuentas c
     JOIN clientas cl ON cl.id = c.clienta_id
     JOIN lives l ON l.id = c.live_id
     CROSS JOIN LATERAL ( SELECT count(*) FILTER (WHERE a.revision = 'encontrada')::integer AS encontradas,
            count(*) FILTER (WHERE a.revision = 'no_encontrada')::integer AS no_encontradas,
            count(*) FILTER (WHERE a.revision IS NULL)::integer AS pendientes,
            live_unir(COALESCE(array_agg(COALESCE(live_num(a.prenda), '#' || a.prime_prenda::text) ORDER BY a.prenda)
                      FILTER (WHERE a.revision = 'no_encontrada'), '{}'::text[])) AS faltantes,
            count(*) FILTER (WHERE a.revision = 'no_vendible')::integer AS no_vendibles,
            live_unir(COALESCE(array_agg(COALESCE(live_num(a.prenda), '#' || a.prime_prenda::text) ORDER BY a.prenda)
                      FILTER (WHERE a.revision = 'no_vendible'), '{}'::text[])) AS no_vendibles_txt
           FROM live_apartados a
          WHERE a.cuenta_id = c.id AND a.estado = 'apartada') r;
