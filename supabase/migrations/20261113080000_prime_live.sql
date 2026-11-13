-- =====================================================================
-- Prime Live · lives exclusivos para clientas MAYORISTAS
--
-- - El equipo programa un Prime Live, elige a qué mayoristas invitar y el sistema
--   genera una contraseña única por mayorista, válida SOLO para ese live.
-- - Las mayoristas NO tienen usuario de Supabase: entran con su contraseña a prime.html,
--   que solo puede llamar a 3 funciones (acceso, estado, apartar) y solo ve lo suyo.
-- - Durante el live el equipo captura la foto de cada prenda; todas reciben el botón
--   "Apartar" al mismo tiempo y gana la primera.
-- - Cobro, casilleros, 3 horas para pagar y paso a la caja fija: lo mismo que en redes.
--
-- Requiere la migración 20261113060000_sistema_lives.sql. Solo agrega o ajusta;
-- no borra datos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Clientas mayoristas (misma tabla de clientas: una por WhatsApp)
-- ---------------------------------------------------------------------
alter table public.clientas add column if not exists mayorista boolean not null default false;

insert into public.categorias (id, nombre, precio, editable, activa, orden)
select 'prime', 'Prime Live', 89, false, true, coalesce(max(orden), 0) + 1 from public.categorias
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 2. Dos tipos de live: redes (bot de WhatsApp) y prime (mayoristas)
-- ---------------------------------------------------------------------
alter table public.lives add column if not exists tipo text not null default 'redes';
alter table public.lives add column if not exists programado_para timestamptz;
alter table public.lives add column if not exists precio numeric;
alter table public.lives add column if not exists limite integer;
alter table public.lives add column if not exists retraso integer not null default 2;
alter table public.lives add column if not exists video_url text;
alter table public.lives add column if not exists actual_prenda uuid;

alter table public.lives drop constraint if exists lives_estado_check;
alter table public.lives add constraint lives_estado_check check (estado in ('programado', 'activo', 'cerrado'));
alter table public.lives drop constraint if exists lives_tipo_check;
alter table public.lives add constraint lives_tipo_check check (tipo in ('redes', 'prime'));
drop index if exists public.lives_uno_activo;
create unique index if not exists lives_uno_activo_por_tipo on public.lives (tipo) where estado = 'activo';

alter table public.live_config add column if not exists prime_precio numeric not null default 89;
alter table public.live_config add column if not exists prime_limite integer default 3;
alter table public.live_config add column if not exists prime_retraso integer not null default 2;
alter table public.live_config add column if not exists prime_video_url text;

-- Prendas mostradas en un Prime Live (con su foto)
create table if not exists public.prime_prendas (
  id uuid primary key default gen_random_uuid(),
  live_id uuid not null references public.lives (id),
  num integer not null,
  foto text,
  precio numeric not null check (precio > 0),
  talla text,
  estado text not null default 'disponible' check (estado in ('disponible', 'apartada', 'pagada', 'quitada')),
  disponible_en timestamptz not null default now(),
  creada_en timestamptz not null default now(),
  creada_por text,
  unique (live_id, num)
);

-- Un apartado ahora puede ser de una etiqueta (redes) o de una prenda de Prime Live
alter table public.live_apartados alter column prenda drop not null;
alter table public.live_apartados add column if not exists prime_prenda uuid references public.prime_prendas (id);
alter table public.live_apartados drop constraint if exists live_apartados_una_prenda;
alter table public.live_apartados add constraint live_apartados_una_prenda
  check ((prenda is null) <> (prime_prenda is null));
create unique index if not exists live_apartados_prime_ocupada
  on public.live_apartados (prime_prenda) where prime_prenda is not null and estado in ('apartada', 'pagada');

-- Invitaciones: una contraseña por mayorista y por live
create table if not exists public.prime_invitaciones (
  id uuid primary key default gen_random_uuid(),
  live_id uuid not null references public.lives (id),
  clienta_id uuid not null references public.clientas (id),
  codigo text not null unique,
  activa boolean not null default true,
  creada_en timestamptz not null default now(),
  creada_por text,
  primer_acceso timestamptz,
  ultimo_acceso timestamptz,
  accesos integer not null default 0,
  unique (live_id, clienta_id)
);

do $$
declare t text;
begin
  foreach t in array array['prime_prendas', 'prime_invitaciones'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists equipo on public.%I', t);
    execute format('create policy equipo on public.%I for all to authenticated using (true) with check (true)', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated, service_role', t);
  end loop;
end $$;

-- Fotos de las prendas: carpeta pública (son fotos de ropa, sin datos personales)
insert into storage.buckets (id, name, public, file_size_limit)
values ('prime', 'prime', true, 5242880)
on conflict (id) do nothing;
drop policy if exists "equipo sube fotos prime" on storage.objects;
create policy "equipo sube fotos prime" on storage.objects for insert to authenticated with check (bucket_id = 'prime');
drop policy if exists "equipo cambia fotos prime" on storage.objects;
create policy "equipo cambia fotos prime" on storage.objects for update to authenticated using (bucket_id = 'prime');
drop policy if exists "equipo borra fotos prime" on storage.objects;
create policy "equipo borra fotos prime" on storage.objects for delete to authenticated using (bucket_id = 'prime');

-- ---------------------------------------------------------------------
-- 3. Textos: piezas de una cuenta, sirvan para etiquetas (0023) o Prime (#3)
-- ---------------------------------------------------------------------
create or replace function public.live_unir(p text[]) returns text
language sql immutable set search_path = public as $$
  select case
    when p is null or cardinality(p) = 0 then ''
    when cardinality(p) = 1 then p[1]
    else array_to_string(p[1:cardinality(p) - 1], ', ') || ' y ' || p[cardinality(p)]
  end
$$;

create or replace function public.live_etiquetas(p_cuenta uuid, p_estados text[]) returns text[]
language sql stable set search_path = public as $$
  select coalesce(array_agg(coalesce(live_num(a.prenda), '#' || pp.num) order by a.prenda nulls last, pp.num), '{}')
    from live_apartados a
    left join prime_prendas pp on pp.id = a.prime_prenda
   where a.cuenta_id = p_cuenta and a.estado = any (p_estados)
$$;

create or replace function public.live_texto_resumen(p_live uuid, p_clienta uuid) returns text
language plpgsql stable set search_path = public as $$
declare c live_cuentas;
begin
  select * into c from live_cuentas
   where live_id = p_live and clienta_id = p_clienta and estado = 'abierta'
   order by creada_en desc limit 1;
  if not found or c.piezas = 0 then return null; end if;
  return format('🛍️ Llevas %s %s: %s = %s. Al terminar el live te mandamos tu total y cómo pagar.',
    c.piezas, case when c.piezas = 1 then 'prenda' else 'prendas' end,
    live_unir(live_etiquetas(c.id, array['apartada'])), live_dinero(c.total));
end $$;

create or replace function public.live_texto_cobro(p_cuenta uuid) returns text
language plpgsql stable set search_path = public as $$
declare
  c live_cuentas;
  v_cfg live_config;
  v_tipo text;
  v_txt text;
  v_datos text;
begin
  select * into c from live_cuentas where id = p_cuenta;
  select * into v_cfg from live_config limit 1;
  select tipo into v_tipo from lives where id = c.live_id;

  v_txt := format('🧾 Tu total del %s: *%s* (%s %s: %s).',
    case when v_tipo = 'prime' then 'Prime Live' else 'live' end,
    live_dinero(c.total), c.piezas, case when c.piezas = 1 then 'prenda' else 'prendas' end,
    live_unir(live_etiquetas(c.id, array['apartada'])));

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
-- 4. Ajustes a lo que ya existía para que distinga redes de prime
-- ---------------------------------------------------------------------

-- El bot de WhatsApp solo aparta en el live de REDES
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

  if p_wa_id is not null and exists (select 1 from wa_mensajes where wa_id = p_wa_id) then
    return jsonb_build_object('duplicado', true);
  end if;

  perform pg_advisory_xact_lock(hashtext('live-tel-' || v_tel));
  select * into v_cfg from live_config limit 1;

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

  select coalesce(array_agg(n order by o), '{}') into v_nums
    from (select (m[1])::integer as n, min(o) as o
            from regexp_matches(v_txt, '(?<![0-9])([0-9]{1,5})(?![0-9])', 'g') with ordinality as t(m, o)
           group by 1) s;

  select * into v_live from lives where estado = 'activo' and tipo = 'redes' limit 1;

  if v_nueva then
    v_lineas := v_lineas || '¡Bienvenida a Outlet Prime! 💕'::text;
  end if;

  if cardinality(v_nums) = 0 then
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

create or replace function public.live_iniciar(p_titulo text default null, p_usuario text default null)
returns public.lives language plpgsql set search_path = public as $$
declare l lives;
begin
  if exists (select 1 from lives where estado = 'activo' and tipo = 'redes') then
    raise exception 'Ya hay un live de redes en curso.';
  end if;
  insert into lives (titulo, iniciado_por, tipo) values (nullif(trim(p_titulo), ''), p_usuario, 'redes') returning * into l;
  return l;
end $$;

create or replace function public.live_pasar_a_caja(p_cuenta uuid) returns text
language plpgsql set search_path = public as $$
declare
  c live_cuentas;
  a asignaciones;
  v_caja text;
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

  select * into a from asignaciones where clienta_id = c.clienta_id and estado = 'activa' limit 1;
  if not found then
    select k.id into v_caja from cajas k
     where not exists (select 1 from asignaciones x where x.caja = k.id and x.estado = 'activa')
     order by substring(k.id from '^[^0-9]*'), nullif(substring(k.id from '[0-9]+'), '')::integer nulls first, k.id
     limit 1
     for update skip locked;
    if v_caja is null then
      return null;
    end if;
    insert into asignaciones (caja, clienta_id, estado, asignada_por, movimientos)
    values (v_caja, c.clienta_id, 'activa', 'Sistema de lives', '[]'::jsonb)
    returning * into a;
  end if;

  select * into v_live from lives where id = c.live_id;
  select zona_horaria into v_tz from live_config limit 1;
  if v_live.tipo = 'prime' then v_cat := 'prime'; v_nombre := 'Prime Live';
  else v_cat := 'live'; v_nombre := 'Live'; end if;

  v_piezas := live_etiquetas(c.id, array['pagada']);
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
  update prime_prendas p set estado = 'pagada'
    from live_apartados a
   where a.cuenta_id = c.id and a.estado = 'pagada' and p.id = a.prime_prenda;
  update live_apartados e set estado = 'cancelada', actualizado_en = now()
    from live_apartados a
   where a.cuenta_id = c.id and a.estado = 'pagada' and a.prenda is not null
     and e.prenda = a.prenda and e.estado = 'espera';
  update live_cuentas set estado = 'pagada', pagada_en = now(), pagada_por = p_usuario where id = c.id;

  v_caja := live_pasar_a_caja(c.id);
  select * into c from live_cuentas where id = c.id;
  perform wa_encolar(v_tel, format('✅ Pago recibido (%s). Tus prendas ya van a tu caja. Te avisamos cuando la enviemos.',
    live_dinero(c.monto_pagado)), c.clienta_id);
  return c;
end $$;

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

  if a.prenda is not null then
    perform 1 from prendas where numero = a.prenda for update;
    update prendas set estado = 'disponible', actualizada_en = now() where numero = a.prenda;
  else
    update prime_prendas set estado = 'disponible', disponible_en = least(disponible_en, now()) where id = a.prime_prenda;
  end if;
  update live_apartados set estado = 'liberada', actualizado_en = now() where id = a.id;
  perform live_recalcular(a.cuenta_id);
  select * into c from live_cuentas where id = a.cuenta_id;
  if c.piezas = 0 and c.estado in ('por_pagar', 'pago_incompleto') then
    update live_cuentas set estado = 'cancelada' where id = c.id;
  end if;
  if a.prenda is not null then
    perform live_ofrecer_espera(a.prenda);
  end if;
end $$;

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
      update prime_prendas p set estado = 'disponible'
        from live_apartados a
       where a.cuenta_id = c.id and a.estado = 'liberada' and p.id = a.prime_prenda and p.estado = 'apartada';
      select telefono into v_tel from clientas where id = c.clienta_id;
      perform wa_encolar(v_tel, 'Tu apartado venció y las prendas se liberaron para otras clientas. ¡Te esperamos en el próximo live! 💕', c.clienta_id);
      for v_prenda in select prenda from live_apartados
                       where cuenta_id = c.id and estado = 'liberada' and prenda is not null order by prenda loop
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
    from live_apartados where clienta_id = any (v_cl) and estado in ('apartada', 'pagada') and prenda is not null;
  select coalesce(array_agg(distinct live_id), '{}') into v_lives
    from (select live_id from live_apartados where clienta_id = any (v_cl)
          union select live_id from live_cuentas where clienta_id = any (v_cl)) s;

  update prime_prendas p set estado = 'disponible'
    from live_apartados a
   where a.clienta_id = any (v_cl) and a.estado in ('apartada', 'pagada') and p.id = a.prime_prenda;
  delete from live_apartados where clienta_id = any (v_cl);
  delete from live_cuentas where clienta_id = any (v_cl);
  delete from prime_invitaciones where clienta_id = any (v_cl);
  delete from pedidos where clienta_id = any (v_cl);
  get diagnostics v_ped = row_count;
  delete from asignaciones where clienta_id = any (v_cl);
  delete from wa_mensajes where telefono like '00%';
  delete from clientas where id = any (v_cl);

  update prendas p set estado = 'disponible', actualizada_en = now()
   where p.numero = any (v_pr)
     and not exists (select 1 from live_apartados a where a.prenda = p.numero and a.estado in ('apartada', 'pagada'));
  delete from lives l
   where l.id = any (v_lives) and l.estado = 'cerrado' and l.tipo = 'redes'
     and not exists (select 1 from live_apartados a where a.live_id = l.id)
     and not exists (select 1 from live_cuentas c where c.live_id = l.id);

  return jsonb_build_object('clientas', cardinality(v_cl), 'prendas', cardinality(v_pr), 'pedidos', v_ped);
end $$;

-- ---------------------------------------------------------------------
-- 5. Prime Live: funciones del EQUIPO (requieren sesión iniciada)
-- ---------------------------------------------------------------------

-- 8 caracteres sin letras confusas (sin I, O, 0, 1): ~1 billón de combinaciones
create or replace function public.prime_codigo_nuevo() returns text
language plpgsql volatile set search_path = public as $$
declare
  a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := uuid_send(gen_random_uuid());
  r text := '';
  i integer;
begin
  foreach i in array array[0, 1, 2, 3, 4, 5, 10, 11] loop
    r := r || substr(a, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return r;
end $$;

create or replace function public.prime_programar(
  p_titulo text default null,
  p_programado_para timestamptz default null,
  p_precio numeric default null,
  p_limite integer default null,
  p_usuario text default null
) returns public.lives
language plpgsql set search_path = public as $$
declare
  v_cfg live_config;
  l lives;
begin
  select * into v_cfg from live_config limit 1;
  insert into lives (tipo, estado, titulo, programado_para, precio, limite, retraso, video_url, iniciado_por)
  values ('prime', 'programado', coalesce(nullif(trim(p_titulo), ''), 'Prime Live'), p_programado_para,
          coalesce(p_precio, v_cfg.prime_precio), coalesce(p_limite, v_cfg.prime_limite),
          v_cfg.prime_retraso, nullif(trim(v_cfg.prime_video_url), ''), p_usuario)
  returning * into l;
  return l;
end $$;

create or replace function public.prime_invitar(p_live uuid, p_clienta uuid, p_usuario text default null)
returns public.prime_invitaciones
language plpgsql set search_path = public as $$
declare
  l lives;
  inv prime_invitaciones;
  intento integer := 0;
begin
  select * into l from lives where id = p_live;
  if not found or l.tipo <> 'prime' then raise exception 'Ese Prime Live no existe.'; end if;
  if l.estado = 'cerrado' then raise exception 'Ese Prime Live ya terminó.'; end if;
  update clientas set mayorista = true where id = p_clienta;
  if not found then raise exception 'No existe esa clienta.'; end if;

  select * into inv from prime_invitaciones where live_id = p_live and clienta_id = p_clienta;
  if found then
    update prime_invitaciones set activa = true where id = inv.id returning * into inv;
    return inv;
  end if;
  loop
    begin
      insert into prime_invitaciones (live_id, clienta_id, codigo, creada_por)
      values (p_live, p_clienta, prime_codigo_nuevo(), p_usuario)
      returning * into inv;
      return inv;
    exception when unique_violation then
      intento := intento + 1;
      if intento > 5 then raise; end if;
    end;
  end loop;
end $$;

create or replace function public.prime_revocar(p_invitacion uuid) returns void
language sql set search_path = public as $$
  update prime_invitaciones set activa = false where id = p_invitacion
$$;

create or replace function public.prime_iniciar(p_live uuid, p_usuario text default null)
returns public.lives language plpgsql set search_path = public as $$
declare l lives;
begin
  if exists (select 1 from lives where estado = 'activo' and tipo = 'prime') then
    raise exception 'Ya hay un Prime Live en curso.';
  end if;
  update lives set estado = 'activo', iniciado_en = now(), iniciado_por = coalesce(p_usuario, iniciado_por)
   where id = p_live and tipo = 'prime' and estado = 'programado'
  returning * into l;
  if not found then raise exception 'Ese Prime Live no está programado.'; end if;
  return l;
end $$;

create or replace function public.prime_cancelar(p_live uuid) returns void
language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from lives where id = p_live and tipo = 'prime' and estado = 'programado') then
    raise exception 'Solo se puede cancelar un Prime Live que no ha empezado.';
  end if;
  delete from prime_invitaciones where live_id = p_live;
  delete from lives where id = p_live;
end $$;

-- Publica la prenda capturada: todas reciben el botón al mismo tiempo
create or replace function public.prime_publicar(p_live uuid, p_foto text, p_talla text default null, p_usuario text default null)
returns public.prime_prendas
language plpgsql set search_path = public as $$
declare
  l lives;
  p prime_prendas;
begin
  select * into l from lives where id = p_live for update;
  if not found or l.tipo <> 'prime' or l.estado <> 'activo' then
    raise exception 'El Prime Live no está en curso.';
  end if;
  insert into prime_prendas (live_id, num, foto, precio, talla, disponible_en, creada_por)
  values (l.id,
          coalesce((select max(num) from prime_prendas where live_id = l.id), 0) + 1,
          p_foto,
          coalesce(l.precio, (select prime_precio from live_config limit 1)),
          nullif(trim(p_talla), ''),
          now() + make_interval(secs => greatest(coalesce(l.retraso, 0), 0)),
          p_usuario)
  returning * into p;
  update lives set actual_prenda = p.id where id = l.id;
  return p;
end $$;

create or replace function public.prime_editar_prenda(p_prenda uuid, p_talla text default null, p_quitar boolean default false)
returns void language plpgsql set search_path = public as $$
declare p prime_prendas;
begin
  select * into p from prime_prendas where id = p_prenda for update;
  if not found then raise exception 'No existe esa prenda.'; end if;
  if p_quitar then
    if p.estado <> 'disponible' then raise exception 'Solo se puede quitar una prenda que nadie ha apartado.'; end if;
    update prime_prendas set estado = 'quitada' where id = p.id;
    update lives set actual_prenda = null where actual_prenda = p.id;
  else
    update prime_prendas set talla = nullif(trim(p_talla), '') where id = p.id;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. Prime Live: funciones de las MAYORISTAS (sin usuario, con su contraseña)
--    Corren con permisos del sistema, pero solo devuelven lo de esa mayorista.
-- ---------------------------------------------------------------------
create or replace function public.prime_validar(p_codigo text) returns public.prime_invitaciones
language plpgsql security definer set search_path = public as $$
declare
  v text := upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z0-9]', '', 'g'));
  inv prime_invitaciones;
  l lives;
  v_horas numeric;
begin
  if length(v) <> 8 then raise exception 'Contraseña no válida.'; end if;
  select * into inv from prime_invitaciones where codigo = v and activa;
  if not found then raise exception 'Contraseña no válida.'; end if;
  select * into l from lives where id = inv.live_id;
  select horas_liberar into v_horas from live_config limit 1;
  if l.estado = 'cerrado' and now() > l.cerrado_en + (v_horas + 1) * interval '1 hour' then
    raise exception 'Esta contraseña ya venció: era solo para el Prime Live del %.',
      to_char(l.iniciado_en at time zone (select zona_horaria from live_config limit 1), 'DD/MM/YYYY');
  end if;
  return inv;
end $$;

create or replace function public.prime_estado(p_codigo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  inv prime_invitaciones;
  l lives;
  cl clientas;
  c live_cuentas;
  v_cfg live_config;
begin
  inv := prime_validar(p_codigo);
  select * into l from lives where id = inv.live_id;
  select * into cl from clientas where id = inv.clienta_id;
  select * into v_cfg from live_config limit 1;
  select * into c from live_cuentas where live_id = l.id and clienta_id = inv.clienta_id
   order by creada_en desc limit 1;

  return jsonb_build_object(
    'ahora', clock_timestamp(),
    'clienta', split_part(cl.nombre, ' ', 1),
    'live', jsonb_build_object(
      'titulo', l.titulo, 'estado', l.estado, 'programado_para', l.programado_para,
      'iniciado_en', l.iniciado_en, 'cerrado_en', l.cerrado_en, 'precio', l.precio,
      'limite', l.limite, 'video_url', l.video_url, 'actual', l.actual_prenda),
    'prendas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'num', p.num, 'foto', p.foto, 'precio', p.precio, 'talla', p.talla,
               'disponible_en', p.disponible_en,
               'estado', case when a.clienta_id = inv.clienta_id then 'mia'
                              when p.estado = 'disponible' then 'disponible'
                              else 'apartada' end)
             order by p.num desc), '[]'::jsonb)
        from prime_prendas p
        left join live_apartados a on a.prime_prenda = p.id and a.estado in ('apartada', 'pagada')
       where p.live_id = l.id and p.estado <> 'quitada'),
    'cuenta', case when c.id is null then null else jsonb_build_object(
      'folio', live_folio(c.folio), 'estado', c.estado, 'total', c.total, 'piezas', c.piezas,
      'monto_pagado', c.monto_pagado, 'clabe', c.clabe, 'banco', v_cfg.banco, 'titular', v_cfg.titular,
      'limite_pago', c.limite_pago, 'liberar_en', c.liberar_en) end
  );
end $$;

create or replace function public.prime_acceso(p_codigo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv prime_invitaciones;
begin
  inv := prime_validar(p_codigo);
  update prime_invitaciones
     set primer_acceso = coalesce(primer_acceso, now()), ultimo_acceso = now(), accesos = accesos + 1
   where id = inv.id;
  return prime_estado(p_codigo);
end $$;

-- Devuelve: ok, mia, tomada, espera, limite, cerrado, no_existe
create or replace function public.prime_apartar(p_codigo text, p_prenda uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  inv prime_invitaciones;
  l lives;
  p prime_prendas;
  c live_cuentas;
  v_tel text;
begin
  inv := prime_validar(p_codigo);
  select telefono into v_tel from clientas where id = inv.clienta_id;
  perform pg_advisory_xact_lock(hashtext('live-tel-' || coalesce(v_tel, inv.clienta_id::text)));
  select * into l from lives where id = inv.live_id;
  if l.estado <> 'activo' then return 'cerrado'; end if;

  select * into p from prime_prendas where id = p_prenda and live_id = l.id for update;
  if not found or p.estado = 'quitada' then return 'no_existe'; end if;
  if exists (select 1 from live_apartados
              where prime_prenda = p.id and clienta_id = inv.clienta_id and estado in ('apartada', 'pagada')) then
    return 'mia';
  end if;
  if p.estado <> 'disponible' then return 'tomada'; end if;
  if clock_timestamp() < p.disponible_en then return 'espera'; end if;
  if l.limite is not null and
     (select count(*) from live_apartados
       where live_id = l.id and clienta_id = inv.clienta_id and estado in ('apartada', 'pagada')) >= l.limite then
    return 'limite';
  end if;

  c := live_cuenta_para(l.id, inv.clienta_id);
  insert into live_apartados (live_id, prime_prenda, clienta_id, cuenta_id, estado, precio, mensaje_en)
  values (l.id, p.id, inv.clienta_id, c.id, 'apartada', p.precio, clock_timestamp());
  update prime_prendas set estado = 'apartada' where id = p.id;
  perform live_recalcular(c.id);
  return 'ok';
end $$;

-- ---------------------------------------------------------------------
-- 7. Vistas para el panel
-- ---------------------------------------------------------------------
create or replace view public.live_tablero with (security_invoker = true) as
select c.*,
       live_folio(c.folio) as folio_txt,
       trim(cl.nombre || coalesce(' ' || cl.apellidos, '')) as clienta,
       cl.telefono,
       (select coalesce(array_agg(a.prenda order by a.prenda), '{}')
          from live_apartados a where a.cuenta_id = c.id and a.estado in ('apartada', 'pagada') and a.prenda is not null) as prendas,
       l.estado as live_estado,
       l.iniciado_en as live_inicio,
       l.tipo,
       live_unir(live_etiquetas(c.id, array['apartada', 'pagada'])) as piezas_txt
  from live_cuentas c
  join clientas cl on cl.id = c.clienta_id
  join lives l on l.id = c.live_id;

drop view if exists public.live_feed;
create view public.live_feed with (security_invoker = true) as
select a.*,
       trim(cl.nombre || coalesce(' ' || cl.apellidos, '')) as clienta,
       cl.telefono,
       c.casillero,
       c.folio
  from live_apartados a
  join clientas cl on cl.id = a.clienta_id
  left join live_cuentas c on c.id = a.cuenta_id;

create or replace view public.prime_tablero with (security_invoker = true) as
select p.*,
       a.id as apartado_id,
       a.estado as apartado_estado,
       a.mensaje_en as apartada_en,
       trim(cl.nombre || coalesce(' ' || cl.apellidos, '')) as clienta,
       c.casillero
  from prime_prendas p
  left join live_apartados a on a.prime_prenda = p.id and a.estado in ('apartada', 'pagada')
  left join clientas cl on cl.id = a.clienta_id
  left join live_cuentas c on c.id = a.cuenta_id;

revoke all on public.live_tablero, public.live_feed, public.prime_tablero from anon;
grant select on public.live_tablero, public.live_feed, public.prime_tablero to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 8. Permisos
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and (p.proname like 'live\_%' or p.proname like 'prime\_%' or p.proname in ('bot_mensaje', 'wa_encolar')) loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;

-- Lo único que puede usar una mayorista sin sesión (siempre con su contraseña)
grant execute on function public.prime_acceso(text) to anon;
grant execute on function public.prime_estado(text) to anon;
grant execute on function public.prime_apartar(text, uuid) to anon;
