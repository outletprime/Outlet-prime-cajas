-- =====================================================================
-- Sistema de lives automatizado · Outlet Prime
--
-- Apartados por WhatsApp, casilleros, cobro y paso automático a la caja fija.
-- Vive en la MISMA base que la app de Cajas y usa la MISMA tabla de clientas:
-- una clienta = un número de WhatsApp, sin duplicados.
--
-- Solo AGREGA cosas: no borra ni cambia datos existentes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Una clienta por número de WhatsApp (sirve para Cajas, el bot y el live)
-- ---------------------------------------------------------------------
create unique index if not exists clientas_telefono_unico
  on public.clientas (telefono)
  where telefono is not null and telefono <> '';

-- ---------------------------------------------------------------------
-- 1. Categoría "Live" en la app de Cajas (prendas del live a $89)
-- ---------------------------------------------------------------------
insert into public.categorias (id, nombre, precio, editable, activa, orden)
select 'live', 'Live', 89, false, true, coalesce(max(orden), 0) + 1 from public.categorias
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 2. Tablas
-- ---------------------------------------------------------------------

-- Ajustes del live (una sola fila)
create table if not exists public.live_config (
  id boolean primary key default true check (id),
  precio numeric not null default 89 check (precio > 0),
  horas_recordatorio numeric not null default 1,
  horas_limite numeric not null default 2,
  horas_liberar numeric not null default 3,
  limite_por_clienta integer check (limite_por_clienta is null or limite_por_clienta > 0),
  clabe text,               -- CLABE de respaldo (BBVA) mientras no haya CLABE por pedido
  banco text,
  titular text,
  zona_horaria text not null default 'America/Mexico_City',
  mensaje_sin_live text not null default 'Ahorita no hay live en curso. Te esperamos en el próximo: de lunes a sábado de 10:00 am a 12:00 pm y de 5:00 a 7:00 pm.',
  actualizado_en timestamptz not null default now(),
  check (horas_recordatorio > 0 and horas_recordatorio < horas_limite and horas_limite <= horas_liberar)
);
insert into public.live_config (id) values (true) on conflict do nothing;

-- Inventario: cada prenda conserva su número hasta venderse
create table if not exists public.prendas (
  numero integer primary key check (numero between 1 and 99999),
  precio numeric not null default 89 check (precio > 0),
  estado text not null default 'disponible'
    check (estado in ('disponible', 'apartada', 'pagada', 'enviada', 'baja')),
  descripcion text,
  registrada_en timestamptz not null default now(),
  registrada_por text,
  actualizada_en timestamptz not null default now()
);
create index if not exists prendas_estado on public.prendas (estado);

-- Cada transmisión
create table if not exists public.lives (
  id uuid primary key default gen_random_uuid(),
  titulo text,
  estado text not null default 'activo' check (estado in ('activo', 'cerrado')),
  iniciado_en timestamptz not null default now(),
  iniciado_por text,
  cerrado_en timestamptz,
  cerrado_por text
);
create unique index if not exists lives_uno_activo on public.lives ((true)) where estado = 'activo';

-- Estación 1: casilleros para lo apartado sin pagar
create table if not exists public.casilleros (
  id text primary key,
  orden integer not null,
  activo boolean not null default true
);
insert into public.casilleros (id, orden)
select 'C-' || lpad(n::text, 3, '0'), n from generate_series(1, 100) n
on conflict (id) do nothing;

-- Cuenta de cobro: lo que una clienta apartó en un live
create table if not exists public.live_cuentas (
  id uuid primary key default gen_random_uuid(),
  folio bigint generated always as identity,
  live_id uuid not null references public.lives (id),
  clienta_id uuid not null references public.clientas (id),
  casillero text references public.casilleros (id) on update cascade,
  estado text not null default 'abierta'
    check (estado in ('abierta', 'por_pagar', 'pago_incompleto', 'pagada', 'vencida', 'cancelada')),
  total numeric not null default 0,
  piezas integer not null default 0,
  monto_pagado numeric not null default 0,
  clabe text,
  proveedor text,
  proveedor_ref text,
  cobro_enviado_en timestamptz,
  recordatorio_en timestamptz,
  recordado_en timestamptz,
  limite_pago timestamptz,
  liberar_en timestamptz,
  vencida_en timestamptz,
  pagada_en timestamptz,
  pagada_por text,
  caja text references public.cajas (id) on update cascade,
  asignacion_id uuid references public.asignaciones (id) on delete set null,
  pedido_id uuid references public.pedidos (id) on delete set null,
  en_caja_en timestamptz,
  casillero_liberado_en timestamptz,
  casillero_liberado_por text,
  creada_en timestamptz not null default now()
);
create unique index if not exists live_cuentas_una_abierta
  on public.live_cuentas (live_id, clienta_id)
  where estado in ('abierta', 'por_pagar', 'pago_incompleto');
create unique index if not exists live_cuentas_casillero_ocupado
  on public.live_cuentas (casillero)
  where casillero is not null and casillero_liberado_en is null;
create index if not exists live_cuentas_live on public.live_cuentas (live_id);
create index if not exists live_cuentas_clienta on public.live_cuentas (clienta_id);
create index if not exists live_cuentas_estado on public.live_cuentas (estado);

-- Cada número que pide una clienta (apartado o lista de espera)
create table if not exists public.live_apartados (
  id uuid primary key default gen_random_uuid(),
  live_id uuid not null references public.lives (id),
  prenda integer not null references public.prendas (numero),
  clienta_id uuid not null references public.clientas (id),
  cuenta_id uuid references public.live_cuentas (id),
  estado text not null check (estado in ('apartada', 'espera', 'pagada', 'liberada', 'cancelada')),
  precio numeric not null,
  mensaje_en timestamptz not null,       -- hora exacta del mensaje: gana la primera
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create unique index if not exists live_apartados_prenda_ocupada
  on public.live_apartados (prenda) where estado in ('apartada', 'pagada');
create unique index if not exists live_apartados_espera_unica
  on public.live_apartados (prenda, clienta_id) where estado = 'espera';
create index if not exists live_apartados_cuenta on public.live_apartados (cuenta_id);
create index if not exists live_apartados_live on public.live_apartados (live_id, creado_en desc);
create index if not exists live_apartados_clienta on public.live_apartados (clienta_id);

-- Mensajes de WhatsApp (entrada y salida). Teléfonos que empiezan con 00 = simulador.
create table if not exists public.wa_mensajes (
  id uuid primary key default gen_random_uuid(),
  direccion text not null check (direccion in ('entrada', 'salida')),
  telefono text not null,
  wa_id text,
  texto text not null,
  clienta_id uuid references public.clientas (id) on delete set null,
  estado text not null default 'pendiente'
    check (estado in ('recibido', 'pendiente', 'enviado', 'error', 'simulado', 'caducado')),
  simulado boolean not null default false,
  error text,
  creado_en timestamptz not null default now(),
  enviado_en timestamptz
);
create unique index if not exists wa_mensajes_wa_id on public.wa_mensajes (wa_id) where wa_id is not null;
create index if not exists wa_mensajes_tel on public.wa_mensajes (telefono, creado_en);
create index if not exists wa_mensajes_pendientes on public.wa_mensajes (creado_en) where estado = 'pendiente';

-- ---------------------------------------------------------------------
-- 3. Seguridad: solo el equipo con sesión iniciada (igual que Cajas)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['live_config', 'prendas', 'lives', 'casilleros', 'live_cuentas', 'live_apartados', 'wa_mensajes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists equipo on public.%I', t);
    execute format('create policy equipo on public.%I for all to authenticated using (true) with check (true)', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated, service_role', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. Ayudantes de texto
-- ---------------------------------------------------------------------
create or replace function public.live_tel10(p text) returns text
language sql immutable set search_path = public as $$
  select right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10)
$$;

create or replace function public.live_num(p integer) returns text
language sql immutable set search_path = public as $$
  select lpad(p::text, 4, '0')
$$;

create or replace function public.live_dinero(p numeric) returns text
language sql immutable set search_path = public as $$
  select '$' || to_char(round(coalesce(p, 0)), 'FM999,999,990')
$$;

create or replace function public.live_hora(p timestamptz) returns text
language sql stable set search_path = public as $$
  select lower(to_char(p at time zone (select zona_horaria from public.live_config limit 1), 'FMHH12:MI am'))
$$;

-- "0023", "0023 y 0310", "0023, 0310 y 0451"
create or replace function public.live_lista(p integer[]) returns text
language sql immutable set search_path = public as $$
  select case
    when p is null or cardinality(p) = 0 then ''
    when cardinality(p) = 1 then public.live_num(p[1])
    else (select string_agg(public.live_num(x), ', ' order by o)
            from unnest(p[1:cardinality(p) - 1]) with ordinality t(x, o))
         || ' y ' || public.live_num(p[cardinality(p)])
  end
$$;

create or replace function public.live_folio(p bigint) returns text
language sql immutable set search_path = public as $$
  select 'OP-' || lpad(p::text, 3, '0')
$$;

-- Deja un mensaje en la cola de salida de WhatsApp
create or replace function public.wa_encolar(p_telefono text, p_texto text, p_clienta uuid default null)
returns uuid language plpgsql set search_path = public as $$
declare
  v_id uuid;
  v_sim boolean := p_telefono like '00%';
begin
  if coalesce(trim(p_texto), '') = '' then return null; end if;
  insert into wa_mensajes (direccion, telefono, texto, clienta_id, estado, simulado)
  values ('salida', p_telefono, p_texto, p_clienta, case when v_sim then 'simulado' else 'pendiente' end, v_sim)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- 5. Cuentas, totales y textos de cobro
-- ---------------------------------------------------------------------
create or replace function public.live_recalcular(p_cuenta uuid) returns void
language sql set search_path = public as $$
  update live_cuentas c set
    total = coalesce((select sum(a.precio) from live_apartados a
                       where a.cuenta_id = c.id and a.estado in ('apartada', 'pagada')), 0),
    piezas = (select count(*) from live_apartados a
               where a.cuenta_id = c.id and a.estado in ('apartada', 'pagada'))
  where c.id = p_cuenta
$$;

-- Cuenta abierta de la clienta en ese live; si no tiene, se crea con el primer casillero libre
create or replace function public.live_cuenta_para(p_live uuid, p_clienta uuid)
returns public.live_cuentas language plpgsql set search_path = public as $$
declare
  c live_cuentas;
  v_cas text;
  v_activo boolean;
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

  select estado = 'activo' into v_activo from lives where id = p_live;
  insert into live_cuentas (live_id, clienta_id, casillero, estado)
  values (p_live, p_clienta, v_cas, case when v_activo then 'abierta' else 'por_pagar' end)
  returning * into c;
  return c;
end $$;

-- "Llevas 2 prendas: 0023 y 0310 = $178."
create or replace function public.live_texto_resumen(p_live uuid, p_clienta uuid) returns text
language plpgsql stable set search_path = public as $$
declare
  c live_cuentas;
  v_p integer[];
begin
  select * into c from live_cuentas
   where live_id = p_live and clienta_id = p_clienta and estado = 'abierta'
   order by creada_en desc limit 1;
  if not found or c.piezas = 0 then return null; end if;
  select array_agg(prenda order by prenda) into v_p
    from live_apartados where cuenta_id = c.id and estado = 'apartada';
  return format('🛍️ Llevas %s %s: %s = %s. Al terminar el live te mandamos tu total y cómo pagar.',
    c.piezas, case when c.piezas = 1 then 'prenda' else 'prendas' end, live_lista(v_p), live_dinero(c.total));
end $$;

-- Mensaje con el total y cómo pagar
create or replace function public.live_texto_cobro(p_cuenta uuid) returns text
language plpgsql stable set search_path = public as $$
declare
  c live_cuentas;
  v_cfg live_config;
  v_p integer[];
  v_txt text;
  v_datos text;
begin
  select * into c from live_cuentas where id = p_cuenta;
  select * into v_cfg from live_config limit 1;
  select coalesce(array_agg(prenda order by prenda), '{}') into v_p
    from live_apartados where cuenta_id = p_cuenta and estado = 'apartada';

  v_txt := format('🧾 Tu total del live: *%s* (%s %s: %s).',
    live_dinero(c.total), c.piezas, case when c.piezas = 1 then 'prenda' else 'prendas' end, live_lista(v_p));

  if coalesce(c.clabe, '') <> '' then
    v_datos := concat_ws(', ', nullif(trim(v_cfg.banco), ''),
                         case when coalesce(trim(v_cfg.titular), '') <> '' then 'a nombre de ' || trim(v_cfg.titular) end);
    v_txt := v_txt || E'\n' || format('Transfiere a la CLABE %s%s antes de las %s. En el concepto pon: %s',
      c.clabe, case when v_datos <> '' then ' (' || v_datos || ')' else '' end,
      live_hora(c.limite_pago), live_folio(c.folio));
  else
    v_txt := v_txt || E'\n' || format('En un momento te mandamos los datos para pagar. Tienes hasta las %s.',
      live_hora(c.limite_pago));
  end if;

  v_txt := v_txt || E'\n' || format('Si no recibimos tu pago, a las %s tus prendas se liberan para otras clientas.',
    live_hora(c.liberar_en));
  return v_txt;
end $$;

-- ---------------------------------------------------------------------
-- 6. El bot: procesa un mensaje de WhatsApp y prepara la respuesta
-- ---------------------------------------------------------------------
create or replace function public.bot_mensaje(
  p_telefono text,
  p_texto text,
  p_nombre text default null,
  p_wa_id text default null,
  p_recibido timestamptz default null
) returns jsonb
language plpgsql set search_path = public as $$
declare
  v_tel text := live_tel10(p_telefono);
  v_sim boolean;
  v_recibido timestamptz := coalesce(p_recibido, clock_timestamp());
  v_txt text := coalesce(p_texto, '');
  v_cfg live_config;
  v_cl clientas;
  v_live lives;
  v_c live_cuentas;
  v_pr prendas;
  v_nums integer[];
  v_n integer;
  v_pos integer;
  v_nueva boolean := false;
  v_tuyas integer[] := '{}';
  v_ya integer[] := '{}';
  v_vendidas integer[] := '{}';
  v_noexiste integer[] := '{}';
  v_limite integer[] := '{}';
  v_espera text[] := '{}';
  v_lineas text[] := '{}';
  v_resp text;
  v_salida uuid;
begin
  if length(v_tel) <> 10 then
    raise exception 'Número de WhatsApp inválido: %', p_telefono;
  end if;
  v_sim := v_tel like '00%';

  -- El mismo mensaje no se procesa dos veces
  if p_wa_id is not null and exists (select 1 from wa_mensajes where wa_id = p_wa_id) then
    return jsonb_build_object('duplicado', true);
  end if;

  -- Los mensajes de una misma clienta se procesan en orden
  perform pg_advisory_xact_lock(hashtext('live-tel-' || v_tel));
  select * into v_cfg from live_config limit 1;

  -- Una clienta por número: si no existe, se registra sola
  select * into v_cl from clientas where telefono = v_tel;
  if not found then
    insert into clientas (nombre, telefono, fecha_registro, creado_por)
    values (coalesce(nullif(trim(p_nombre), ''), 'Clienta ' || right(v_tel, 4)), v_tel,
            (now() at time zone v_cfg.zona_horaria)::date,
            case when v_sim then 'Simulador' else 'Bot WhatsApp' end)
    returning * into v_cl;
    v_nueva := true;
  end if;

  insert into wa_mensajes (direccion, telefono, wa_id, texto, clienta_id, estado, simulado, creado_en)
  values ('entrada', v_tel, p_wa_id, v_txt, v_cl.id, 'recibido', v_sim, v_recibido);

  -- Números de 1 a 5 cifras, en el orden en que los escribió
  select coalesce(array_agg(n order by o), '{}') into v_nums
    from (select (m[1])::integer as n, min(o) as o
            from regexp_matches(v_txt, '(?<![0-9])([0-9]{1,5})(?![0-9])', 'g') with ordinality as t(m, o)
           group by 1) s;

  select * into v_live from lives where estado = 'activo' limit 1;

  if v_nueva then
    v_lineas := v_lineas || '¡Bienvenida a Outlet Prime! 💕'::text;
  end if;

  if cardinality(v_nums) = 0 then
    -- Sin números: ayuda y estado de su cuenta
    if v_live.id is not null then
      v_lineas := v_lineas || format('Hola %s 👋 Para apartar manda el número de la etiqueta, por ejemplo: 23. Puedes mandar varios: 23 45 310.',
                                     split_part(v_cl.nombre, ' ', 1));
      v_lineas := v_lineas || live_texto_resumen(v_live.id, v_cl.id);
    else
      select * into v_c from live_cuentas
       where clienta_id = v_cl.id and estado = 'por_pagar'
       order by creada_en desc limit 1;
      if found then
        v_lineas := v_lineas || format('Hola %s 👋 Esto es lo que tienes pendiente:', split_part(v_cl.nombre, ' ', 1));
        v_lineas := v_lineas || live_texto_cobro(v_c.id);
      else
        v_lineas := v_lineas || v_cfg.mensaje_sin_live;
      end if;
    end if;

  elsif v_live.id is null then
    v_lineas := v_lineas || v_cfg.mensaje_sin_live;

  else
    foreach v_n in array v_nums loop
      select * into v_pr from prendas where numero = v_n for update;
      if not found then
        v_noexiste := v_noexiste || v_n;
        continue;
      end if;

      if exists (select 1 from live_apartados
                  where prenda = v_n and clienta_id = v_cl.id and estado in ('apartada', 'pagada')) then
        v_ya := v_ya || v_n;

      elsif v_pr.estado = 'disponible' then
        if v_cfg.limite_por_clienta is not null and
           (select count(*) from live_apartados
             where live_id = v_live.id and clienta_id = v_cl.id and estado in ('apartada', 'pagada')) >= v_cfg.limite_por_clienta then
          v_limite := v_limite || v_n;
          continue;
        end if;
        v_c := live_cuenta_para(v_live.id, v_cl.id);
        update live_apartados set estado = 'cancelada', actualizado_en = now()
         where prenda = v_n and clienta_id = v_cl.id and estado = 'espera';
        insert into live_apartados (live_id, prenda, clienta_id, cuenta_id, estado, precio, mensaje_en)
        values (v_live.id, v_n, v_cl.id, v_c.id, 'apartada', v_pr.precio, v_recibido);
        update prendas set estado = 'apartada', actualizada_en = now() where numero = v_n;
        perform live_recalcular(v_c.id);
        v_tuyas := v_tuyas || v_n;

      elsif v_pr.estado = 'apartada' then
        -- Ya la tiene otra: lista de espera
        if not exists (select 1 from live_apartados
                        where prenda = v_n and clienta_id = v_cl.id and estado = 'espera') then
          insert into live_apartados (live_id, prenda, clienta_id, estado, precio, mensaje_en)
          values (v_live.id, v_n, v_cl.id, 'espera', v_pr.precio, v_recibido);
        end if;
        select count(*) into v_pos
          from live_apartados e, live_apartados yo
         where yo.prenda = v_n and yo.clienta_id = v_cl.id and yo.estado = 'espera'
           and e.prenda = v_n and e.estado = 'espera'
           and (e.mensaje_en, e.creado_en) <= (yo.mensaje_en, yo.creado_en);
        v_espera := v_espera || format('%s ya se apartó: quedaste #%s en espera', live_num(v_n), v_pos);

      else
        v_vendidas := v_vendidas || v_n;
      end if;
    end loop;

    if cardinality(v_tuyas) = 1 then
      v_lineas := v_lineas || format('✅ La %s es tuya.', live_num(v_tuyas[1]));
    elsif cardinality(v_tuyas) > 1 then
      v_lineas := v_lineas || format('✅ %s son tuyas.', live_lista(v_tuyas));
    end if;
    if cardinality(v_ya) = 1 then
      v_lineas := v_lineas || format('👍 La %s ya era tuya.', live_num(v_ya[1]));
    elsif cardinality(v_ya) > 1 then
      v_lineas := v_lineas || format('👍 %s ya eran tuyas.', live_lista(v_ya));
    end if;
    if cardinality(v_espera) > 0 then
      v_lineas := v_lineas || ('⏳ ' || array_to_string(v_espera, '; ') || '. Si se libera, te avisamos.');
    end if;
    if cardinality(v_vendidas) = 1 then
      v_lineas := v_lineas || format('❌ La %s ya se vendió.', live_num(v_vendidas[1]));
    elsif cardinality(v_vendidas) > 1 then
      v_lineas := v_lineas || format('❌ %s ya se vendieron.', live_lista(v_vendidas));
    end if;
    if cardinality(v_noexiste) > 0 then
      v_lineas := v_lineas || format('🤔 No encontramos %s. Revisa el número de la etiqueta.',
        case when cardinality(v_noexiste) = 1 then 'la ' || live_num(v_noexiste[1]) else live_lista(v_noexiste) end);
    end if;
    if cardinality(v_limite) > 0 then
      v_lineas := v_lineas || format('⚠️ Ya tienes el máximo de %s prendas en este live; no pudimos apartar %s.',
        v_cfg.limite_por_clienta, live_lista(v_limite));
    end if;
    v_lineas := v_lineas || live_texto_resumen(v_live.id, v_cl.id);
  end if;

  v_resp := array_to_string(v_lineas, E'\n');
  v_salida := wa_encolar(v_tel, v_resp, v_cl.id);

  return jsonb_build_object(
    'clienta_id', v_cl.id,
    'nueva', v_nueva,
    'respuesta', v_resp,
    'mensaje_id', v_salida,
    'apartadas', to_jsonb(v_tuyas),
    'espera', to_jsonb(v_espera)
  );
end $$;

-- ---------------------------------------------------------------------
-- 7. Ciclo del live
-- ---------------------------------------------------------------------
create or replace function public.live_iniciar(p_titulo text default null, p_usuario text default null)
returns public.lives language plpgsql set search_path = public as $$
declare l lives;
begin
  if exists (select 1 from lives where estado = 'activo') then
    raise exception 'Ya hay un live en curso.';
  end if;
  insert into lives (titulo, iniciado_por) values (nullif(trim(p_titulo), ''), p_usuario) returning * into l;
  return l;
end $$;

-- Cierra el live y manda a cada clienta su total y cómo pagar
create or replace function public.live_cerrar(p_live uuid, p_usuario text default null)
returns integer language plpgsql set search_path = public as $$
declare
  v_cfg live_config;
  v_id uuid;
  c live_cuentas;
  v_tel text;
  v_n integer := 0;
begin
  select * into v_cfg from live_config limit 1;
  update lives set estado = 'cerrado', cerrado_en = now(), cerrado_por = p_usuario
   where id = p_live and estado = 'activo';
  if not found then raise exception 'Ese live ya estaba cerrado.'; end if;

  for v_id in select id from live_cuentas where live_id = p_live and estado = 'abierta' order by folio loop
    perform live_recalcular(v_id);
    select * into c from live_cuentas where id = v_id for update;
    if c.piezas = 0 then
      update live_cuentas set estado = 'cancelada', casillero_liberado_en = now() where id = c.id;
      continue;
    end if;
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
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Pone lo pagado en la caja fija de la clienta y crea el pedido en la app de Cajas
create or replace function public.live_pasar_a_caja(p_cuenta uuid) returns text
language plpgsql set search_path = public as $$
declare
  c live_cuentas;
  a asignaciones;
  v_caja text;
  v_items jsonb;
  v_piezas integer[];
  v_live lives;
  v_tz text;
  v_ped uuid;
begin
  select * into c from live_cuentas where id = p_cuenta for update;
  if not found then raise exception 'No existe esa cuenta.'; end if;
  if c.estado <> 'pagada' then raise exception 'La cuenta todavía no está pagada.'; end if;
  if c.pedido_id is not null then return c.caja; end if;

  select * into a from asignaciones where clienta_id = c.clienta_id and estado = 'activa' limit 1;
  if not found then
    select k.id into v_caja from cajas k
     where not exists (select 1 from asignaciones x where x.caja = k.id and x.estado = 'activa')
     order by substring(k.id from '^[^0-9]*'), nullif(substring(k.id from '[0-9]+'), '')::integer nulls first, k.id
     limit 1
     for update skip locked;
    if v_caja is null then
      return null; -- no hay cajas libres: el panel lo avisa
    end if;
    insert into asignaciones (caja, clienta_id, estado, asignada_por, movimientos)
    values (v_caja, c.clienta_id, 'activa', 'Sistema de lives', '[]'::jsonb)
    returning * into a;
  end if;

  select coalesce(array_agg(prenda order by prenda), '{}') into v_piezas
    from live_apartados where cuenta_id = c.id and estado = 'pagada';
  select jsonb_agg(jsonb_build_object('cat', 'live', 'nombre', 'Live', 'precio', precio, 'cantidad', n) order by precio)
    into v_items
    from (select precio, count(*)::integer n from live_apartados
           where cuenta_id = c.id and estado = 'pagada' group by precio) s;
  select * into v_live from lives where id = c.live_id;
  select zona_horaria into v_tz from live_config limit 1;

  insert into pedidos (asignacion_id, clienta_id, caja, fecha, items, prendas, total, notas, creado_por)
  values (a.id, c.clienta_id, a.caja, coalesce(c.pagada_en, now()), coalesce(v_items, '[]'::jsonb),
          cardinality(v_piezas), c.total,
          format('Live del %s · folio %s · piezas %s',
                 to_char(v_live.iniciado_en at time zone v_tz, 'DD/MM/YYYY'), live_folio(c.folio),
                 (select string_agg(live_num(x), ', ' order by x) from unnest(v_piezas) x)),
          'Sistema de lives')
  returning id into v_ped;

  update live_cuentas set caja = a.caja, asignacion_id = a.id, pedido_id = v_ped where id = c.id;
  return a.caja;
end $$;

-- Registra un pago (a mano desde el panel o, más adelante, del proveedor de CLABE)
create or replace function public.live_registrar_pago(
  p_cuenta uuid,
  p_monto numeric default null,
  p_usuario text default null,
  p_referencia text default null
) returns public.live_cuentas
language plpgsql set search_path = public as $$
declare
  c live_cuentas;
  v_tel text;
  v_falta numeric;
  v_caja text;
begin
  select * into c from live_cuentas where id = p_cuenta for update;
  if not found then raise exception 'No existe esa cuenta.'; end if;
  if c.estado = 'pagada' then raise exception 'Esa cuenta ya estaba pagada.'; end if;
  if c.estado = 'abierta' then raise exception 'El live sigue en curso: ciérralo antes de registrar pagos.'; end if;
  if c.estado not in ('por_pagar', 'pago_incompleto') then
    raise exception 'Esta cuenta ya no se puede cobrar: sus prendas se liberaron.';
  end if;
  if p_monto is not null and p_monto <= 0 then raise exception 'El monto debe ser mayor a cero.'; end if;

  perform live_recalcular(c.id);
  select * into c from live_cuentas where id = p_cuenta;
  update live_cuentas set
    monto_pagado = monto_pagado + coalesce(p_monto, greatest(total - monto_pagado, 0)),
    proveedor_ref = coalesce(nullif(trim(p_referencia), ''), proveedor_ref)
  where id = c.id
  returning * into c;
  select telefono into v_tel from clientas where id = c.clienta_id;

  v_falta := c.total - c.monto_pagado;
  if v_falta > 0 then
    update live_cuentas set estado = 'pago_incompleto' where id = c.id returning * into c;
    perform wa_encolar(v_tel, format('Recibimos %s, pero tu total es %s. Te faltan %s para completar tu pago (folio %s).',
      live_dinero(c.monto_pagado), live_dinero(c.total), live_dinero(v_falta), live_folio(c.folio)), c.clienta_id);
    return c;
  end if;

  update live_apartados set estado = 'pagada', actualizado_en = now()
   where cuenta_id = c.id and estado = 'apartada';
  update prendas p set estado = 'pagada', actualizada_en = now()
    from live_apartados a
   where a.cuenta_id = c.id and a.estado = 'pagada' and p.numero = a.prenda;
  update live_apartados e set estado = 'cancelada', actualizado_en = now()
    from live_apartados a
   where a.cuenta_id = c.id and a.estado = 'pagada' and e.prenda = a.prenda and e.estado = 'espera';
  update live_cuentas set estado = 'pagada', pagada_en = now(), pagada_por = p_usuario where id = c.id;

  v_caja := live_pasar_a_caja(c.id);
  select * into c from live_cuentas where id = c.id;
  perform wa_encolar(v_tel, format('✅ Pago recibido (%s). Tus prendas ya van a tu caja. Te avisamos cuando la enviemos.',
    live_dinero(c.monto_pagado)), c.clienta_id);
  return c;
end $$;

-- El ayudante confirma que vació el casillero (a la caja o de regreso a racks)
create or replace function public.live_casillero_listo(p_cuenta uuid, p_usuario text default null)
returns void language plpgsql set search_path = public as $$
declare c live_cuentas;
begin
  select * into c from live_cuentas where id = p_cuenta for update;
  if not found then raise exception 'No existe esa cuenta.'; end if;
  if c.casillero_liberado_en is not null then return; end if;
  if c.estado = 'pagada' then
    if c.pedido_id is null then raise exception 'Primero hay que asignarle una caja.'; end if;
    update live_cuentas set en_caja_en = now(), casillero_liberado_en = now(), casillero_liberado_por = p_usuario
     where id = c.id;
  elsif c.estado in ('vencida', 'cancelada') then
    update live_cuentas set casillero_liberado_en = now(), casillero_liberado_por = p_usuario where id = c.id;
  else
    raise exception 'Este casillero todavía no se vacía: la cuenta está %.', replace(c.estado, '_', ' ');
  end if;
end $$;

-- Cuando una prenda se libera, pasa a la primera de la lista de espera
create or replace function public.live_ofrecer_espera(p_prenda integer) returns uuid
language plpgsql set search_path = public as $$
declare
  e live_apartados;
  c live_cuentas;
  v_cfg live_config;
  v_activo boolean;
  v_tel text;
  v_txt text;
begin
  perform 1 from prendas where numero = p_prenda and estado = 'disponible' for update;
  if not found then return null; end if;
  select * into e from live_apartados
   where prenda = p_prenda and estado = 'espera'
   order by mensaje_en, creado_en
   limit 1
   for update skip locked;
  if not found then return null; end if;

  select * into v_cfg from live_config limit 1;
  select estado = 'activo' into v_activo from lives where id = e.live_id;
  c := live_cuenta_para(e.live_id, e.clienta_id);
  update live_apartados set estado = 'apartada', cuenta_id = c.id, actualizado_en = now() where id = e.id;
  update prendas set estado = 'apartada', actualizada_en = now() where numero = p_prenda;
  perform live_recalcular(c.id);

  if v_activo then
    v_txt := format('🎉 ¡Se liberó la %s y ahora es tuya! Al terminar el live te mandamos tu total.', live_num(p_prenda));
  else
    update live_cuentas set
      clabe = coalesce(clabe, nullif(trim(v_cfg.clabe), '')),
      cobro_enviado_en = now(),
      recordatorio_en = now() + v_cfg.horas_recordatorio * interval '1 hour',
      recordado_en = null,
      limite_pago = now() + v_cfg.horas_limite * interval '1 hour',
      liberar_en = now() + v_cfg.horas_liberar * interval '1 hour'
    where id = c.id;
    v_txt := format('🎉 ¡Se liberó la %s y ahora es tuya!', live_num(p_prenda)) || E'\n' || live_texto_cobro(c.id);
  end if;
  select telefono into v_tel from clientas where id = e.clienta_id;
  perform wa_encolar(v_tel, v_txt, e.clienta_id);
  return e.clienta_id;
end $$;

-- Liberar a mano una prenda apartada sin pagar (o quitar a alguien de la lista de espera)
create or replace function public.live_liberar_apartado(p_apartado uuid) returns void
language plpgsql set search_path = public as $$
declare
  a live_apartados;
  c live_cuentas;
begin
  select * into a from live_apartados where id = p_apartado for update;
  if not found then raise exception 'No existe ese apartado.'; end if;
  if a.estado = 'espera' then
    update live_apartados set estado = 'cancelada', actualizado_en = now() where id = a.id;
    return;
  end if;
  if a.estado <> 'apartada' then raise exception 'Solo se puede liberar una prenda apartada sin pagar.'; end if;

  perform 1 from prendas where numero = a.prenda for update;
  update live_apartados set estado = 'liberada', actualizado_en = now() where id = a.id;
  update prendas set estado = 'disponible', actualizada_en = now() where numero = a.prenda;
  perform live_recalcular(a.cuenta_id);
  select * into c from live_cuentas where id = a.cuenta_id;
  if c.piezas = 0 and c.estado in ('por_pagar', 'pago_incompleto') then
    update live_cuentas set estado = 'cancelada' where id = c.id;
  end if;
  perform live_ofrecer_espera(a.prenda);
end $$;

-- Cada minuto: recordatorios y liberación de lo no pagado
create or replace function public.live_revisar_vencimientos() returns jsonb
language plpgsql set search_path = public as $$
declare
  c live_cuentas;
  v_prenda integer;
  v_tel text;
  v_rec integer := 0;
  v_ven integer := 0;
  v_err integer := 0;
begin
  for c in select * from live_cuentas
            where estado in ('por_pagar', 'pago_incompleto') and recordado_en is null
              and recordatorio_en <= now() and liberar_en > now() loop
    begin
      select telefono into v_tel from clientas where id = c.clienta_id;
      if c.estado = 'pago_incompleto' then
        perform wa_encolar(v_tel, format('⏰ Recordatorio: te faltan %s para completar tu pago (folio %s).',
          live_dinero(c.total - c.monto_pagado), live_folio(c.folio)), c.clienta_id);
      else
        perform wa_encolar(v_tel, '⏰ Recordatorio' || E'\n' || live_texto_cobro(c.id), c.clienta_id);
      end if;
      update live_cuentas set recordado_en = now() where id = c.id;
      v_rec := v_rec + 1;
    exception when others then
      v_err := v_err + 1;
      raise warning 'Recordatorio de la cuenta %: %', c.id, sqlerrm;
    end;
  end loop;

  -- Solo se liberan solas las que no pagaron nada; un pago incompleto lo revisa una persona
  for c in select * from live_cuentas where estado = 'por_pagar' and liberar_en <= now() loop
    begin
      perform 1 from live_cuentas where id = c.id and estado = 'por_pagar' for update;
      if not found then continue; end if;
      update live_cuentas set estado = 'vencida', vencida_en = now() where id = c.id;
      update live_apartados set estado = 'liberada', actualizado_en = now()
       where cuenta_id = c.id and estado = 'apartada';
      update prendas p set estado = 'disponible', actualizada_en = now()
        from live_apartados a
       where a.cuenta_id = c.id and a.estado = 'liberada' and p.numero = a.prenda and p.estado = 'apartada';
      select telefono into v_tel from clientas where id = c.clienta_id;
      perform wa_encolar(v_tel, 'Tu apartado venció y las prendas se liberaron para otras clientas. ¡Te esperamos en el próximo live! 💕', c.clienta_id);
      for v_prenda in select prenda from live_apartados where cuenta_id = c.id and estado = 'liberada' order by prenda loop
        perform live_ofrecer_espera(v_prenda);
      end loop;
      v_ven := v_ven + 1;
    exception when others then
      v_err := v_err + 1;
      raise warning 'Vencimiento de la cuenta %: %', c.id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object('recordatorios', v_rec, 'vencidas', v_ven, 'errores', v_err);
end $$;

-- Registrar etiquetas nuevas por rango (por ejemplo 3001 a 3200)
create or replace function public.live_registrar_prendas(
  p_desde integer, p_hasta integer, p_precio numeric default null, p_usuario text default null
) returns integer language plpgsql set search_path = public as $$
declare
  v_n integer;
  v_precio numeric;
begin
  if p_desde is null or p_hasta is null or p_desde < 1 or p_hasta < p_desde or p_hasta > 99999 then
    raise exception 'Rango inválido: usa números del 1 al 99999, el primero menor o igual al segundo.';
  end if;
  if p_hasta - p_desde >= 5000 then
    raise exception 'Registra como máximo 5,000 prendas a la vez.';
  end if;
  select coalesce(p_precio, precio) into v_precio from live_config limit 1;
  insert into prendas (numero, precio, registrada_por)
  select g, v_precio, p_usuario from generate_series(p_desde, p_hasta) g
  on conflict (numero) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Borra todo lo que generó el simulador (teléfonos que empiezan con 00)
create or replace function public.live_borrar_simulacion() returns jsonb
language plpgsql set search_path = public as $$
declare
  v_cl uuid[];
  v_pr integer[];
  v_lives uuid[];
  v_ped integer;
begin
  select coalesce(array_agg(id), '{}') into v_cl from clientas where telefono like '00%';
  select coalesce(array_agg(distinct prenda), '{}') into v_pr
    from live_apartados where clienta_id = any (v_cl) and estado in ('apartada', 'pagada');
  select coalesce(array_agg(distinct live_id), '{}') into v_lives
    from (select live_id from live_apartados where clienta_id = any (v_cl)
          union select live_id from live_cuentas where clienta_id = any (v_cl)) s;

  delete from live_apartados where clienta_id = any (v_cl);
  delete from live_cuentas where clienta_id = any (v_cl);
  delete from pedidos where clienta_id = any (v_cl);
  get diagnostics v_ped = row_count;
  delete from asignaciones where clienta_id = any (v_cl);
  delete from wa_mensajes where telefono like '00%';
  delete from clientas where id = any (v_cl);

  update prendas p set estado = 'disponible', actualizada_en = now()
   where p.numero = any (v_pr)
     and not exists (select 1 from live_apartados a where a.prenda = p.numero and a.estado in ('apartada', 'pagada'));
  delete from lives l
   where l.id = any (v_lives) and l.estado = 'cerrado'
     and not exists (select 1 from live_apartados a where a.live_id = l.id)
     and not exists (select 1 from live_cuentas c where c.live_id = l.id);

  return jsonb_build_object('clientas', cardinality(v_cl), 'prendas', cardinality(v_pr), 'pedidos', v_ped);
end $$;

-- ---------------------------------------------------------------------
-- 8. Vistas para el panel (respetan la seguridad de quien consulta)
-- ---------------------------------------------------------------------
create or replace view public.live_tablero with (security_invoker = true) as
select c.*,
       live_folio(c.folio) as folio_txt,
       trim(cl.nombre || coalesce(' ' || cl.apellidos, '')) as clienta,
       cl.telefono,
       (select coalesce(array_agg(a.prenda order by a.prenda), '{}')
          from live_apartados a where a.cuenta_id = c.id and a.estado in ('apartada', 'pagada')) as prendas,
       l.estado as live_estado,
       l.iniciado_en as live_inicio
  from live_cuentas c
  join clientas cl on cl.id = c.clienta_id
  join lives l on l.id = c.live_id;

create or replace view public.live_feed with (security_invoker = true) as
select a.*,
       trim(cl.nombre || coalesce(' ' || cl.apellidos, '')) as clienta,
       cl.telefono,
       c.casillero,
       c.folio
  from live_apartados a
  join clientas cl on cl.id = a.clienta_id
  left join live_cuentas c on c.id = a.cuenta_id;

revoke all on public.live_tablero, public.live_feed from anon;
grant select on public.live_tablero, public.live_feed to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 9. Permisos de las funciones: solo el equipo y el servidor
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and (p.proname like 'live\_%' or p.proname in ('bot_mensaje', 'wa_encolar')) loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 10. Tarea automática cada minuto (recordatorios y liberaciones)
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('live-vencimientos', '* * * * *', 'select public.live_revisar_vencimientos()');
  else
    raise notice 'pg_cron no está disponible: live_revisar_vencimientos() hay que llamarla de otra forma.';
  end if;
end $$;
