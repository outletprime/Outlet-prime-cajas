-- =====================================================================
-- Revisar cada pedido antes de cobrarlo (lives de redes).
--
-- Antes: al cerrar el live, a cada clienta se le mandaba su total y empezaba a correr su plazo.
-- Ahora:
--   1. Cerrar el live solo deja de apartar. Las cuentas quedan "en revisión" (siguen 'abierta'
--      con el live ya cerrado): sin cobro y sin plazo.
--   2. Operación live revisa en físico cada casillero. Cada prenda se marca con ✓ en Acomodo;
--      la que no aparece simplemente se queda sin ✓ (o se le quita a la clienta).
--   3. Con todas las prendas con ✓, Operación live confirma el pedido (live_pedido_confirmar):
--      la cuenta pasa a 'por_pagar', todavía sin plazo.
--   4. Una dueña manda la nota (live_cobro_mandar): en ese momento empieza a correr el plazo.
-- Prime Live (mayoristas) no cambia: se cobra al cerrar.
-- =====================================================================

alter table public.live_cuentas add column if not exists revisada_en timestamptz;
alter table public.live_cuentas add column if not exists revisada_por text;
comment on column public.live_cuentas.revisada_en is 'Cuándo Operación live confirmó que el pedido está completo en su casillero';

-- 1. Cerrar: en lives de redes las cuentas quedan en revisión, sin cobro
create or replace function public.live_cerrar(p_live uuid, p_usuario text default null) returns integer
language plpgsql set search_path = public as $$
declare
  v_cfg live_config;
  v_tipo text;
  v_id uuid;
  c live_cuentas;
  v_tel text;
  v_n integer := 0;
begin
  select * into v_cfg from live_config limit 1;
  update lives set estado = 'cerrado', cerrado_en = now(), cerrado_por = p_usuario
   where id = p_live and estado = 'activo'
  returning tipo into v_tipo;
  if not found then raise exception 'Ese live ya estaba cerrado.'; end if;

  for v_id in select id from live_cuentas where live_id = p_live and estado = 'abierta' order by folio loop
    perform live_recalcular(v_id);
    select * into c from live_cuentas where id = v_id for update;
    if c.piezas = 0 then
      update live_cuentas set estado = 'cancelada', casillero_liberado_en = now() where id = c.id;
      continue;
    end if;
    v_n := v_n + 1;
    if v_tipo = 'redes' then continue; end if;   -- queda en revisión: se cobra cuando el pedido esté completo
    update live_cuentas set
      estado = 'por_pagar',
      clabe = coalesce(clabe, nullif(trim(v_cfg.clabe), '')),
      cobro_enviado_en = now(),
      recordatorio_en = now() + v_cfg.horas_recordatorio * interval '1 hour',
      limite_pago = now() + v_cfg.horas_limite * interval '1 hour',
      liberar_en = now() + v_cfg.horas_liberar * interval '1 hour'
    where id = c.id;
    select telefono into v_tel from clientas where id = c.clienta_id;
    perform wa_encolar(v_tel, live_texto_cobro(c.id), c.clienta_id);
  end loop;
  return v_n;
end $$;

-- Una cuenta nueva en un live de redes ya cerrado (alguien heredó una prenda de la lista de espera)
-- también entra en revisión, igual que las demás
create or replace function public.live_cuenta_para(p_live uuid, p_clienta uuid) returns live_cuentas
language plpgsql set search_path = public as $$
declare
  c live_cuentas;
  v_cas text;
  v_abierta boolean;
begin
  select * into c from live_cuentas
   where live_id = p_live and clienta_id = p_clienta
     and estado in ('abierta', 'por_pagar', 'pago_incompleto')
   for update;
  if found then return c; end if;

  select k.id into v_cas from casilleros k
   where k.activo
     and not exists (select 1 from live_cuentas x where x.casillero = k.id and x.casillero_liberado_en is null)
   order by k.orden
   limit 1
   for update skip locked;

  select estado = 'activo' or tipo = 'redes' into v_abierta from lives where id = p_live;
  insert into live_cuentas (live_id, clienta_id, casillero, estado)
  values (p_live, p_clienta, v_cas, case when v_abierta then 'abierta' else 'por_pagar' end)
  returning * into c;
  return c;
end $$;

-- Si hereda una prenda mientras su pedido está en revisión, no se le manda cobro todavía
do $$
declare def text;
begin
  select pg_get_functiondef(p.oid) into def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'live_ofrecer_espera';
  if position('or c.estado = ''abierta''' in def) = 0 then
    if position('  if v_activo then' in def) = 0 then
      raise exception 'No se encontró el punto a cambiar en live_ofrecer_espera().';
    end if;
    execute replace(def, '  if v_activo then', '  if v_activo or c.estado = ''abierta'' then');
  end if;
end $$;

create or replace function public.puede_confirmar_pedido() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is null
      or exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion', 'live'))
$$;

-- 3. Operación live confirma que el pedido está completo en su casillero
create or replace function public.live_pedido_confirmar(p_cuenta uuid, p_usuario text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c live_cuentas;
  v_live lives;
  v_faltan text;
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

  select string_agg(coalesce(live_num(a.prenda), '#' || pp.num), ', ' order by a.prenda nulls last)
    into v_faltan
    from live_apartados a left join prime_prendas pp on pp.id = a.prime_prenda
   where a.cuenta_id = c.id and a.estado = 'apartada' and a.acomodada_en is null;
  if v_faltan is not null then
    raise exception 'Faltan por localizar: %. Márcalas con ✓ cuando estén en el casillero.', v_faltan;
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

-- 4. Mandar la nota: aquí empieza a correr el plazo de pago. Devuelve el texto y el teléfono
--    para mandarla a mano por WhatsApp mientras el bot no tenga número.
create or replace function public.live_cobro_mandar(p_cuenta uuid, p_usuario text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c live_cuentas;
  v_cfg live_config;
  v_cl clientas;
  v_texto text;
  v_primera boolean := false;
begin
  if auth.uid() is not null and not puede_operar() then raise exception 'Tu nivel de acceso no permite mandar cobros.'; end if;
  select * into c from live_cuentas where id = p_cuenta for update;
  if not found then raise exception 'No existe esa cuenta.'; end if;
  if c.estado not in ('por_pagar', 'pago_incompleto') then
    raise exception 'Este pedido todavía no se puede cobrar: falta confirmarlo en Acomodo o ya se cerró.';
  end if;
  select * into v_cfg from live_config limit 1;
  select * into v_cl from clientas where id = c.clienta_id;

  if c.cobro_enviado_en is null or c.liberar_en is null then
    v_primera := true;
    update live_cuentas set
      clabe = coalesce(clabe, nullif(trim(v_cfg.clabe), '')),
      cobro_enviado_en = now(),
      recordatorio_en = now() + v_cfg.horas_recordatorio * interval '1 hour',
      recordado_en = null,
      limite_pago = now() + v_cfg.horas_limite * interval '1 hour',
      liberar_en = now() + v_cfg.horas_liberar * interval '1 hour'
    where id = c.id;
  end if;
  v_texto := live_texto_cobro(c.id);
  if v_primera then perform wa_encolar(v_cl.telefono, v_texto, c.clienta_id); end if;
  return jsonb_build_object('texto', v_texto, 'telefono', v_cl.telefono, 'nombre', v_cl.nombre, 'primera', v_primera);
end $$;

revoke all on function public.puede_confirmar_pedido(), public.live_pedido_confirmar(uuid, text),
  public.live_cobro_mandar(uuid, text) from public, anon;
grant execute on function public.puede_confirmar_pedido(), public.live_pedido_confirmar(uuid, text),
  public.live_cobro_mandar(uuid, text) to authenticated, service_role;
