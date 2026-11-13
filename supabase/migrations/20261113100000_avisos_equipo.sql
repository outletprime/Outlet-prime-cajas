-- =====================================================================
-- Avisos al celular del equipo (notificaciones push)
--
-- Eventos:
--   ✅ Pago recibido      → "Mover C-007 → caja B3 · piezas 0023, 0310"
--   ⚠️ Pago incompleto    → "Faltan $89 · revisar con la clienta"
--   ⏰ Apartado vencido   → "Regresar 0932 a racks"
--   📦 Caja lista         → a los 20 días (como Cajas) o al llegar a N prendas (si se configura)
--
-- Cómo funciona: la base crea un registro en "avisos" y llama a la Edge Function "avisos",
-- que cifra y manda la notificación a cada teléfono del equipo que la activó.
-- Las llaves de las notificaciones las genera y guarda la propia función: nadie las copia.
--
-- Requiere las migraciones del sistema de lives y de Prime Live. Solo agrega; no borra datos.
-- =====================================================================

alter table public.live_config add column if not exists dias_caja integer not null default 20;
alter table public.live_config add column if not exists caja_llena_prendas integer;
alter table public.live_config drop constraint if exists live_config_caja_llena_check;
alter table public.live_config add constraint live_config_caja_llena_check
  check ((caja_llena_prendas is null or caja_llena_prendas > 0) and dias_caja > 0);

-- Cada aviso que se manda (o se va a mandar)
create table if not exists public.avisos (
  id uuid primary key default gen_random_uuid(),
  tipo text not null,                  -- pago, incompleto, vencido, caja, prueba
  clave text unique,                   -- evita mandar el mismo aviso dos veces
  titulo text not null,
  cuerpo text not null,
  url text,
  usuario_id uuid,                     -- solo para esa persona (aviso de prueba)
  creado_en timestamptz not null default now(),
  enviado_en timestamptz,
  enviados integer not null default 0,
  error text
);
create index if not exists avisos_pendientes on public.avisos (creado_en) where enviado_en is null;

-- Teléfonos del equipo que activaron los avisos
create table if not exists public.avisos_dispositivos (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null default auth.uid(),
  nombre text,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  activo boolean not null default true,
  creado_en timestamptz not null default now(),
  ultimo_envio timestamptz,
  ultimo_error text
);

-- Configuración interna (llaves de notificaciones): solo la lee el servidor
create table if not exists public.avisos_config (
  id boolean primary key default true check (id),
  vapid_publica text,
  vapid_privada jsonb,
  funcion_url text,
  llave_anon text,
  actualizado_en timestamptz not null default now()
);
insert into public.avisos_config (id, funcion_url, llave_anon)
values (true,
        'https://fjafsvirllfuzrzonovy.supabase.co/functions/v1/avisos',
        -- llave pública "anon" del proyecto (la misma de config.js): solo sirve para llamar a la función
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZqYWZzdmlybGxmdXpyem9ub3Z5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQxMTM5NzEsImV4cCI6MjEwOTY4OTk3MX0.rN7gVhHbiy3T0mSStHKPWzUH1YD9qoTv9VYmUAbDYJI')
on conflict (id) do nothing;

alter table public.avisos enable row level security;
alter table public.avisos_dispositivos enable row level security;
alter table public.avisos_config enable row level security;   -- sin reglas: nadie fuera del servidor la ve

drop policy if exists equipo_lee on public.avisos;
create policy equipo_lee on public.avisos for select to authenticated using (true);
drop policy if exists propio on public.avisos_dispositivos;
create policy propio on public.avisos_dispositivos for all to authenticated
  using (usuario_id = auth.uid()) with check (usuario_id = auth.uid());

revoke all on public.avisos, public.avisos_dispositivos, public.avisos_config from anon;
revoke all on public.avisos_config from authenticated;
grant select on public.avisos to authenticated;
grant select, insert, update, delete on public.avisos_dispositivos to authenticated;
grant select, insert, update, delete on public.avisos, public.avisos_dispositivos, public.avisos_config to service_role;

-- ---------------------------------------------------------------------
-- Crear avisos
-- ---------------------------------------------------------------------
create or replace function public.avisos_encolar(
  p_tipo text, p_clave text, p_titulo text, p_cuerpo text, p_url text default null, p_usuario uuid default null
) returns void
language sql security definer set search_path = public as $$
  insert into avisos (tipo, clave, titulo, cuerpo, url, usuario_id)
  values (p_tipo, p_clave, p_titulo, p_cuerpo, p_url, p_usuario)
  on conflict (clave) do nothing
$$;

-- Cuando un cobro cambia de estado. Se revisa al final de la operación,
-- para que el aviso ya traiga la caja asignada.
create or replace function public.avisos_por_cuenta() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  c live_cuentas;
  v_nombre text;
  v_piezas text;
begin
  select * into c from live_cuentas where id = new.id;
  if not found or c.estado is distinct from new.estado then
    return null;  -- en la misma operación pasó a otro estado: avisa ese otro
  end if;
  select trim(nombre || coalesce(' ' || apellidos, '')) into v_nombre from clientas where id = c.clienta_id;

  if c.estado = 'pagada' then
    v_piezas := live_unir(live_etiquetas(c.id, array['pagada']));
    perform avisos_encolar('pago', 'pago:' || c.id,
      format('✅ Pagado %s · %s', live_folio(c.folio), v_nombre),
      case when c.caja is null
           then format('Sin caja libre: crea más cajas en Cajas · piezas %s', v_piezas)
           else format('Mover %s → caja %s · piezas %s', coalesce(c.casillero, 'sus prendas'), c.caja, v_piezas) end,
      'live.html#casilleros');
  elsif c.estado = 'pago_incompleto' then
    perform avisos_encolar('incompleto', 'incompleto:' || c.id || ':' || c.monto_pagado,
      format('⚠️ Pago incompleto %s · %s', live_folio(c.folio), v_nombre),
      format('Pagó %s de %s · faltan %s. Revisar con la clienta.',
             live_dinero(c.monto_pagado), live_dinero(c.total), live_dinero(c.total - c.monto_pagado)),
      'live.html#casilleros');
  elsif c.estado = 'vencida' then
    v_piezas := nullif(live_unir(live_etiquetas(c.id, array['liberada'])), '');
    perform avisos_encolar('vencido', 'vencido:' || c.id,
      format('⏰ Sin pago · %s · %s', coalesce(c.casillero, 'sin casillero'), v_nombre),
      format('Regresar %s a racks (%s)', coalesce(v_piezas, 'las prendas'), live_folio(c.folio)),
      'live.html#casilleros');
  end if;
  return null;
end $$;

drop trigger if exists avisos_por_cuenta on public.live_cuentas;
create constraint trigger avisos_por_cuenta
  after update of estado on public.live_cuentas
  deferrable initially deferred
  for each row when (old.estado is distinct from new.estado)
  execute function public.avisos_por_cuenta();

-- Cajas listas para empacar: por días (como Cajas) o por número de prendas (si se configura)
create or replace function public.avisos_revisar_cajas() returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_cfg live_config;
  n integer := 0;
  m integer := 0;
begin
  select * into v_cfg from live_config limit 1;

  insert into avisos (tipo, clave, titulo, cuerpo, url)
  select 'caja', 'caja-dias:' || a.id,
         format('📦 Caja %s · %s', a.caja, trim(cl.nombre || coalesce(' ' || cl.apellidos, ''))),
         format('Cumplió %s días: lista para empacar (%s %s)', d.dias, d.prendas, case when d.prendas = 1 then 'prenda' else 'prendas' end),
         'index.html#/caja/' || a.caja
    from asignaciones a
    join clientas cl on cl.id = a.clienta_id
    cross join lateral (
      select ((now() at time zone v_cfg.zona_horaria)::date - (a.asignada_en at time zone v_cfg.zona_horaria)::date) as dias,
             coalesce((select sum(p.prendas) from pedidos p where p.asignacion_id = a.id), 0) as prendas) d
   where a.estado = 'activa' and d.dias >= v_cfg.dias_caja
  on conflict (clave) do nothing;
  get diagnostics n = row_count;

  if v_cfg.caja_llena_prendas is not null then
    insert into avisos (tipo, clave, titulo, cuerpo, url)
    select 'caja', 'caja-llena:' || a.id,
           format('📦 Caja %s llena · %s', a.caja, trim(cl.nombre || coalesce(' ' || cl.apellidos, ''))),
           format('Tiene %s %s: lista para empacar', d.prendas, case when d.prendas = 1 then 'prenda' else 'prendas' end),
           'index.html#/caja/' || a.caja
      from asignaciones a
      join clientas cl on cl.id = a.clienta_id
      cross join lateral (select coalesce((select sum(p.prendas) from pedidos p where p.asignacion_id = a.id), 0) as prendas) d
     where a.estado = 'activa' and d.prendas >= v_cfg.caja_llena_prendas
    on conflict (clave) do nothing;
    get diagnostics m = row_count;
  end if;
  return n + m;
end $$;

-- ---------------------------------------------------------------------
-- Mandar: la base llama a la función "avisos" en cuanto hay algo nuevo
-- (y cada minuto revisa si quedó algo pendiente)
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
  else
    raise notice 'pg_net no está disponible: los avisos se mandarán al llamar a la función.';
  end if;
end $$;

create or replace function public.avisos_disparar() returns void
language plpgsql security definer set search_path = public as $$
declare v avisos_config;
begin
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then return; end if;
  select * into v from avisos_config limit 1;
  if v.funcion_url is null then return; end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3)'
    using v.funcion_url, '{}'::jsonb,
          jsonb_build_object('Content-Type', 'application/json',
                             'Authorization', 'Bearer ' || v.llave_anon,
                             'apikey', v.llave_anon);
end $$;

create or replace function public.avisos_tras_insertar() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform avisos_disparar();
  return null;
end $$;

drop trigger if exists avisos_tras_insertar on public.avisos;
create trigger avisos_tras_insertar after insert on public.avisos
  for each statement execute function public.avisos_tras_insertar();

create or replace function public.avisos_pendientes() returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from avisos where enviado_en is null and creado_en > now() - interval '1 day') then
    perform avisos_disparar();
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Para el panel
-- ---------------------------------------------------------------------
create or replace function public.avisos_prueba() returns void
language sql security definer set search_path = public as $$
  insert into avisos (tipo, titulo, cuerpo, url, usuario_id)
  values ('prueba', '🔔 Avisos activados',
          'Así te llegarán los pagos, vencimientos y cajas listas.', 'live.html#ajustes', auth.uid())
$$;

create or replace function public.avisos_resumen() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'dispositivos', (select count(*) from avisos_dispositivos where activo),
    'nombres', (select coalesce(jsonb_agg(nombre order by creado_en), '[]'::jsonb) from avisos_dispositivos where activo),
    'ultimos', (select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'cuerpo', cuerpo, 'creado_en', creado_en, 'enviados', enviados, 'enviado', enviado_en is not null) order by creado_en desc), '[]'::jsonb)
                  from (select * from avisos where usuario_id is null order by creado_en desc limit 5) x))
$$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'avisos\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
grant execute on function public.avisos_prueba() to authenticated;
grant execute on function public.avisos_resumen() to authenticated;

-- ---------------------------------------------------------------------
-- Tareas automáticas
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('avisos-pendientes', '* * * * *', 'select public.avisos_pendientes()');
    perform cron.schedule('avisos-cajas', '7 * * * *', 'select public.avisos_revisar_cajas()');
  else
    raise notice 'pg_cron no está disponible.';
  end if;
end $$;
