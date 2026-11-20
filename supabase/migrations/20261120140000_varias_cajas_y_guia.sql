-- =====================================================================
-- 1. Una clienta puede tener VARIAS cajas de resguardo: si el pedido nuevo ya no cabe en su caja
--    (30 prendas en A–H, 40 en I–J), ese pedido completo va a otra caja libre.
-- 2. Repartir una caja que ya está pasada de su capacidad (caja_repartir).
-- 3. Guía por caja, en dos pasos:
--      a) "Lista para generar guía"  → la marca quien metió los pedidos (Dueña, Operación, Operación live).
--                                      Le llega el aviso al Supervisor.
--      b) "Guía pegada"              → la marca el Supervisor (o una Dueña): lista para recolección o
--                                      para llevar a sucursal. Les llega el aviso a las Dueñas.
--    El envío final (foto de la guía, "Marcar como enviado") sigue igual.
-- =====================================================================

-- 1. Varias cajas por clienta (sigue habiendo una sola clienta por caja)
drop index if exists public.una_caja_por_clienta;
create index if not exists asignaciones_clienta_activa on public.asignaciones (clienta_id) where estado = 'activa';

alter table public.asignaciones add column if not exists lista_guia_en timestamptz;
alter table public.asignaciones add column if not exists lista_guia_por text;
alter table public.asignaciones add column if not exists guia_pegada_en timestamptz;
alter table public.asignaciones add column if not exists guia_pegada_por text;
alter table public.asignaciones add column if not exists entrega text;
alter table public.asignaciones drop constraint if exists asignaciones_entrega_check;
alter table public.asignaciones add constraint asignaciones_entrega_check
  check (entrega is null or entrega in ('recoleccion', 'sucursal'));

-- En qué caja va un pedido de N prendas de esta clienta:
--   1) una de sus cajas donde todavía quepa (y que no esté ya lista para guía);
--   2) si no, una caja libre: la más chica donde quepa (las de 40 se guardan para pedidos grandes);
--      si no cabe en ninguna, la libre más grande.
-- Devuelve null si no hay cajas libres.
create or replace function public.caja_para_pedido(
  p_clienta uuid, p_prendas integer, p_excluir uuid default null, p_desde timestamptz default null
) returns public.asignaciones
language plpgsql set search_path = public as $$
declare
  a asignaciones;
  v_caja text;
begin
  select x.* into a
    from asignaciones x join cajas k on k.id = x.caja
   where x.clienta_id = p_clienta and x.estado = 'activa' and x.lista_guia_en is null
     and (p_excluir is null or x.id <> p_excluir)
     and coalesce((select sum(p.prendas) from pedidos p where p.asignacion_id = x.id), 0) + p_prendas <= k.capacidad
   order by x.asignada_en desc
   limit 1;
  if found then return a; end if;

  select k.id into v_caja from cajas k
   where not exists (select 1 from asignaciones x where x.caja = k.id and x.estado = 'activa')
   order by (k.capacidad >= p_prendas) desc,
            case when k.capacidad >= p_prendas then k.capacidad else -k.capacidad end,
            substring(k.id from '^[^0-9]*'), nullif(substring(k.id from '[0-9]+'), '')::integer nulls first, k.id
   limit 1
   for update skip locked;
  if v_caja is null then return null; end if;

  insert into asignaciones (caja, clienta_id, estado, asignada_en, asignada_por, movimientos)
  values (v_caja, p_clienta, 'activa', coalesce(p_desde, now()), 'Sistema de lives', '[]'::jsonb)
  returning * into a;
  return a;
end $$;

-- Lo pagado en el live pasa a la caja donde quepa (antes: siempre a la única caja de la clienta)
create or replace function public.live_pasar_a_caja(p_cuenta uuid) returns text
language plpgsql set search_path = public as $$
declare
  c live_cuentas;
  a asignaciones;
  v_items jsonb;
  v_piezas text[];
  v_live lives;
  v_tz text;
  v_ped uuid;
  v_cat text;
  v_nombre text;
begin
  select * into c from live_cuentas where id = p_cuenta for update;
  if not found then raise exception 'No existe esa cuenta.'; end if;
  if c.estado <> 'pagada' then raise exception 'La cuenta todavía no está pagada.'; end if;
  if c.pedido_id is not null then return c.caja; end if;

  v_piezas := live_etiquetas(c.id, array['pagada']);
  -- Los pagos de una misma clienta se acomodan uno por uno
  perform pg_advisory_xact_lock(hashtext('cajas-de-' || c.clienta_id));
  a := caja_para_pedido(c.clienta_id, cardinality(v_piezas));
  if a.id is null then return null; end if;   -- no hay cajas libres: el panel lo avisa

  select * into v_live from lives where id = c.live_id;
  select zona_horaria into v_tz from live_config limit 1;
  if v_live.tipo = 'prime' then v_cat := 'prime'; v_nombre := 'Prime Live';
  else v_cat := 'live'; v_nombre := 'Live'; end if;

  select jsonb_agg(jsonb_build_object('cat', v_cat, 'nombre', v_nombre, 'precio', precio, 'cantidad', n) order by precio)
    into v_items
    from (select precio, count(*)::integer n from live_apartados
           where cuenta_id = c.id and estado = 'pagada' group by precio) s;

  insert into pedidos (asignacion_id, clienta_id, caja, fecha, items, prendas, total, notas, creado_por)
  values (a.id, c.clienta_id, a.caja, coalesce(c.pagada_en, now()), coalesce(v_items, '[]'::jsonb),
          cardinality(v_piezas), c.total,
          format('%s del %s · folio %s · piezas %s', v_nombre,
                 to_char(v_live.iniciado_en at time zone v_tz, 'DD/MM/YYYY'), live_folio(c.folio),
                 array_to_string(v_piezas, ', ')),
          'Sistema de lives')
  returning id into v_ped;

  update live_cuentas set caja = a.caja, asignacion_id = a.id, pedido_id = v_ped where id = c.id;
  return a.caja;
end $$;

-- 2. Repartir una caja pasada de su capacidad: los pedidos que ya no caben (del más antiguo al más nuevo)
--    pasan completos a otra caja de la misma clienta. Avisa al equipo a dónde mover las prendas.
create or replace function public.caja_repartir(p_asignacion uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a asignaciones;
  b asignaciones;
  p pedidos;
  v_cap integer;
  v_lleva integer := 0;
  v_primero boolean := true;
  v_cl text;
  v_mov text[] := '{}';
  v_sin text[] := '{}';
  v_et text;
begin
  if auth.uid() is not null and not es_duena() then raise exception 'Solo una Dueña puede repartir una caja.'; end if;
  select * into a from asignaciones where id = p_asignacion and estado = 'activa' for update;
  if not found then raise exception 'Esa caja no está ocupada.'; end if;
  select capacidad into v_cap from cajas where id = a.caja;
  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;
  perform pg_advisory_xact_lock(hashtext('cajas-de-' || a.clienta_id));

  for p in select * from pedidos where asignacion_id = a.id order by fecha, id loop
    if v_primero or v_lleva + p.prendas <= v_cap then
      v_lleva := v_lleva + p.prendas;
      v_primero := false;
      continue;
    end if;
    v_et := coalesce((select live_folio(c.folio) from live_cuentas c where c.pedido_id = p.id), 'pedido') || format(' (%s prendas)', p.prendas);
    b := caja_para_pedido(a.clienta_id, p.prendas, a.id, p.fecha);
    if b.id is null then
      v_sin := v_sin || v_et;
      continue;
    end if;
    update pedidos set asignacion_id = b.id, caja = b.caja where id = p.id;
    update live_cuentas set caja = b.caja, asignacion_id = b.id where pedido_id = p.id;
    v_mov := v_mov || (v_et || ' → caja ' || b.caja);
  end loop;

  if cardinality(v_mov) > 0 then
    perform avisos_encolar('caja', 'repartir:' || a.id || ':' || extract(epoch from now())::bigint,
      format('📦 %s: la caja %s ya no daba, se repartió', v_cl, a.caja),
      format('Hay que mover las prendas: %s.%s', array_to_string(v_mov, '; '),
             case when cardinality(v_sin) > 0 then ' Sin caja libre para: ' || array_to_string(v_sin, ', ') || '.' else '' end),
      'index.html#/caja/' || a.caja);
  end if;
  return jsonb_build_object('caja', a.caja, 'clienta', v_cl, 'se_quedan', v_lleva,
                            'movidos', to_jsonb(v_mov), 'sin_caja_libre', to_jsonb(v_sin));
end $$;

-- 3a. Caja lista para generar su guía (todos sus pedidos ya están adentro)
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
  if not found or a.estado <> 'activa' then raise exception 'Esa caja ya se envió o cambió. Revisa de nuevo.'; end if;

  if not coalesce(p_lista, true) then
    if a.guia_pegada_en is not null then raise exception 'La guía ya está pegada: ya no se puede deshacer aquí.'; end if;
    update asignaciones set lista_guia_en = null, lista_guia_por = null where id = a.id returning * into a;
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

  update asignaciones set lista_guia_en = now(), lista_guia_por = v_por where id = a.id returning * into a;
  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('caja', 'lista-guia:' || a.id || ':' || extract(epoch from now())::bigint,
          format('🏷️ Caja %s lista para generar guía', a.caja),
          format('%s · %s %s en %s %s. Genera la guía, pégala en la caja y márcala en Cajas → caja %s.',
                 v_cl, v_pren, case when v_pren = 1 then 'prenda' else 'prendas' end,
                 v_ped, case when v_ped = 1 then 'pedido' else 'pedidos' end, a.caja),
          'index.html#/caja/' || a.caja, 'supervisor')
  on conflict (clave) do nothing;
  return a;
end $$;

-- 3b. Guía pegada en la caja: lista para recolección o para llevar a sucursal (Supervisor o Dueña)
--     Con p_entrega = null se deshace (por si se marcó por error).
create or replace function public.caja_guia_pegada(
  p_asignacion uuid, p_entrega text, p_paqueteria text default null, p_guia text default null, p_usuario text default null
) returns public.asignaciones
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
  if not found or a.estado <> 'activa' then raise exception 'Esa caja ya se envió o cambió. Revisa de nuevo.'; end if;

  if p_entrega is null then
    update asignaciones set guia_pegada_en = null, guia_pegada_por = null, entrega = null where id = a.id returning * into a;
    return a;
  end if;
  if p_entrega not in ('recoleccion', 'sucursal') then raise exception 'Elige recolección o llevar a sucursal.'; end if;
  if a.lista_guia_en is null then raise exception 'Primero hay que marcar la caja como lista para generar guía.'; end if;

  update asignaciones set
    guia_pegada_en = now(), guia_pegada_por = v_por, entrega = p_entrega,
    paqueteria = coalesce(nullif(trim(p_paqueteria), ''), paqueteria),
    guia = coalesce(nullif(trim(p_guia), ''), guia)
  where id = a.id returning * into a;

  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;
  select coalesce(sum(prendas), 0) into v_pren from pedidos where asignacion_id = a.id;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('caja', 'guia-pegada:' || a.id || ':' || extract(epoch from now())::bigint,
          format('📦 Caja %s con guía pegada · %s', a.caja,
                 case when a.entrega = 'recoleccion' then 'lista para recolección' else 'para llevar a sucursal' end),
          concat_ws(' · ', v_cl, format('%s %s', v_pren, case when v_pren = 1 then 'prenda' else 'prendas' end),
                    nullif(concat_ws(' ', a.paqueteria, a.guia), ''),
                    'La marcó ' || split_part(coalesce(v_por, 'supervisor'), '@', 1)),
          'index.html#/caja/' || a.caja, 'duena')
  on conflict (clave) do nothing;
  return a;
end $$;

revoke all on function public.caja_para_pedido(uuid, integer, uuid, timestamptz) from public, anon;
revoke all on function public.caja_repartir(uuid) from public, anon;
revoke all on function public.caja_lista_para_guia(uuid, boolean, text) from public, anon;
revoke all on function public.caja_guia_pegada(uuid, text, text, text, text) from public, anon;
grant execute on function public.caja_para_pedido(uuid, integer, uuid, timestamptz) to authenticated, service_role;
grant execute on function public.caja_repartir(uuid) to authenticated, service_role;
grant execute on function public.caja_lista_para_guia(uuid, boolean, text) to authenticated, service_role;
grant execute on function public.caja_guia_pegada(uuid, text, text, text, text) to authenticated, service_role;
