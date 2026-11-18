-- =====================================================================
-- Nivel "Resurtido": quien repone en la sala las prendas que ya se vendieron.
--
--  - Una prenda cuenta como vendida cuando su pago queda completo (apartado "pagada").
--  - Por resurtir = prendas pagadas (sin las de prueba) − prendas ya resurtidas.
--  - Este nivel NO ve clientas, pagos, casilleros ni el live: solo el número por
--    reponer, lo que se vendió por live y su propio historial, todo por funciones.
--  - Le llega un aviso "🧺 Van N prendas por resurtir" cada vez que se completa un pago,
--    y ningún otro aviso (eso lo decide la función `avisos`).
--  - Por ahora hay una sola sala ("Sala 1"); la tabla ya guarda la sala para cuando haya más.
-- =====================================================================

alter table public.equipo drop constraint if exists equipo_rol_check;
alter table public.equipo add constraint equipo_rol_check
  check (rol in ('duena', 'supervisor', 'operacion', 'live', 'presentadora', 'resurtido'));

alter table public.equipo_invitaciones drop constraint if exists equipo_invitaciones_rol_check;
alter table public.equipo_invitaciones add constraint equipo_invitaciones_rol_check
  check (rol in ('supervisor', 'operacion', 'live', 'presentadora', 'resurtido'));

-- Ver datos del negocio: todos menos la presentadora y resurtido
create or replace function public.puede_ver() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from equipo where usuario_id = auth.uid() and rol not in ('presentadora', 'resurtido'))
$$;

create or replace function public.puede_resurtir() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion', 'resurtido'))
$$;

create or replace function public.equipo_asignar(p_usuario uuid, p_rol text) returns void
language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  if not es_duena() then raise exception 'Solo una dueña puede cambiar los accesos.'; end if;
  select email into v_email from auth.users where id = p_usuario;
  if not found then raise exception 'No existe ese usuario.'; end if;
  if p_rol is null then
    delete from equipo where usuario_id = p_usuario;
  elsif p_rol in ('duena', 'supervisor', 'operacion', 'live', 'presentadora', 'resurtido') then
    insert into equipo (usuario_id, email, rol, asignado_por)
    values (p_usuario, v_email, p_rol, (select email from auth.users where id = auth.uid()))
    on conflict (usuario_id) do update
      set rol = excluded.rol, email = excluded.email, asignado_por = excluded.asignado_por, actualizado_en = now();
  else
    raise exception 'Nivel inválido.';
  end if;
end $$;

-- Cada vez que alguien repone prendas en la sala
create table if not exists public.resurtidos (
  id uuid primary key default gen_random_uuid(),
  sala text not null default 'Sala 1',
  prendas integer not null check (prendas > 0),
  hecho_por text,
  hecho_en timestamptz not null default now()
);
alter table public.resurtidos enable row level security;   -- sin políticas: solo se usa por funciones

-- Prendas pagadas de clientas reales que todavía no se reponen
create or replace function public.resurtido_pendientes() returns integer
language sql stable security definer set search_path = public as $$
  select greatest(
    (select count(*) from live_apartados a left join clientas cl on cl.id = a.clienta_id
      where a.estado = 'pagada' and (cl.telefono is null or cl.telefono not like '00%'))
    - (select coalesce(sum(prendas), 0) from resurtidos), 0)::integer
$$;

create or replace function public.resurtido_estado() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid()
                  and rol in ('duena', 'supervisor', 'operacion', 'resurtido')) then
    raise exception 'Tu nivel de acceso no permite ver el resurtido.';
  end if;
  return jsonb_build_object(
    'sala', 'Sala 1',
    'pendientes', resurtido_pendientes(),
    'de_prueba', (select count(*) from live_apartados a join clientas cl on cl.id = a.clienta_id
                   where a.estado = 'pagada' and cl.telefono like '00%'),
    'puede_marcar', puede_resurtir(),
    'por_live', (select coalesce(jsonb_agg(jsonb_build_object('titulo', x.titulo, 'fecha', x.iniciado_en, 'prendas', x.prendas)
                                           order by x.iniciado_en desc), '[]'::jsonb)
                   from (select l.id, l.titulo, l.iniciado_en, count(*) as prendas
                           from live_apartados a
                           join lives l on l.id = a.live_id
                           left join clientas cl on cl.id = a.clienta_id
                          where a.estado = 'pagada' and (cl.telefono is null or cl.telefono not like '00%')
                          group by l.id, l.titulo, l.iniciado_en
                          order by l.iniciado_en desc limit 5) x),
    'historial', (select coalesce(jsonb_agg(jsonb_build_object('prendas', x.prendas, 'hecho_en', x.hecho_en, 'hecho_por', x.hecho_por, 'sala', x.sala)
                                            order by x.hecho_en desc), '[]'::jsonb)
                    from (select * from resurtidos order by hecho_en desc limit 8) x));
end $$;

-- p_prendas vacío = se repuso todo lo pendiente
create or replace function public.resurtido_marcar(p_prendas integer default null, p_usuario text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_pend integer;
  v_n integer;
begin
  if not puede_resurtir() then raise exception 'Tu nivel de acceso no permite marcar el resurtido.'; end if;
  perform pg_advisory_xact_lock(hashtext('resurtido'));
  v_pend := resurtido_pendientes();
  if v_pend <= 0 then raise exception 'No hay prendas por resurtir.'; end if;
  v_n := coalesce(p_prendas, v_pend);
  if v_n < 1 or v_n > v_pend then raise exception 'Escribe un número entre 1 y %.', v_pend; end if;
  insert into resurtidos (prendas, hecho_por)
  values (v_n, coalesce(nullif(trim(p_usuario), ''), (select email from auth.users where id = auth.uid())));
  return jsonb_build_object('resurtidas', v_n, 'pendientes', v_pend - v_n);
end $$;

-- Aviso al nivel resurtido cuando un pago queda completo
create or replace function public.avisos_resurtido() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  c live_cuentas;
  v_n integer;
  v_prueba boolean;
begin
  select * into c from live_cuentas where id = new.id;
  if not found or c.estado <> 'pagada' then return null; end if;
  select count(*) into v_n from live_apartados where cuenta_id = c.id and estado = 'pagada';
  if v_n = 0 then return null; end if;
  select coalesce(telefono like '00%', false) into v_prueba from clientas where id = c.clienta_id;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('resurtido', 'resurtir:' || c.id,
          case when coalesce(v_prueba, false)
               then format('🧺 Pago de prueba: %s %s (prueba)', v_n, case when v_n = 1 then 'prenda' else 'prendas' end)
               else format('🧺 Van %s %s por resurtir', resurtido_pendientes(),
                           case when resurtido_pendientes() = 1 then 'prenda' else 'prendas' end) end,
          case when coalesce(v_prueba, false) then 'Es un ensayo: no hay que reponer nada.'
               else format('Se %s %s más. Sala 1.', case when v_n = 1 then 'acaba de pagar' else 'acaban de pagar' end, v_n) end,
          'live.html#resurtir', 'resurtido')
  on conflict (clave) do nothing;
  return null;
end $$;

drop trigger if exists avisos_resurtido on public.live_cuentas;
create constraint trigger avisos_resurtido after update of estado on public.live_cuentas
  deferrable initially deferred for each row
  when (old.estado is distinct from new.estado and new.estado = 'pagada')
  execute function public.avisos_resurtido();

-- Aviso de prueba y resumen de avisos según el nivel
create or replace function public.avisos_prueba() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not es_del_equipo() then raise exception 'Tu cuenta todavía no tiene nivel de acceso.'; end if;
  insert into avisos (tipo, titulo, cuerpo, url, usuario_id)
  values ('prueba', '🔔 Avisos activados',
          case mi_rol()
            when 'presentadora' then 'Así te llegará a quién pedirle DM durante el live.'
            when 'live' then 'Así te llegará cada prenda que hay que llevar a su casillero o regresar al rack.'
            when 'resurtido' then 'Así te llegará cuántas prendas hay que reponer en la sala.'
            else 'Así te llegarán los pagos, vencimientos y cajas listas.' end,
          case mi_rol() when 'presentadora' then 'live.html#dm' when 'live' then 'live.html#acomodo'
                        when 'resurtido' then 'live.html#resurtir' else 'live.html#ajustes' end,
          auth.uid());
end $$;

create or replace function public.avisos_resumen() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_rol text := mi_rol();
begin
  if not es_del_equipo() then return null; end if;
  if v_rol in ('presentadora', 'resurtido') then
    return jsonb_build_object(
      'dispositivos', (select count(*) from avisos_dispositivos where activo and usuario_id = auth.uid()),
      'nombres', (select coalesce(jsonb_agg(nombre order by creado_en), '[]'::jsonb) from avisos_dispositivos where activo and usuario_id = auth.uid()),
      'ultimos', (select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'cuerpo', cuerpo, 'creado_en', creado_en, 'enviados', enviados, 'enviado', enviado_en is not null) order by creado_en desc), '[]'::jsonb)
                    from (select * from avisos where para_rol = v_rol order by creado_en desc limit 5) x));
  end if;
  return jsonb_build_object(
    'dispositivos', (select count(*) from avisos_dispositivos where activo),
    'nombres', (select coalesce(jsonb_agg(nombre order by creado_en), '[]'::jsonb) from avisos_dispositivos where activo),
    'ultimos', (select coalesce(jsonb_agg(jsonb_build_object('titulo', titulo, 'cuerpo', cuerpo, 'creado_en', creado_en, 'enviados', enviados, 'enviado', enviado_en is not null) order by creado_en desc), '[]'::jsonb)
                  from (select * from avisos where usuario_id is null and para_rol is null order by creado_en desc limit 5) x));
end $$;

revoke all on function public.puede_resurtir(), public.resurtido_pendientes(), public.resurtido_estado(),
  public.resurtido_marcar(integer, text), public.avisos_resurtido() from public, anon;
grant execute on function public.puede_resurtir(), public.resurtido_estado(), public.resurtido_marcar(integer, text)
  to authenticated, service_role;
grant execute on function public.resurtido_pendientes() to service_role;
revoke execute on function public.resurtido_pendientes(), public.avisos_resurtido() from authenticated;
