-- Consultas de la burbuja de ayuda: además de explicar cómo se usa el panel, el asistente puede
-- contestar preguntas del equipo sobre los datos ("¿cuántas prendas tiene Bere en su caja?").
--
-- La función `ayuda` llama a ayuda_consulta() con la sesión de quien pregunta, y AQUÍ se decide
-- qué puede ver cada nivel (igual que en el panel):
--   Dueña y Supervisor  → clientas, cajas, prendas, pedidos del live y ventas.
--   Operación           → lo mismo, menos ventas.
--   Operación live      → de quién es una caja o una prenda y cuántas prendas tiene, sin teléfonos ni dinero.
--   Presentadora y Resurtido → nada.
-- Solo CONSULTA: no cambia ningún dato.

-- "Pérez Ñuñez" → "perez nunez" (para buscar sin importar acentos ni mayúsculas)
create or replace function public.ayuda_norm(p text) returns text
language sql immutable set search_path = public as $$
  select trim(regexp_replace(lower(translate(coalesce(p, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g'))
$$;

create or replace function public.ayuda_consulta(
  p_que text, p_texto text default null, p_desde date default null, p_hasta date default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_rol text := (select rol from equipo where usuario_id = auth.uid());
  v_todo boolean;      -- ve teléfonos y dinero
  v_tz text := coalesce((select zona_horaria from live_config limit 1), 'America/Mexico_City');
  v_dias integer := coalesce((select dias_caja from live_config limit 1), 20);
  v_hoy date;
  v_q text := ayuda_norm(p_texto);
  v_pal text[];
  v_num integer;
  v_caja text;
  v_r jsonb;
  v_n integer;
begin
  if v_rol is null or v_rol not in ('duena', 'supervisor', 'operacion', 'live') then
    return jsonb_build_object('sin_permiso', true, 'motivo', 'Su nivel de acceso no permite consultar clientas, cajas ni ventas.');
  end if;
  v_todo := v_rol in ('duena', 'supervisor', 'operacion');
  v_hoy := (now() at time zone v_tz)::date;

  -- ------------------------------------------------------------------
  -- Clienta: por nombre, apellido, usuario de TikTok o teléfono
  -- ------------------------------------------------------------------
  if p_que = 'clienta' then
    if v_q = '' then return jsonb_build_object('error', 'Falta el nombre de la clienta.'); end if;
    v_pal := string_to_array(v_q, ' ');
    with base as (
      select cl.*, trim(cl.nombre || coalesce(' ' || cl.apellidos, '')) as completo,
             ayuda_norm(concat_ws(' ', cl.nombre, cl.apellidos, cl.tiktok,
               (select string_agg(r.usuario, ' ') from clientas_redes r where r.clienta_id = cl.id),
               case when v_todo then cl.telefono end)) as buscable
        from clientas cl
    ), halladas as (
      select b.*, (ayuda_norm(b.completo) = v_q) as exacta
        from base b
       where not exists (select 1 from unnest(v_pal) w where b.buscable not like '%' || w || '%')
    )
    select count(*)::integer,
           coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'clienta', h.completo,
             'tiktok', nullif(trim(coalesce(h.tiktok, '')), ''),
             'telefono', case when v_todo then nullif(h.telefono, '') end,
             'caja', a.caja,
             'en_caja', case when a.id is not null then jsonb_strip_nulls(jsonb_build_object(
                 'prendas', coalesce(pe.prendas, 0),
                 'capacidad', k.capacidad,
                 'pedidos', coalesce(pe.pedidos, 0),
                 'total', case when v_todo then coalesce(pe.total, 0) end,
                 'dias_en_caja', (v_hoy - (a.asignada_en at time zone v_tz)::date),
                 'vencida', (v_hoy - (a.asignada_en at time zone v_tz)::date) >= v_dias,
                 'pedidos_sin_video', coalesce(pe.sin_video, 0))) end,
             'sin_caja', case when a.id is null then true end,
             'cajas_enviadas', nullif((select count(*) from asignaciones e where e.clienta_id = h.id and e.estado = 'enviada'), 0),
             'ultimo_envio', (select max(e.enviada_en) from asignaciones e where e.clienta_id = h.id and e.estado = 'enviada'),
             'pedidos_del_live_sin_pagar', (
               select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                        'folio', live_folio(c.folio),
                        'estado', case c.estado when 'abierta' then case when l.estado = 'activo' then 'live en curso' else 'en revisión' end
                                                when 'por_pagar' then 'por pagar' else 'pago incompleto' end,
                        'prendas', c.piezas,
                        'claves', live_unir(live_etiquetas(c.id, array['apartada', 'pagada'])),
                        'casilleros', nullif(live_unir(live_casilleros_de(c.id)), ''),
                        'total', case when v_todo then c.total end,
                        'pagado', case when v_todo then c.monto_pagado end,
                        'limite_de_pago', c.limite_pago)) order by c.folio)
                 from live_cuentas c join lives l on l.id = c.live_id
                where c.clienta_id = h.id and c.estado in ('abierta', 'por_pagar', 'pago_incompleto') and c.piezas > 0)
           )) order by h.exacta desc, h.completo) filter (where h.rn <= 6), '[]'::jsonb)
      into v_n, v_r
      from (select x.*, row_number() over (order by x.exacta desc, x.completo) as rn from halladas x) h
      left join asignaciones a on a.clienta_id = h.id and a.estado = 'activa'
      left join cajas k on k.id = a.caja
      left join lateral (select sum(p.prendas)::integer as prendas, count(*)::integer as pedidos, sum(p.total) as total,
                                (count(*) filter (where p.video is null))::integer as sin_video
                           from pedidos p where p.asignacion_id = a.id) pe on true;
    return jsonb_build_object('encontradas', v_n, 'clientas', v_r,
      'nota', case when v_n = 0 then 'No hay ninguna clienta con ese nombre.'
                   when v_n > 6 then 'Hay más de 6 con ese nombre: se muestran las primeras 6. Pide un apellido para afinar.' end);

  -- ------------------------------------------------------------------
  -- Caja de resguardo: quién la tiene y qué hay adentro
  -- ------------------------------------------------------------------
  elsif p_que = 'caja' then
    select k.id into v_caja from cajas k where upper(replace(k.id, ' ', '')) = upper(regexp_replace(coalesce(p_texto, ''), '[^A-Za-z0-9]', '', 'g'));
    if v_caja is null then return jsonb_build_object('error', format('No existe la caja "%s".', coalesce(p_texto, ''))); end if;
    select jsonb_strip_nulls(jsonb_build_object(
             'caja', k.id, 'capacidad', k.capacidad, 'libre', a.id is null,
             'clienta', trim(cl.nombre || coalesce(' ' || cl.apellidos, '')),
             'telefono', case when v_todo then nullif(cl.telefono, '') end,
             'prendas', case when a.id is not null then coalesce(pe.prendas, 0) end,
             'pedidos', case when a.id is not null then coalesce(pe.pedidos, 0) end,
             'total', case when v_todo and a.id is not null then coalesce(pe.total, 0) end,
             'asignada_el', a.asignada_en,
             'dias_en_caja', case when a.id is not null then (v_hoy - (a.asignada_en at time zone v_tz)::date) end,
             'vencida', case when a.id is not null then (v_hoy - (a.asignada_en at time zone v_tz)::date) >= v_dias end,
             'pedidos_sin_video', case when a.id is not null then coalesce(pe.sin_video, 0) end))
      into v_r
      from cajas k
      left join asignaciones a on a.caja = k.id and a.estado = 'activa'
      left join clientas cl on cl.id = a.clienta_id
      left join lateral (select sum(p.prendas)::integer as prendas, count(*)::integer as pedidos, sum(p.total) as total,
                                (count(*) filter (where p.video is null))::integer as sin_video
                           from pedidos p where p.asignacion_id = a.id) pe on true
     where k.id = v_caja;
    return v_r;

  -- ------------------------------------------------------------------
  -- Prenda por su clave (AB23): en qué estado está y de quién es
  -- ------------------------------------------------------------------
  elsif p_que = 'prenda' then
    v_num := clave_a_num(p_texto);
    if v_num is null or not exists (select 1 from prendas where numero = v_num) then
      return jsonb_build_object('error', format('No existe una prenda con la clave "%s".', coalesce(p_texto, '')));
    end if;
    select jsonb_strip_nulls(jsonb_build_object(
             'clave', live_num(p.numero),
             'estado', p.estado,
             'precio', case when v_todo then p.precio end,
             'clienta', trim(cl.nombre || coalesce(' ' || cl.apellidos, '')),
             'casillero', case when c.casillero_liberado_en is null then coalesce(a.casillero, c.casillero) end,
             'folio', live_folio(c.folio),
             'pedido', case c.estado when 'abierta' then 'sin cobrar todavía' when 'por_pagar' then 'por pagar'
                                     when 'pago_incompleto' then 'pago incompleto' when 'pagada' then 'pagado' end,
             'caja', c.caja,
             'ya_en_caja', case when c.estado = 'pagada' then c.en_caja_en is not null end,
             'en_espera', nullif((select count(*) from live_apartados e where e.prenda = p.numero and e.estado = 'espera'), 0)))
      into v_r
      from prendas p
      left join live_apartados a on a.prenda = p.numero and a.estado in ('apartada', 'pagada')
      left join live_cuentas c on c.id = a.cuenta_id
      left join clientas cl on cl.id = a.clienta_id
     where p.numero = v_num;
    return v_r;

  -- ------------------------------------------------------------------
  -- Resumen de cómo están las cajas y los cobros ahora mismo
  -- ------------------------------------------------------------------
  elsif p_que = 'resumen' then
    return jsonb_strip_nulls(jsonb_build_object(
      'cajas', (select jsonb_build_object(
                  'total', count(*), 'ocupadas', count(a.id), 'libres', count(*) - count(a.id),
                  'vencidas', count(a.id) filter (where (v_hoy - (a.asignada_en at time zone v_tz)::date) >= v_dias),
                  'dias_para_vencer', v_dias)
                  from cajas k left join asignaciones a on a.caja = k.id and a.estado = 'activa'),
      'cajas_vencidas', (select jsonb_agg(jsonb_build_object('caja', a.caja,
                                 'clienta', trim(cl.nombre || coalesce(' ' || cl.apellidos, '')),
                                 'dias', (v_hoy - (a.asignada_en at time zone v_tz)::date)) order by a.asignada_en)
                           from asignaciones a join clientas cl on cl.id = a.clienta_id
                          where a.estado = 'activa' and (v_hoy - (a.asignada_en at time zone v_tz)::date) >= v_dias),
      'prendas_en_cajas', (select coalesce(sum(p.prendas), 0) from pedidos p join asignaciones a on a.id = p.asignacion_id where a.estado = 'activa'),
      'mercancia_en_cajas', case when v_todo then (select coalesce(sum(p.total), 0) from pedidos p join asignaciones a on a.id = p.asignacion_id where a.estado = 'activa') end,
      'live_en_curso', exists (select 1 from lives where estado = 'activo'),
      'pedidos_del_live_sin_pagar', (select jsonb_strip_nulls(jsonb_build_object(
                  'pedidos', count(*), 'prendas', coalesce(sum(c.piezas), 0),
                  'por_cobrar', case when v_todo then coalesce(sum(c.total - c.monto_pagado), 0) end,
                  'quienes', case when count(*) <= 40 then jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                       'clienta', trim(cl.nombre || coalesce(' ' || cl.apellidos, '')), 'folio', live_folio(c.folio),
                       'estado', replace(c.estado, '_', ' '), 'prendas', c.piezas,
                       'total', case when v_todo then c.total end)) order by c.folio) end))
                  from live_cuentas c join clientas cl on cl.id = c.clienta_id
                 where c.estado in ('abierta', 'por_pagar', 'pago_incompleto') and c.piezas > 0)));

  -- ------------------------------------------------------------------
  -- Ventas de un periodo (solo Dueña y Supervisor, igual que Reportes)
  -- ------------------------------------------------------------------
  elsif p_que = 'ventas' then
    if v_rol not in ('duena', 'supervisor') then
      return jsonb_build_object('sin_permiso', true, 'motivo', 'Las ventas solo las pueden ver Dueña y Supervisor.');
    end if;
    p_hasta := coalesce(p_hasta, v_hoy);
    p_desde := coalesce(p_desde, p_hasta);
    if p_desde > p_hasta then return jsonb_build_object('error', 'La fecha inicial es posterior a la final.'); end if;
    return jsonb_build_object(
      'desde', p_desde, 'hasta', p_hasta,
      'pedidos_en_cajas', (select jsonb_build_object('total_vendido', coalesce(sum(p.total), 0), 'pedidos', count(*),
                                    'prendas', coalesce(sum(p.prendas), 0), 'clientas_que_compraron', count(distinct p.clienta_id))
                             from pedidos p where (p.fecha at time zone v_tz)::date between p_desde and p_hasta),
      'clientas_nuevas', (select count(*) from clientas where fecha_registro between p_desde and p_hasta),
      'cajas_enviadas', (select count(*) from asignaciones a where a.estado = 'enviada' and (a.enviada_en at time zone v_tz)::date between p_desde and p_hasta),
      'lives', reporte_lives(p_desde, p_hasta),
      'nota', 'total_vendido son los pedidos ya pagados que entraron a cajas en esas fechas. En cada live: venta = prendas pagadas; cheque promedio = venta entre clientas_pagaron.');
  end if;

  return jsonb_build_object('error', 'Consulta desconocida.');
end $$;

revoke all on function public.ayuda_norm(text) from public, anon;
revoke all on function public.ayuda_consulta(text, text, date, date) from public, anon;
grant execute on function public.ayuda_norm(text) to authenticated, service_role;
grant execute on function public.ayuda_consulta(text, text, date, date) to authenticated, service_role;
