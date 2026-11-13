-- =====================================================================
-- Niveles de acceso del equipo
--
--   dueña       → todo: pagos, CLABE y precios, Prime Live (programar e invitar), borrar, dar accesos.
--   supervisor  → monitor: ve todo y recibe avisos, pero no puede cambiar nada.
--   operación   → opera el live (iniciar, cerrar, capturar, liberar) y mueve prendas;
--                 no registra pagos, no toca ajustes, no invita mayoristas y no borra.
--
-- Quien tenga usuario en Supabase pero no esté en el equipo NO ve nada hasta que una dueña
-- le asigne nivel. Las cuentas que ya existen quedan como dueñas.
-- Las reglas viven en la base de datos: esconder botones es solo comodidad.
-- Pagos, cambios de ajustes, borrados y cambios de nivel quedan en la bitácora.
--
-- Requiere las migraciones anteriores (lives, Prime Live y avisos). No borra datos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. El equipo y su nivel
-- ---------------------------------------------------------------------
create table if not exists public.equipo (
  usuario_id uuid primary key references auth.users (id) on delete cascade,
  email text,
  rol text not null check (rol in ('duena', 'supervisor', 'operacion')),
  asignado_por text,
  actualizado_en timestamptz not null default now()
);

-- Las cuentas que ya existen son de las dueñas
insert into public.equipo (usuario_id, email, rol, asignado_por)
select id, email, 'duena', 'instalación' from auth.users
on conflict (usuario_id) do nothing;

create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select rol from equipo where usuario_id = auth.uid()
$$;
create or replace function public.puede_ver() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from equipo where usuario_id = auth.uid())
$$;
create or replace function public.puede_operar() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion'))
$$;
create or replace function public.es_duena() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from equipo where usuario_id = auth.uid() and rol = 'duena')
$$;

-- Siempre debe quedar al menos una dueña
create or replace function public.equipo_una_duena() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from equipo where rol = 'duena') then
    raise exception 'Debe quedar al menos una dueña en el equipo.';
  end if;
  return null;
end $$;
drop trigger if exists equipo_una_duena on public.equipo;
create constraint trigger equipo_una_duena after update or delete on public.equipo
  deferrable initially deferred for each row execute function public.equipo_una_duena();

-- ---------------------------------------------------------------------
-- 2. Bitácora: quién hizo qué y cuándo
-- ---------------------------------------------------------------------
create table if not exists public.bitacora (
  id bigint generated always as identity primary key,
  creado_en timestamptz not null default now(),
  usuario_id uuid,
  usuario text,
  accion text not null,
  detalle jsonb
);
create index if not exists bitacora_fecha on public.bitacora (creado_en desc);

create or replace function public.bitacora_anotar(p_accion text, p_detalle jsonb) returns void
language sql security definer set search_path = public as $$
  insert into bitacora (usuario_id, usuario, accion, detalle)
  values (auth.uid(),
          coalesce((select email from auth.users where id = auth.uid()),
                   case when auth.uid() is null then 'sistema' end),
          p_accion, p_detalle)
$$;

-- Pagos y pagos incompletos
create or replace function public.bitacora_pagos() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform bitacora_anotar(case when new.estado = 'pagada' then 'pago registrado' else 'pago incompleto' end,
    jsonb_build_object('folio', live_folio(new.folio), 'total', new.total, 'monto_pagado', new.monto_pagado,
                       'referencia', new.proveedor_ref, 'caja', new.caja));
  return null;
end $$;
drop trigger if exists bitacora_pagos on public.live_cuentas;
create trigger bitacora_pagos after update of estado on public.live_cuentas
  for each row when (old.estado is distinct from new.estado and new.estado in ('pagada', 'pago_incompleto'))
  execute function public.bitacora_pagos();

-- Cambios de ajustes (CLABE, precios, tiempos) y de categorías/precios de Cajas
create or replace function public.bitacora_cambios() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  antes jsonb := to_jsonb(old);
  despues jsonb := to_jsonb(new);
  dif jsonb := '{}'::jsonb;
  k text;
begin
  for k in select jsonb_object_keys(despues) loop
    if k not in ('actualizado_en') and antes -> k is distinct from despues -> k then
      dif := dif || jsonb_build_object(k, jsonb_build_object('antes', antes -> k, 'despues', despues -> k));
    end if;
  end loop;
  if dif <> '{}'::jsonb then
    perform bitacora_anotar('cambio en ' || tg_table_name, dif);
  end if;
  return null;
end $$;
drop trigger if exists bitacora_cambios on public.live_config;
create trigger bitacora_cambios after update on public.live_config for each row execute function public.bitacora_cambios();
drop trigger if exists bitacora_cambios on public.categorias;
create trigger bitacora_cambios after update on public.categorias for each row execute function public.bitacora_cambios();

-- Borrados (sin anotar lo que borra el simulador: teléfonos que empiezan con 00)
create or replace function public.bitacora_borrados() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  fila jsonb := to_jsonb(old);
  v_cl uuid;
begin
  v_cl := nullif(fila ->> 'clienta_id', '')::uuid;
  if tg_table_name = 'clientas' and coalesce(fila ->> 'telefono', '') like '00%' then return null; end if;
  if v_cl is not null and exists (select 1 from clientas where id = v_cl and telefono like '00%') then return null; end if;
  perform bitacora_anotar('borrado en ' || tg_table_name, fila);
  return null;
end $$;
do $$
declare t text;
begin
  foreach t in array array['clientas', 'pedidos', 'asignaciones', 'cajas', 'categorias', 'prendas', 'prime_prendas'] loop
    execute format('drop trigger if exists bitacora_borrados on public.%I', t);
    execute format('create trigger bitacora_borrados after delete on public.%I for each row execute function public.bitacora_borrados()', t);
  end loop;
end $$;

-- Cambios de nivel
create or replace function public.bitacora_equipo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform bitacora_anotar(case tg_op when 'DELETE' then 'acceso quitado' else 'nivel asignado' end,
    jsonb_build_object('email', coalesce(new.email, old.email), 'antes', case when tg_op <> 'INSERT' then old.rol end,
                       'despues', case when tg_op <> 'DELETE' then new.rol end));
  return null;
end $$;
drop trigger if exists bitacora_equipo on public.equipo;
create trigger bitacora_equipo after insert or update or delete on public.equipo
  for each row execute function public.bitacora_equipo();

-- ---------------------------------------------------------------------
-- 3. Candados que no dependen de la tabla
-- ---------------------------------------------------------------------
-- Solo una dueña registra pagos (el sistema y el futuro proveedor de CLABE sí pueden)
create or replace function public.candado_pagos() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not es_duena() and
     (new.monto_pagado is distinct from old.monto_pagado
      or (new.estado is distinct from old.estado and new.estado in ('pagada', 'pago_incompleto'))) then
    raise exception 'Solo una dueña puede registrar pagos.';
  end if;
  return new;
end $$;
drop trigger if exists candado_pagos on public.live_cuentas;
create trigger candado_pagos before update on public.live_cuentas for each row execute function public.candado_pagos();

-- Solo una dueña programa un Prime Live
create or replace function public.candado_prime() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.tipo = 'prime' and auth.uid() is not null and not es_duena() then
    raise exception 'Solo una dueña puede programar un Prime Live.';
  end if;
  return new;
end $$;
drop trigger if exists candado_prime on public.lives;
create trigger candado_prime before insert on public.lives for each row execute function public.candado_prime();

-- ---------------------------------------------------------------------
-- 4. Reglas por tabla
--    ver: cualquier nivel · crear/cambiar: dueña u operación (o solo dueña) · borrar: dueña
-- ---------------------------------------------------------------------
do $$
declare
  t text;
  p record;
  operan text[] := array['clientas', 'asignaciones', 'pedidos', 'prendas', 'lives', 'casilleros',
                         'live_cuentas', 'live_apartados', 'wa_mensajes', 'prime_prendas'];
  solo_duena text[] := array['cajas', 'categorias', 'live_config', 'prime_invitaciones'];
begin
  foreach t in array operan || solo_duena loop
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
    if t = 'prime_invitaciones' then
      -- Las contraseñas de las mayoristas solo las ven las dueñas
      execute format('create policy ver on public.%I for select to authenticated using ((select public.es_duena()))', t);
    else
      execute format('create policy ver on public.%I for select to authenticated using ((select public.puede_ver()))', t);
    end if;
    if t = any (operan) then
      execute format('create policy crear on public.%I for insert to authenticated with check ((select public.puede_operar()))', t);
      execute format('create policy cambiar on public.%I for update to authenticated using ((select public.puede_operar())) with check ((select public.puede_operar()))', t);
    else
      execute format('create policy crear on public.%I for insert to authenticated with check ((select public.es_duena()))', t);
      execute format('create policy cambiar on public.%I for update to authenticated using ((select public.es_duena())) with check ((select public.es_duena()))', t);
    end if;
    execute format('create policy borrar on public.%I for delete to authenticated using ((select public.es_duena()))', t);
  end loop;
end $$;

-- Equipo y bitácora
alter table public.equipo enable row level security;
alter table public.bitacora enable row level security;
drop policy if exists ver on public.equipo;
create policy ver on public.equipo for select to authenticated using ((select public.puede_ver()));
drop policy if exists ver on public.bitacora;
create policy ver on public.bitacora for select to authenticated using ((select public.es_duena()));
revoke all on public.equipo, public.bitacora from anon;
revoke insert, update, delete on public.equipo, public.bitacora from authenticated;
grant select on public.equipo, public.bitacora to authenticated;
grant all on public.equipo, public.bitacora to service_role;

-- Avisos: solo quien es del equipo
drop policy if exists equipo_lee on public.avisos;
drop policy if exists ver on public.avisos;
create policy ver on public.avisos for select to authenticated using ((select public.puede_ver()));
drop policy if exists propio on public.avisos_dispositivos;
create policy propio on public.avisos_dispositivos for all to authenticated
  using (usuario_id = auth.uid() and (select public.puede_ver()))
  with check (usuario_id = auth.uid() and (select public.puede_ver()));

-- Archivos de Cajas (fotos de guías y videos) y fotos de Prime Live
drop policy if exists "equipo lee archivos" on storage.objects;
create policy "equipo lee archivos" on storage.objects for select to authenticated
  using (bucket_id = 'archivos' and (select public.puede_ver()));
drop policy if exists "equipo sube archivos" on storage.objects;
create policy "equipo sube archivos" on storage.objects for insert to authenticated
  with check (bucket_id = 'archivos' and (select public.puede_operar()));
drop policy if exists "equipo cambia archivos" on storage.objects;
create policy "equipo cambia archivos" on storage.objects for update to authenticated
  using (bucket_id = 'archivos' and (select public.puede_operar()));
drop policy if exists "equipo borra archivos" on storage.objects;
create policy "equipo borra archivos" on storage.objects for delete to authenticated
  using (bucket_id = 'archivos' and (select public.es_duena()));
drop policy if exists "equipo sube fotos prime" on storage.objects;
create policy "equipo sube fotos prime" on storage.objects for insert to authenticated
  with check (bucket_id = 'prime' and (select public.puede_operar()));
drop policy if exists "equipo cambia fotos prime" on storage.objects;
create policy "equipo cambia fotos prime" on storage.objects for update to authenticated
  using (bucket_id = 'prime' and (select public.puede_operar()));
drop policy if exists "equipo borra fotos prime" on storage.objects;
create policy "equipo borra fotos prime" on storage.objects for delete to authenticated
  using (bucket_id = 'prime' and (select public.es_duena()));

-- ---------------------------------------------------------------------
-- 5. Administrar el equipo desde el panel (solo dueñas)
-- ---------------------------------------------------------------------
-- Lista a todas las personas con usuario en Supabase, tengan o no nivel
create or replace function public.equipo_listar() returns table (
  usuario_id uuid, email text, rol text, creado_en timestamptz, ultimo_ingreso timestamptz
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not es_duena() then raise exception 'Solo una dueña puede ver y cambiar los accesos.'; end if;
  return query
    select u.id, u.email::text, e.rol, u.created_at, u.last_sign_in_at
      from auth.users u left join equipo e on e.usuario_id = u.id
     order by (e.rol is null) desc, u.created_at;
end $$;

-- p_rol: 'duena', 'supervisor', 'operacion' o null para quitar el acceso
create or replace function public.equipo_asignar(p_usuario uuid, p_rol text) returns void
language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  if not es_duena() then raise exception 'Solo una dueña puede cambiar los accesos.'; end if;
  select email into v_email from auth.users where id = p_usuario;
  if not found then raise exception 'No existe ese usuario.'; end if;
  if p_rol is null then
    delete from equipo where usuario_id = p_usuario;
  elsif p_rol in ('duena', 'supervisor', 'operacion') then
    insert into equipo (usuario_id, email, rol, asignado_por)
    values (p_usuario, v_email, p_rol, (select email from auth.users where id = auth.uid()))
    on conflict (usuario_id) do update
      set rol = excluded.rol, email = excluded.email, asignado_por = excluded.asignado_por, actualizado_en = now();
  else
    raise exception 'Nivel inválido.';
  end if;
end $$;

-- Los avisos del panel también exigen ser del equipo
create or replace function public.avisos_prueba() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not puede_ver() then raise exception 'Tu cuenta todavía no tiene nivel de acceso.'; end if;
  insert into avisos (tipo, titulo, cuerpo, url, usuario_id)
  values ('prueba', '🔔 Avisos activados',
          'Así te llegarán los pagos, vencimientos y cajas listas.', 'live.html#ajustes', auth.uid());
end $$;

create or replace function public.avisos_resumen() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not puede_ver() then return null; end if;
  return jsonb_build_object(
    'dispositivos', (select count(*) from avisos_dispositivos where activo),
    'nombres', (select coalesce(jsonb_agg(nombre order by creado_en), '[]'::jsonb) from avisos_dispositivos where activo),
    'ultimos', (select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'cuerpo', cuerpo, 'creado_en', creado_en, 'enviados', enviados, 'enviado', enviado_en is not null) order by creado_en desc), '[]'::jsonb)
                  from (select * from avisos where usuario_id is null order by creado_en desc limit 5) x));
end $$;
revoke all on function public.avisos_prueba(), public.avisos_resumen() from public, anon;
grant execute on function public.avisos_prueba(), public.avisos_resumen() to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 6. Permisos de las funciones nuevas
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('mi_rol', 'puede_ver', 'puede_operar', 'es_duena', 'equipo_listar', 'equipo_asignar',
                                'equipo_una_duena', 'bitacora_anotar', 'bitacora_pagos', 'bitacora_cambios',
                                'bitacora_borrados', 'bitacora_equipo', 'candado_pagos', 'candado_prime') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
grant execute on function public.mi_rol(), public.puede_ver(), public.puede_operar(), public.es_duena(),
  public.equipo_listar(), public.equipo_asignar(uuid, text) to authenticated;
