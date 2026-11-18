-- =====================================================================
-- Un casillero lleva como máximo 10 prendas (live_config.prendas_por_casillero).
--
-- Cada prenda apartada guarda en qué casillero va (live_apartados.casillero). Cuando el casillero
-- de una clienta ya tiene 10 prendas, la siguiente va al siguiente casillero libre, y así. La
-- clienta sigue teniendo una sola cuenta (un solo cobro y una sola caja): solo cambia dónde se
-- guardan sus prendas. Al pagar o liberar la cuenta se liberan todos sus casilleros.
-- Si no queda ningún casillero libre, la prenda va a su primer casillero aunque pase de 10.
-- =====================================================================

alter table public.live_config add column if not exists prendas_por_casillero integer not null default 10;
alter table public.live_config drop constraint if exists live_config_prendas_por_casillero_check;
alter table public.live_config add constraint live_config_prendas_por_casillero_check
  check (prendas_por_casillero between 1 and 100);

alter table public.live_apartados add column if not exists casillero text references public.casilleros(id) on update cascade;
comment on column public.live_apartados.casillero is 'Casillero donde va esta prenda (una clienta puede ocupar varios, hasta prendas_por_casillero en cada uno)';

-- Lo que ya estaba apartado se queda en el casillero de su cuenta (no se reacomoda nada)
update public.live_apartados a set casillero = c.casillero
  from public.live_cuentas c
 where c.id = a.cuenta_id and a.casillero is null and c.casillero is not null and a.estado in ('apartada', 'pagada', 'liberada');

-- ¿Algún pedido sin liberar está usando este casillero?
create or replace function public.live_casillero_ocupado(p_casillero text) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from live_cuentas c where c.casillero = p_casillero and c.casillero_liberado_en is null)
      or exists (select 1 from live_apartados a join live_cuentas c on c.id = a.cuenta_id
                  where a.casillero = p_casillero and a.estado in ('apartada', 'pagada') and c.casillero_liberado_en is null)
$$;

-- Casilleros de una cuenta, en el orden físico
create or replace function public.live_casilleros_de(p_cuenta uuid) returns text[]
language sql stable set search_path = public as $$
  select coalesce(array_agg(k.id order by k.orden), '{}')
    from casilleros k
   where k.id = (select casillero from live_cuentas where id = p_cuenta)
      or exists (select 1 from live_apartados a where a.cuenta_id = p_cuenta and a.casillero = k.id and a.estado in ('apartada', 'pagada', 'liberada'))
$$;

-- "casillero A1" o "casilleros A1 y B5" (para los avisos)
create or replace function public.live_casilleros_frase(p_cuenta uuid) returns text
language sql stable set search_path = public as $$
  select case cardinality(x) when 0 then null when 1 then 'casillero ' || x[1] else 'casilleros ' || live_unir(x) end
    from (select live_casilleros_de(p_cuenta) x) t
$$;

-- Al apartar (o cambiar de clienta) una prenda: su casillero
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
   where (select count(*) from live_apartados x
           where x.cuenta_id = c.id and x.casillero = t.k and x.estado in ('apartada', 'pagada') and x.id <> new.id) < v_max
   order by n limit 1;

  -- 2. Si todos están llenos (o no tiene), el siguiente casillero libre
  if v_cas is null then
    perform pg_advisory_xact_lock(hashtext('casilleros-libres'));
    select k.id into v_cas from casilleros k
     where k.activo and not live_casillero_ocupado(k.id)
     order by k.orden limit 1;
    if v_cas is not null and c.casillero is null then
      update live_cuentas set casillero = v_cas where id = c.id;
    end if;
  end if;

  -- 3. Sin casilleros libres: a su primer casillero aunque pase del máximo
  new.casillero := coalesce(v_cas, c.casillero, (live_casilleros_de(c.id))[1]);
  return new;
end $$;

drop trigger if exists live_apartado_casillero on public.live_apartados;
create trigger live_apartado_casillero before insert or update of estado, cuenta_id on public.live_apartados
  for each row execute function public.live_apartado_casillero();

-- Un casillero nuevo para una cuenta solo puede ser uno que nadie use (ni como extra)
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

  perform pg_advisory_xact_lock(hashtext('casilleros-libres'));
  select k.id into v_cas from casilleros k
   where k.activo and not live_casillero_ocupado(k.id)
   order by k.orden
   limit 1
   for update skip locked;

  select estado = 'activo' or tipo = 'redes' into v_abierta from lives where id = p_live;
  insert into live_cuentas (live_id, clienta_id, casillero, estado)
  values (p_live, p_clienta, v_cas, case when v_abierta then 'abierta' else 'por_pagar' end)
  returning * into c;
  return c;
end $$;

-- Ajustes de texto en funciones existentes (búsqueda y reemplazo exactos)
do $$
declare
  def text;
  f record;
begin
  for f in select * from (values
      ('tiktok_ligar',
       'and not exists (select 1 from live_cuentas c2 where c2.casillero = k.id and c2.casillero_liberado_en is null)',
       'and not live_casillero_ocupado(k.id)'),
      ('avisos_por_cuenta', 'coalesce(''casillero '' || c.casillero, ''sus prendas'')', 'coalesce(live_casilleros_frase(c.id), ''sus prendas'')'),
      ('avisos_por_cuenta', 'coalesce(''casillero '' || c.casillero, ''sin casillero'')', 'coalesce(live_casilleros_frase(c.id), ''sin casillero'')'),
      ('avisos_acomodo', 'select k.casillero into v_antes', 'select coalesce(x.casillero, k.casillero) into v_antes'),
      ('avisos_acomodo', 'and k.casillero is not null and k.casillero is distinct from c.casillero',
       'and coalesce(x.casillero, k.casillero) is not null and coalesce(x.casillero, k.casillero) is distinct from coalesce(a.casillero, c.casillero)'),
      ('avisos_acomodo', 'coalesce(c.casillero, ''sin casillero'')', 'coalesce(a.casillero, c.casillero, ''sin casillero'')'),
      ('avisos_acomodo', 'coalesce(c.casillero, ''⚠️ sin casillero'')', 'coalesce(a.casillero, c.casillero, ''⚠️ sin casillero'')'),
      ('avisos_acomodo', 'coalesce(c.casillero, ''su casillero'')', 'coalesce(a.casillero, c.casillero, ''su casillero'')')
    ) t(fn, viejo, nuevo) loop
    select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = f.fn;
    if position(f.nuevo in def) > 0 then continue; end if;
    if position(f.viejo in def) = 0 then raise exception 'No se encontró en %: %', f.fn, f.viejo; end if;
    execute replace(def, f.viejo, f.nuevo);
  end loop;
end $$;

-- Listas del panel: cada prenda muestra su propio casillero
create or replace view public.live_feed with (security_invoker = true) as
 SELECT a.id, a.live_id, a.prenda, a.clienta_id, a.cuenta_id, a.estado, a.precio, a.mensaje_en, a.creado_en,
    a.actualizado_en, a.prime_prenda, a.origen, a.origen_usuario,
    TRIM(BOTH FROM cl.nombre || COALESCE(' '::text || cl.apellidos, ''::text)) AS clienta,
    cl.telefono,
    COALESCE(a.casillero, c.casillero) AS casillero,
    c.folio
   FROM live_apartados a
     JOIN clientas cl ON cl.id = a.clienta_id
     LEFT JOIN live_cuentas c ON c.id = a.cuenta_id;

create or replace view public.live_acomodo with (security_invoker = true) as
 SELECT a.id, a.live_id, a.prenda, a.prime_prenda, a.estado, a.creado_en, a.actualizado_en, a.acomodada_en,
    a.acomodada_por, a.regresada_en, a.regresada_por,
    COALESCE(live_num(a.prenda), '#'::text || pp.num) AS etiqueta,
    COALESCE(a.casillero, c.casillero) AS casillero,
    TRIM(BOTH FROM cl.nombre || COALESCE(' '::text || cl.apellidos, ''::text)) AS clienta,
        CASE
            WHEN a.estado = 'apartada'::text AND a.acomodada_en IS NULL THEN 'acomodar'::text
            WHEN a.estado = 'liberada'::text AND a.regresada_en IS NULL AND NOT o.otra THEN 'regresar'::text
            ELSE 'hecho'::text
        END AS tarea
   FROM live_apartados a
     JOIN clientas cl ON cl.id = a.clienta_id
     LEFT JOIN live_cuentas c ON c.id = a.cuenta_id
     LEFT JOIN prime_prendas pp ON pp.id = a.prime_prenda
     CROSS JOIN LATERAL ( SELECT (EXISTS ( SELECT 1
                   FROM live_apartados x
                  WHERE (x.estado = ANY (ARRAY['apartada'::text, 'pagada'::text])) AND x.id <> a.id AND (x.prenda = a.prenda OR x.prime_prenda = a.prime_prenda))) AS otra) o
  WHERE a.estado = 'apartada'::text AND a.acomodada_en IS NULL OR a.estado = 'liberada'::text AND a.regresada_en IS NULL AND NOT o.otra OR a.acomodada_en > (now() - '12:00:00'::interval) OR a.regresada_en > (now() - '12:00:00'::interval);

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
    live_unir(live_casilleros_de(c.id)) AS casilleros_txt
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

-- Detalle del pedido: cada prenda con su casillero
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
    'casilleros', live_unir(live_casilleros_de(c.id)),
    'clienta', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = c.clienta_id),
    'revisable', c.estado = 'abierta' and v_live.estado = 'cerrado',
    'piezas', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', a.id, 'clave', coalesce(live_num(a.prenda), '#' || pp.num), 'estado', a.estado,
                  'casillero', coalesce(a.casillero, c.casillero),
                  'revision', a.revision, 'revision_por', a.revision_por, 'revision_en', a.revision_en)
                  order by coalesce(a.casillero, c.casillero), a.prenda nulls last, pp.num), '[]'::jsonb)
                 from live_apartados a left join prime_prendas pp on pp.id = a.prime_prenda
                where a.cuenta_id = c.id and a.estado in ('apartada', 'pagada')));
end $$;

revoke all on function public.live_casillero_ocupado(text), public.live_casilleros_de(uuid), public.live_casilleros_frase(uuid),
  public.live_apartado_casillero() from public, anon;
grant execute on function public.live_casillero_ocupado(text), public.live_casilleros_de(uuid), public.live_casilleros_frase(uuid)
  to authenticated, service_role;
