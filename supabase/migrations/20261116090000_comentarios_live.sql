-- =====================================================================
-- Outlet Prime · Apartar comentando en el live (agente con IA)
--
-- Flujo:
--  1. El agente lee los comentarios del live (TikTok, Facebook, Instagram, YouTube…)
--     y llama a live_comentario(red, @usuario, texto, prendas).
--  2. Si @usuario ya está ligada a una clienta → la prenda se le aparta al momento
--     y va a SU casillero (igual que por WhatsApp). Gana el primer comentario/mensaje.
--  3. Si no la conocemos → apartado PROVISIONAL (10 min por defecto) y aviso en el panel:
--     "🙋 Pide DM a @usuario". La host le pide mensaje directo; la bienvenida del DM
--     trae el WhatsApp del bot.
--  4. La clienta escribe al bot: nombre + @usuario + número. El bot la registra, liga
--     @usuario ↔ WhatsApp ↔ clienta y el provisional se vuelve definitivo.
--  5. Lo que comente después (en este live y en los siguientes) cae solo en su casillero.
--  El WhatsApp sigue sirviendo para apartar (respaldo): gana quien llegue primero.
--
-- Requiere haber pegado antes 20261113120000_niveles_acceso.sql.
-- Se puede pegar varias veces sin dañar nada.
-- =====================================================================

do $$
begin
  if to_regprocedure('public.puede_ver()') is null then
    raise exception 'Primero pega el archivo 20261113120000_niveles_acceso.sql y después este.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Ajustes
-- ---------------------------------------------------------------------
alter table public.live_config add column if not exists minutos_registro integer not null default 10;
alter table public.live_config add column if not exists whatsapp_numero text;
alter table public.live_config add column if not exists red_principal text not null default 'tiktok';
alter table public.live_config add column if not exists mensaje_dm text not null default
  '¡Hola! 💕 Para apartar tu prenda mándanos un WhatsApp al {whatsapp} con tu nombre, tu usuario ({usuario}) y el número de la prenda. Después de eso, todo lo que comentes en el live se te aparta solo.';
alter table public.live_config drop constraint if exists live_config_minutos_registro_check;
alter table public.live_config add constraint live_config_minutos_registro_check check (minutos_registro between 1 and 120);
alter table public.live_config drop constraint if exists live_config_red_principal_check;
alter table public.live_config add constraint live_config_red_principal_check
  check (red_principal in ('tiktok', 'facebook', 'instagram', 'youtube'));

-- De dónde vino cada apartado (whatsapp, tiktok, facebook…) y con qué usuario
alter table public.live_apartados add column if not exists origen text;
alter table public.live_apartados add column if not exists origen_usuario text;

-- ---------------------------------------------------------------------
-- 2. Tablas
-- ---------------------------------------------------------------------

-- Usuario de cada red social ligado a una clienta (una clienta puede tener varios)
create table if not exists public.clientas_redes (
  id uuid primary key default gen_random_uuid(),
  clienta_id uuid not null references public.clientas (id) on delete cascade,
  red text not null check (red in ('tiktok', 'facebook', 'instagram', 'youtube', 'otra')),
  usuario text not null check (usuario = lower(usuario) and usuario !~ '^@' and usuario !~ '\s' and length(usuario) between 1 and 60),
  ligada_en timestamptz not null default now(),
  ligada_por text,
  unique (red, usuario)
);
create index if not exists clientas_redes_clienta on public.clientas_redes (clienta_id);
create index if not exists clientas_redes_usuario on public.clientas_redes (usuario);

-- Usuaria que comentó en el live pero todavía no está registrada: "pide DM"
create table if not exists public.live_dm (
  id uuid primary key default gen_random_uuid(),
  live_id uuid not null references public.lives (id) on delete cascade,
  red text not null,
  usuario text not null,
  nombre_visible text,
  estado text not null default 'esperando' check (estado in ('esperando', 'registrada', 'vencida', 'cancelada')),
  primer_comentario_en timestamptz not null,
  vence_en timestamptz not null,
  pedido_en timestamptz,            -- la host ya le pidió el DM
  pedido_por text,
  clienta_id uuid references public.clientas (id) on delete set null,
  registrada_en timestamptz,
  simulado boolean not null default false,
  creado_en timestamptz not null default now()
);
create unique index if not exists live_dm_una_esperando on public.live_dm (live_id, red, usuario) where estado = 'esperando';
create index if not exists live_dm_usuario on public.live_dm (usuario, estado);
create index if not exists live_dm_vence on public.live_dm (vence_en) where estado = 'esperando';

-- Prendas que pidió esa usuaria mientras se registra
create table if not exists public.live_reservas (
  id uuid primary key default gen_random_uuid(),
  dm_id uuid not null references public.live_dm (id) on delete cascade,
  live_id uuid not null references public.lives (id) on delete cascade,
  prenda integer not null references public.prendas (numero),
  estado text not null check (estado in ('provisional', 'espera', 'confirmada', 'vencida', 'cancelada')),
  comentario_en timestamptz not null,   -- hora del comentario: conserva su lugar
  apartado_id uuid references public.live_apartados (id) on delete set null,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create unique index if not exists live_reservas_prenda_provisional on public.live_reservas (prenda) where estado = 'provisional';
create unique index if not exists live_reservas_una_por_dm on public.live_reservas (dm_id, prenda) where estado in ('provisional', 'espera');
create index if not exists live_reservas_dm on public.live_reservas (dm_id);

-- Comentarios con pedido que mandó el agente (bitácora para aclarar quién comentó primero)
create table if not exists public.live_comentarios (
  id bigint generated always as identity primary key,
  live_id uuid references public.lives (id) on delete set null,
  red text not null,
  usuario text not null,
  nombre_visible text,
  texto text not null,
  comentario_id text,
  comentado_en timestamptz not null,
  recibido_en timestamptz not null default now(),
  prendas integer[] not null default '{}',
  interpretado_por text,           -- reglas | ia | manual
  clienta_id uuid references public.clientas (id) on delete set null,
  resultado jsonb,
  simulado boolean not null default false
);
create unique index if not exists live_comentarios_unico on public.live_comentarios (red, comentario_id) where comentario_id is not null;
create index if not exists live_comentarios_live on public.live_comentarios (live_id, id desc);

-- Estado del agente en la computadora de la tienda (el panel lo muestra)
create table if not exists public.live_agente (
  red text primary key,              -- tiktok, facebook… o 'agente' para el programa en sí
  estado text not null,              -- conectado | esperando | error | apagado
  detalle text,
  comentarios integer not null default 0,
  pedidos integer not null default 0,
  equipo text,                       -- nombre de la computadora
  actualizado_en timestamptz not null default now()
);

-- Reglas de acceso (mismos niveles: ver todos · operar dueña/operación · borrar dueña)
do $$
declare
  t text;
  p record;
begin
  foreach t in array array['clientas_redes', 'live_dm', 'live_reservas', 'live_comentarios', 'live_agente'] loop
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy ver on public.%I for select to authenticated using ((select public.puede_ver()))', t);
    execute format('create policy crear on public.%I for insert to authenticated with check ((select public.puede_operar()))', t);
    execute format('create policy cambiar on public.%I for update to authenticated using ((select public.puede_operar())) with check ((select public.puede_operar()))', t);
    if t = 'clientas_redes' then
      -- quitar un usuario mal ligado lo puede hacer operación
      execute format('create policy borrar on public.%I for delete to authenticated using ((select public.puede_operar()))', t);
    else
      execute format('create policy borrar on public.%I for delete to authenticated using ((select public.es_duena()))', t);
    end if;
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated, service_role', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3. Ayudantes
-- ---------------------------------------------------------------------
create or replace function public.live_usuario_norm(p text) returns text
language sql immutable as $$
  -- minúsculas, sin acentos, sin @ ni espacios; solo letras, números, punto y guion bajo
  select nullif(left(regexp_replace(translate(lower(coalesce(p, '')), 'áàäâéèëêíìïîóòöôúùüûñç', 'aaaaeeeeiiiioooouuuunc'),
                                    '[^a-z0-9_.]', '', 'g'), 60), '')
$$;

-- 23 → 0023; los números de 5 cifras ya no se recortan
create or replace function public.live_num(p integer) returns text
language sql immutable set search_path = public as $$
  select case when p >= 10000 then p::text else lpad(p::text, 4, '0') end
$$;

create or replace function public.live_ints(j jsonb) returns integer[]
language sql immutable as $$
  select coalesce(array_agg(x::integer order by o), '{}')
    from jsonb_array_elements_text(coalesce(j, '[]'::jsonb)) with ordinality t(x, o)
$$;

create or replace function public.live_red_nombre(p text) returns text
language sql immutable as $$
  select case p when 'tiktok' then 'TikTok' when 'facebook' then 'Facebook' when 'instagram' then 'Instagram'
                when 'youtube' then 'YouTube' else coalesce(p, '') end
$$;

-- Mensaje de bienvenida del DM, con el WhatsApp y el usuario
create or replace function public.live_texto_dm(p_usuario text default null) returns text
language sql stable set search_path = public as $$
  select replace(replace(c.mensaje_dm, '{whatsapp}', coalesce(nullif(trim(c.whatsapp_numero), ''), '(número del bot)')),
                 '{usuario}', coalesce('@' || nullif(p_usuario, ''), 'tu usuario'))
    from live_config c limit 1
$$;

-- ---------------------------------------------------------------------
-- 4. Apartar números para una clienta conocida (lo usan el bot y el agente)
-- ---------------------------------------------------------------------
create or replace function public.live_apartar(
  p_live uuid,
  p_clienta uuid,
  p_nums integer[],
  p_recibido timestamptz,
  p_origen text default 'whatsapp',
  p_origen_usuario text default null
) returns jsonb
language plpgsql set search_path = public as $$
declare
  v_cfg live_config;
  v_pr prendas;
  v_c live_cuentas;
  v_n integer;
  v_pos integer;
  v_cas text;
  v_tuyas integer[] := '{}';
  v_ya integer[] := '{}';
  v_vendidas integer[] := '{}';
  v_noexiste integer[] := '{}';
  v_limite integer[] := '{}';
  v_prov integer[] := '{}';
  v_espera jsonb := '[]'::jsonb;
begin
  select * into v_cfg from live_config limit 1;
  foreach v_n in array coalesce(p_nums, '{}') loop
    select * into v_pr from prendas where numero = v_n for update;
    if not found then
      v_noexiste := v_noexiste || v_n;
      continue;
    end if;

    if exists (select 1 from live_apartados
                where prenda = v_n and clienta_id = p_clienta and estado in ('apartada', 'pagada')) then
      v_ya := v_ya || v_n;

    elsif v_pr.estado = 'disponible' then
      if v_cfg.limite_por_clienta is not null and
         (select count(*) from live_apartados
           where live_id = p_live and clienta_id = p_clienta and estado in ('apartada', 'pagada')) >= v_cfg.limite_por_clienta then
        v_limite := v_limite || v_n;
        continue;
      end if;
      v_c := live_cuenta_para(p_live, p_clienta);
      update live_apartados set estado = 'cancelada', actualizado_en = now()
       where prenda = v_n and clienta_id = p_clienta and estado = 'espera';
      insert into live_apartados (live_id, prenda, clienta_id, cuenta_id, estado, precio, mensaje_en, origen, origen_usuario)
      values (p_live, v_n, p_clienta, v_c.id, 'apartada', v_pr.precio, p_recibido, p_origen, p_origen_usuario);
      update prendas set estado = 'apartada', actualizada_en = now() where numero = v_n;
      perform live_recalcular(v_c.id);
      v_tuyas := v_tuyas || v_n;

    elsif v_pr.estado = 'apartada' then
      if not exists (select 1 from live_apartados
                      where prenda = v_n and clienta_id = p_clienta and estado = 'espera') then
        insert into live_apartados (live_id, prenda, clienta_id, estado, precio, mensaje_en, origen, origen_usuario)
        values (p_live, v_n, p_clienta, 'espera', v_pr.precio, p_recibido, p_origen, p_origen_usuario);
      end if;
      select count(*) into v_pos
        from live_apartados e, live_apartados yo
       where yo.prenda = v_n and yo.clienta_id = p_clienta and yo.estado = 'espera'
         and e.prenda = v_n and e.estado = 'espera'
         and (e.mensaje_en, e.creado_en) <= (yo.mensaje_en, yo.creado_en);
      v_espera := v_espera || jsonb_build_object('n', v_n, 'pos', v_pos);
      if exists (select 1 from live_reservas where prenda = v_n and estado = 'provisional') then
        v_prov := v_prov || v_n;
      end if;

    else
      v_vendidas := v_vendidas || v_n;
    end if;
  end loop;

  select casillero into v_cas from live_cuentas
   where live_id = p_live and clienta_id = p_clienta and estado in ('abierta', 'por_pagar', 'pago_incompleto')
   order by creada_en desc limit 1;

  return jsonb_build_object(
    'tuyas', to_jsonb(v_tuyas), 'ya', to_jsonb(v_ya), 'espera', v_espera,
    'vendidas', to_jsonb(v_vendidas), 'noexiste', to_jsonb(v_noexiste), 'limite', to_jsonb(v_limite),
    'provisional_de_otra', to_jsonb(v_prov), 'casillero', v_cas);
end $$;

-- Las líneas de respuesta del bot para un resultado de live_apartar
create or replace function public.live_texto_apartar(r jsonb) returns text[]
language plpgsql stable set search_path = public as $$
declare
  v_l text[] := '{}';
  a integer[];
  v_esp text[];
  v_lim integer;
begin
  a := live_ints(r->'tuyas');
  if cardinality(a) = 1 then v_l := v_l || format('✅ La %s es tuya.', live_num(a[1]));
  elsif cardinality(a) > 1 then v_l := v_l || format('✅ %s son tuyas.', live_lista(a)); end if;
  a := live_ints(r->'ya');
  if cardinality(a) = 1 then v_l := v_l || format('👍 La %s ya era tuya.', live_num(a[1]));
  elsif cardinality(a) > 1 then v_l := v_l || format('👍 %s ya eran tuyas.', live_lista(a)); end if;
  select coalesce(array_agg(format('%s ya se apartó: quedaste #%s en espera', live_num((e->>'n')::integer), e->>'pos') order by o), '{}')
    into v_esp from jsonb_array_elements(coalesce(r->'espera', '[]'::jsonb)) with ordinality t(e, o);
  if cardinality(v_esp) > 0 then
    v_l := v_l || ('⏳ ' || array_to_string(v_esp, '; ') || '. Si se libera, te avisamos.');
  end if;
  a := live_ints(r->'vendidas');
  if cardinality(a) = 1 then v_l := v_l || format('❌ La %s ya se vendió.', live_num(a[1]));
  elsif cardinality(a) > 1 then v_l := v_l || format('❌ %s ya se vendieron.', live_lista(a)); end if;
  a := live_ints(r->'noexiste');
  if cardinality(a) > 0 then
    v_l := v_l || format('🤔 No encontramos %s. Revisa el número de la etiqueta.',
      case when cardinality(a) = 1 then 'la ' || live_num(a[1]) else live_lista(a) end);
  end if;
  a := live_ints(r->'limite');
  if cardinality(a) > 0 then
    select limite_por_clienta into v_lim from live_config limit 1;
    v_l := v_l || format('⚠️ Ya tienes el máximo de %s prendas en este live; no pudimos apartar %s.', v_lim, live_lista(a));
  end if;
  return v_l;
end $$;

-- ---------------------------------------------------------------------
-- 5. Comentario del live (lo llama el agente, o el equipo a mano)
-- ---------------------------------------------------------------------
create or replace function public.live_comentario(
  p_red text,
  p_usuario text,
  p_texto text,
  p_prendas integer[],
  p_comentado_en timestamptz default null,
  p_comentario_id text default null,
  p_nombre text default null,
  p_interpretado_por text default 'reglas',
  p_simulado boolean default false
) returns jsonb
language plpgsql set search_path = public as $$
declare
  v_red text := lower(trim(coalesce(p_red, '')));
  v_usr text := live_usuario_norm(p_usuario);
  v_sim boolean;
  v_at timestamptz := least(coalesce(p_comentado_en, clock_timestamp()), clock_timestamp());
  v_cfg live_config;
  v_live lives;
  v_com bigint;
  v_nums integer[];
  v_cl clientas;
  v_d live_dm;
  v_pr prendas;
  v_n integer;
  v_res jsonb;
  v_reserv integer[] := '{}';
  v_ya integer[] := '{}';
  v_esp integer[] := '{}';
  v_vend integer[] := '{}';
  v_noex integer[] := '{}';
begin
  if v_red not in ('tiktok', 'facebook', 'instagram', 'youtube', 'otra') then
    raise exception 'Red social desconocida: %', p_red;
  end if;
  if v_usr is null then raise exception 'Falta el usuario del comentario.'; end if;
  v_sim := coalesce(p_simulado, false) or v_usr like 'sim\_%';
  if v_sim and v_usr not like 'sim\_%' then v_usr := left('sim_' || v_usr, 60); end if;

  if p_comentario_id is not null and exists (select 1 from live_comentarios where red = v_red and comentario_id = p_comentario_id) then
    return jsonb_build_object('resultado', 'duplicado');
  end if;

  select coalesce(array_agg(n order by o), '{}') into v_nums
    from (select n, min(o) o from unnest(coalesce(p_prendas, '{}')) with ordinality t(n, o)
           where n between 1 and 99999 group by n) s;

  select * into v_cfg from live_config limit 1;
  select * into v_live from lives where estado = 'activo' and tipo = 'redes' limit 1;
  if v_live.id is null then
    return jsonb_build_object('resultado', 'sin_live', 'red', v_red, 'usuario', v_usr);
  end if;

  insert into live_comentarios (live_id, red, usuario, nombre_visible, texto, comentario_id, comentado_en,
                                prendas, interpretado_por, simulado)
  values (v_live.id, v_red, v_usr, nullif(trim(p_nombre), ''), coalesce(p_texto, ''), p_comentario_id, v_at,
          v_nums, p_interpretado_por, v_sim)
  returning id into v_com;

  if cardinality(v_nums) = 0 then
    v_res := jsonb_build_object('resultado', 'sin_prendas');
  else
    -- Mismo candado que usa el bot al registrar a esta usuaria (siempre usuario → teléfono)
    perform pg_advisory_xact_lock(hashtext('live-usr-' || v_usr));
    select c.* into v_cl from clientas_redes r join clientas c on c.id = r.clienta_id
     where r.red = v_red and r.usuario = v_usr;

    if found then
      perform pg_advisory_xact_lock(hashtext('live-tel-' || coalesce(v_cl.telefono, v_cl.id::text)));
      v_res := live_apartar(v_live.id, v_cl.id, v_nums, v_at, v_red, v_usr)
               || jsonb_build_object('resultado', 'clienta', 'clienta_id', v_cl.id,
                                     'clienta', trim(v_cl.nombre || coalesce(' ' || v_cl.apellidos, '')));
      update live_comentarios set clienta_id = v_cl.id where id = v_com;
    else
      select * into v_d from live_dm
       where live_id = v_live.id and red = v_red and usuario = v_usr and estado = 'esperando'
       for update;
      if not found then
        insert into live_dm (live_id, red, usuario, nombre_visible, primer_comentario_en, vence_en, simulado)
        values (v_live.id, v_red, v_usr, nullif(trim(p_nombre), ''), v_at,
                now() + v_cfg.minutos_registro * interval '1 minute', v_sim)
        returning * into v_d;
      end if;

      foreach v_n in array v_nums loop
        select * into v_pr from prendas where numero = v_n for update;
        if not found then
          v_noex := v_noex || v_n;
        elsif exists (select 1 from live_reservas where dm_id = v_d.id and prenda = v_n and estado in ('provisional', 'espera')) then
          v_ya := v_ya || v_n;
        elsif v_pr.estado = 'disponible' then
          insert into live_reservas (dm_id, live_id, prenda, estado, comentario_en)
          values (v_d.id, v_live.id, v_n, 'provisional', v_at);
          update prendas set estado = 'apartada', actualizada_en = now() where numero = v_n;
          v_reserv := v_reserv || v_n;
        elsif v_pr.estado = 'apartada' then
          insert into live_reservas (dm_id, live_id, prenda, estado, comentario_en)
          values (v_d.id, v_live.id, v_n, 'espera', v_at);
          v_esp := v_esp || v_n;
        else
          v_vend := v_vend || v_n;
        end if;
      end loop;

      v_res := jsonb_build_object('resultado', 'pide_dm', 'dm_id', v_d.id, 'vence_en', v_d.vence_en,
        'provisional', to_jsonb(v_reserv), 'ya', to_jsonb(v_ya), 'espera_provisional', to_jsonb(v_esp),
        'vendidas', to_jsonb(v_vend), 'noexiste', to_jsonb(v_noex), 'mensaje_dm', live_texto_dm(v_usr));
    end if;
  end if;

  v_res := v_res || jsonb_build_object('comentario', v_com, 'red', v_red, 'usuario', v_usr);
  update live_comentarios set resultado = v_res where id = v_com;
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- 6. Ligar @usuario ↔ clienta y volver definitivo lo que pidió en el live
-- ---------------------------------------------------------------------
create or replace function public.live_ligar_red(
  p_clienta uuid,
  p_red text,
  p_usuario text,
  p_por text default null,
  p_forzar boolean default false,
  p_avisar boolean default false      -- true: le manda por WhatsApp lo que quedó (cuando se liga desde el panel)
) returns jsonb
language plpgsql set search_path = public as $$
declare
  v_red text := lower(trim(coalesce(p_red, '')));
  v_usr text := live_usuario_norm(p_usuario);
  v_cfg live_config;
  v_cl clientas;
  v_otra uuid;
  d live_dm;
  r live_reservas;
  v_pr prendas;
  v_c live_cuentas;
  v_ap uuid;
  v_pos integer;
  v_cuentas uuid[] := '{}';
  v_tuyas integer[] := '{}';
  v_ya integer[] := '{}';
  v_vend integer[] := '{}';
  v_lim integer[] := '{}';
  v_espera jsonb := '[]'::jsonb;
  v_cobros text[] := '{}';
  v_cid uuid;
  v_lineas text[];
  v_msg text;
begin
  if v_red not in ('tiktok', 'facebook', 'instagram', 'youtube', 'otra') then
    raise exception 'Red social desconocida: %', p_red;
  end if;
  if v_usr is null then raise exception 'Falta el usuario.'; end if;
  select * into v_cl from clientas where id = p_clienta;
  if not found then raise exception 'No existe esa clienta.'; end if;

  perform pg_advisory_xact_lock(hashtext('live-usr-' || v_usr));
  perform pg_advisory_xact_lock(hashtext('live-tel-' || coalesce(v_cl.telefono, v_cl.id::text)));
  select * into v_cfg from live_config limit 1;

  select clienta_id into v_otra from clientas_redes where red = v_red and usuario = v_usr for update;
  if found and v_otra <> p_clienta then
    if not coalesce(p_forzar, false) then
      return jsonb_build_object('conflicto', true, 'red', v_red, 'usuario', v_usr,
        'clienta_actual', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = v_otra));
    end if;
    update clientas_redes set clienta_id = p_clienta, ligada_en = now(), ligada_por = p_por
     where red = v_red and usuario = v_usr;
  elsif not found then
    insert into clientas_redes (clienta_id, red, usuario, ligada_por) values (p_clienta, v_red, v_usr, p_por);
  end if;

  for d in select * from live_dm where red = v_red and usuario = v_usr and estado = 'esperando'
            order by creado_en for update loop
    for r in select * from live_reservas where dm_id = d.id and estado in ('provisional', 'espera')
              order by comentario_en, creado_en for update loop
      select * into v_pr from prendas where numero = r.prenda for update;

      if exists (select 1 from live_apartados
                  where prenda = r.prenda and clienta_id = p_clienta and estado in ('apartada', 'pagada')) then
        if r.estado = 'provisional' then   -- ya era suya por WhatsApp: el provisional sobra
          update live_reservas set estado = 'cancelada', actualizado_en = now() where id = r.id;
        else
          update live_reservas set estado = 'confirmada', actualizado_en = now() where id = r.id;
        end if;
        v_ya := v_ya || r.prenda;

      elsif (r.estado = 'provisional' and v_pr.estado = 'apartada'
             and not exists (select 1 from live_apartados where prenda = r.prenda and estado in ('apartada', 'pagada')))
            or v_pr.estado = 'disponible' then
        if v_cfg.limite_por_clienta is not null and
           (select count(*) from live_apartados
             where live_id = d.live_id and clienta_id = p_clienta and estado in ('apartada', 'pagada')) >= v_cfg.limite_por_clienta then
          update live_reservas set estado = 'cancelada', actualizado_en = now() where id = r.id;
          if r.estado = 'provisional' then
            update prendas set estado = 'disponible', actualizada_en = now() where numero = r.prenda;
            perform live_ofrecer_espera(r.prenda);
          end if;
          v_lim := v_lim || r.prenda;
          continue;
        end if;
        v_c := live_cuenta_para(d.live_id, p_clienta);
        update live_apartados set estado = 'cancelada', actualizado_en = now()
         where prenda = r.prenda and clienta_id = p_clienta and estado = 'espera';
        insert into live_apartados (live_id, prenda, clienta_id, cuenta_id, estado, precio, mensaje_en, origen, origen_usuario)
        values (d.live_id, r.prenda, p_clienta, v_c.id, 'apartada', v_pr.precio, r.comentario_en, d.red, d.usuario)
        returning id into v_ap;
        update prendas set estado = 'apartada', actualizada_en = now() where numero = r.prenda;
        perform live_recalcular(v_c.id);
        update live_reservas set estado = 'confirmada', apartado_id = v_ap, actualizado_en = now() where id = r.id;
        if not v_c.id = any (v_cuentas) then v_cuentas := v_cuentas || v_c.id; end if;
        v_tuyas := v_tuyas || r.prenda;

      elsif v_pr.estado = 'apartada' then
        if not exists (select 1 from live_apartados where prenda = r.prenda and clienta_id = p_clienta and estado = 'espera') then
          insert into live_apartados (live_id, prenda, clienta_id, estado, precio, mensaje_en, origen, origen_usuario)
          values (d.live_id, r.prenda, p_clienta, 'espera', v_pr.precio, r.comentario_en, d.red, d.usuario)
          returning id into v_ap;
        else
          select id into v_ap from live_apartados where prenda = r.prenda and clienta_id = p_clienta and estado = 'espera';
        end if;
        update live_reservas set estado = 'confirmada', apartado_id = v_ap, actualizado_en = now() where id = r.id;
        select count(*) into v_pos
          from live_apartados e, live_apartados yo
         where yo.id = v_ap and e.prenda = r.prenda and e.estado = 'espera'
           and (e.mensaje_en, e.creado_en) <= (yo.mensaje_en, yo.creado_en);
        v_espera := v_espera || jsonb_build_object('n', r.prenda, 'pos', v_pos);

      else
        update live_reservas set estado = 'cancelada', actualizado_en = now() where id = r.id;
        v_vend := v_vend || r.prenda;
      end if;
    end loop;
    update live_dm set estado = 'registrada', clienta_id = p_clienta, registrada_en = now() where id = d.id;
  end loop;

  -- Si el live ya se cerró, su cuenta nueva necesita el cobro (igual que cuando se libera una prenda)
  foreach v_cid in array v_cuentas loop
    select * into v_c from live_cuentas where id = v_cid;
    if v_c.estado = 'por_pagar' and v_c.cobro_enviado_en is null then
      update live_cuentas set
        clabe = coalesce(clabe, nullif(trim(v_cfg.clabe), '')),
        cobro_enviado_en = now(),
        recordatorio_en = now() + v_cfg.horas_recordatorio * interval '1 hour',
        recordado_en = null,
        limite_pago = now() + v_cfg.horas_limite * interval '1 hour',
        liberar_en = now() + v_cfg.horas_liberar * interval '1 hour'
      where id = v_cid;
      v_cobros := v_cobros || live_texto_cobro(v_cid);
    elsif v_c.estado in ('por_pagar', 'pago_incompleto') then
      v_cobros := v_cobros || live_texto_cobro(v_cid);
    end if;
  end loop;

  v_lineas := live_texto_apartar(jsonb_build_object('tuyas', to_jsonb(v_tuyas), 'espera', v_espera,
                                                    'vendidas', to_jsonb(v_vend), 'limite', to_jsonb(v_lim)))
              || v_cobros;
  v_msg := array_to_string(v_lineas, E'\n');
  if coalesce(p_avisar, false) and v_msg <> '' and v_cl.telefono is not null then
    perform wa_encolar(v_cl.telefono,
      format('✅ Listo %s, ya quedaste registrada como @%s (%s). Lo que comentes en el live se te aparta solo. 💕',
             split_part(v_cl.nombre, ' ', 1), v_usr, live_red_nombre(v_red)) || E'\n' || v_msg,
      v_cl.id);
  end if;

  return jsonb_build_object('ligada', true, 'red', v_red, 'usuario', v_usr,
    'tuyas', to_jsonb(v_tuyas), 'ya', to_jsonb(v_ya), 'espera', v_espera, 'vendidas', to_jsonb(v_vend),
    'limite', to_jsonb(v_lim), 'lineas', to_jsonb(v_lineas));
end $$;

-- Quitar un usuario mal ligado
create or replace function public.live_desligar_red(p_red text, p_usuario text) returns void
language sql set search_path = public as $$
  delete from clientas_redes where red = lower(trim(p_red)) and usuario = live_usuario_norm(p_usuario)
$$;

-- ---------------------------------------------------------------------
-- 7. Vencimiento del provisional y acciones del panel
-- ---------------------------------------------------------------------
create or replace function public.live_soltar_reserva(r public.live_reservas, p_estado text) returns void
language plpgsql set search_path = public as $$
begin
  update live_reservas set estado = p_estado, actualizado_en = now() where id = r.id;
  if r.estado = 'provisional' then
    perform 1 from prendas where numero = r.prenda for update;
    update prendas set estado = 'disponible', actualizada_en = now()
     where numero = r.prenda and estado = 'apartada'
       and not exists (select 1 from live_apartados a where a.prenda = r.prenda and a.estado in ('apartada', 'pagada'));
    perform live_ofrecer_espera(r.prenda);
  end if;
end $$;

create or replace function public.live_revisar_reservas() returns jsonb
language plpgsql set search_path = public as $$
declare
  d live_dm;
  r live_reservas;
  v_dm integer := 0;
  v_pr integer := 0;
begin
  for d in select * from live_dm where estado = 'esperando' and vence_en <= now()
            order by vence_en for update skip locked loop
    for r in select * from live_reservas where dm_id = d.id and estado in ('provisional', 'espera')
              order by comentario_en for update loop
      perform live_soltar_reserva(r, 'vencida');
      if r.estado = 'provisional' then v_pr := v_pr + 1; end if;
    end loop;
    update live_dm set estado = 'vencida' where id = d.id;
    v_dm := v_dm + 1;
  end loop;
  return jsonb_build_object('vencidas', v_dm, 'prendas_liberadas', v_pr);
end $$;

-- La host marca "ya se lo pedí"
create or replace function public.live_dm_pedido(p_dm uuid, p_por text default null) returns void
language sql set search_path = public as $$
  update live_dm set pedido_en = coalesce(pedido_en, now()), pedido_por = coalesce(pedido_por, p_por)
   where id = p_dm and estado = 'esperando'
$$;

-- Darle más tiempo para registrarse
create or replace function public.live_dm_extender(p_dm uuid, p_minutos integer default null) returns timestamptz
language plpgsql set search_path = public as $$
declare v timestamptz;
begin
  update live_dm set vence_en = greatest(vence_en, now()) +
         coalesce(p_minutos, (select minutos_registro from live_config limit 1)) * interval '1 minute'
   where id = p_dm and estado = 'esperando'
  returning vence_en into v;
  if v is null then raise exception 'Ese aviso ya no está esperando.'; end if;
  return v;
end $$;

-- Soltar todo lo que pidió (no se registró / era broma)
create or replace function public.live_dm_cancelar(p_dm uuid) returns void
language plpgsql set search_path = public as $$
declare r live_reservas;
begin
  perform 1 from live_dm where id = p_dm and estado = 'esperando' for update;
  if not found then raise exception 'Ese aviso ya no está esperando.'; end if;
  for r in select * from live_reservas where dm_id = p_dm and estado in ('provisional', 'espera') for update loop
    perform live_soltar_reserva(r, 'cancelada');
  end loop;
  update live_dm set estado = 'cancelada' where id = p_dm;
end $$;

-- Quitar una sola prenda del provisional
create or replace function public.live_reserva_quitar(p_reserva uuid) returns void
language plpgsql set search_path = public as $$
declare r live_reservas;
begin
  select * into r from live_reservas where id = p_reserva and estado in ('provisional', 'espera') for update;
  if not found then raise exception 'Esa prenda ya no está en provisional.'; end if;
  perform live_soltar_reserva(r, 'cancelada');
end $$;

-- ---------------------------------------------------------------------
-- 8. El bot de WhatsApp ahora también registra a las clientas que comentaron
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
  v_txt_nums text;
  v_cfg live_config;
  v_cl clientas;
  v_live lives;
  v_c live_cuentas;
  v_nums integer[];
  v_arroba text[];
  v_handles text[];
  v_h text;
  v_red text;
  v_l jsonb;
  v_nombre text;
  v_pal text;
  v_nueva boolean := false;
  v_ligo boolean := false;
  v_ligadas integer[] := '{}';
  v_tuyas integer[] := '{}';
  v_r jsonb;
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

  -- Usuarios de redes que escribió: "@ana_23" o "mi usuario es ana_23"
  select coalesce(array_agg(distinct h), '{}') into v_arroba
    from (select regexp_replace(lower(m[1]), '\.+$', '') h
            from regexp_matches(v_txt, '@([A-Za-z0-9_.]{2,40})', 'g') m) s
   where length(h) >= 2;
  select coalesce(array_agg(distinct h order by h), '{}') into v_handles
    from (select unnest(v_arroba) h
          union
          select regexp_replace(lower(m[1]), '\.+$', '')
            from regexp_matches(v_txt, '(?:usuario|user|cuenta|perfil)\s*(?:de\s+[[:alpha:]]+\s*)?(?:es\s+|:\s*)?@?([A-Za-z0-9_.]{2,40})', 'gi') m) s
   where length(h) >= 2
     and h !~ '^(es|de|del|el|la|mi|tiktok|tik|facebook|face|fb|instagram|insta|ig|youtube|yt)$'
     and (case when v_sim then h like 'sim\_%' else h not like 'sim\_%' end);

  -- Candados en orden fijo (usuario → teléfono) para no chocar con el agente
  foreach v_h in array v_handles loop
    perform pg_advisory_xact_lock(hashtext('live-usr-' || v_h));
  end loop;
  perform pg_advisory_xact_lock(hashtext('live-tel-' || v_tel));
  select * into v_cfg from live_config limit 1;

  -- Nombre que escribió: "Soy Ana López", "me llamo Ana", "mi nombre es Ana"
  select string_agg(w, ' ' order by o) into v_nombre
    from (select w, o, bool_and(w !~* '^(y|e|mi|quiero|me|usuario|con|para|soy|por|que|en|el|la|de|del|las|los|tiktok|whats|whatsapp|face|facebook|insta|instagram|apartar|aparto|la)$')
                       over (order by o) as sigue
            from regexp_split_to_table(
                   (regexp_match(v_txt, '(?:soy|me llamo|mi nombre es)\s+([A-Za-zÁÉÍÓÚÑÜáéíóúñü]+(?:\s+[A-Za-zÁÉÍÓÚÑÜáéíóúñü]+){0,5})', 'i'))[1],
                   '\s+') with ordinality t(w, o)) s
   where sigue and o <= 4;
  if v_nombre is not null then v_nombre := initcap(lower(v_nombre)); end if;

  select * into v_cl from clientas where telefono = v_tel;
  if not found then
    insert into clientas (nombre, telefono, fecha_registro, creado_por)
    values (coalesce(v_nombre, nullif(trim(p_nombre), ''), 'Clienta ' || right(v_tel, 4)), v_tel,
            (now() at time zone v_cfg.zona_horaria)::date,
            case when v_sim then 'Simulador' else 'Bot WhatsApp' end)
    returning * into v_cl;
    v_nueva := true;
  elsif v_nombre is not null and v_cl.nombre ~ '^Clienta [0-9]{4}$' then
    update clientas set nombre = v_nombre where id = v_cl.id returning * into v_cl;
  end if;

  insert into wa_mensajes (direccion, telefono, wa_id, texto, clienta_id, estado, simulado, creado_en)
  values ('entrada', v_tel, p_wa_id, v_txt, v_cl.id, 'recibido', v_sim, v_recibido);

  select * into v_live from lives where estado = 'activo' and tipo = 'redes' limit 1;
  if v_nueva then
    v_lineas := v_lineas || '¡Bienvenida a Outlet Prime! 💕'::text;
  end if;

  -- Ligar sus usuarios de redes
  foreach v_h in array v_handles loop
    v_red := null;
    for v_red in select distinct red from live_dm where usuario = v_h and estado = 'esperando' loop
      v_l := live_ligar_red(v_cl.id, v_red, v_h, case when v_sim then 'Simulador' else 'Bot WhatsApp' end);
      if coalesce((v_l->>'conflicto')::boolean, false) then
        v_lineas := v_lineas || format('⚠️ El usuario @%s de %s ya está registrado con otro número. Si es tuyo, escríbenos y el equipo lo revisa.',
                                       v_h, live_red_nombre(v_red));
      else
        v_ligo := true;
        v_lineas := v_lineas || format('✅ Listo %s, ya quedaste registrada como @%s (%s).',
                                       split_part(v_cl.nombre, ' ', 1), v_h, live_red_nombre(v_red));
        v_lineas := v_lineas || array(select jsonb_array_elements_text(v_l->'lineas'));
        v_ligadas := v_ligadas || live_ints(v_l->'tuyas') || live_ints(v_l->'ya');
        v_tuyas := v_tuyas || live_ints(v_l->'tuyas');
        v_ligadas := v_ligadas || array(select (e->>'n')::integer from jsonb_array_elements(v_l->'espera') e)
                               || live_ints(v_l->'vendidas') || live_ints(v_l->'limite');
      end if;
    end loop;

    if v_red is null then
      -- No había aviso esperando: ¿se le venció el provisional?
      select red into v_red from live_dm where usuario = v_h and estado = 'vencida'
       order by creado_en desc limit 1;
      if v_red is not null then
        v_l := live_ligar_red(v_cl.id, v_red, v_h, case when v_sim then 'Simulador' else 'Bot WhatsApp' end);
        if coalesce((v_l->>'conflicto')::boolean, false) then
          v_lineas := v_lineas || format('⚠️ El usuario @%s ya está registrado con otro número. Si es tuyo, escríbenos y el equipo lo revisa.', v_h);
        else
          v_ligo := true;
          v_lineas := v_lineas || format('✅ Listo %s, ya quedaste registrada como @%s (%s). ⏰ Tu apartado provisional ya había vencido: comenta otra vez el número en el live y se te aparta al momento.',
                                         split_part(v_cl.nombre, ' ', 1), v_h, live_red_nombre(v_red));
        end if;
      elsif v_h = any (v_arroba) and not exists (select 1 from clientas_redes where usuario = v_h and clienta_id = v_cl.id) then
        -- Se registra antes de comentar: la ligamos en la red principal
        v_l := live_ligar_red(v_cl.id, v_cfg.red_principal, v_h, case when v_sim then 'Simulador' else 'Bot WhatsApp' end);
        if coalesce((v_l->>'conflicto')::boolean, false) then
          v_lineas := v_lineas || format('⚠️ El usuario @%s ya está registrado con otro número. Si es tuyo, escríbenos y el equipo lo revisa.', v_h);
        else
          v_ligo := true;
          v_lineas := v_lineas || format('✅ Listo %s, te registramos como @%s (%s).',
                                         split_part(v_cl.nombre, ' ', 1), v_h, live_red_nombre(v_cfg.red_principal));
        end if;
      end if;
    end if;
  end loop;
  if v_ligo then
    v_lineas := v_lineas || 'A partir de ahora, lo que comentes en el live se te aparta solo. 💕'::text;
  end if;

  -- Números de prenda (sin contar los que trae el @usuario)
  v_txt_nums := regexp_replace(v_txt, '@[A-Za-z0-9_.]+', ' ', 'g');
  foreach v_h in array v_handles loop
    v_txt_nums := regexp_replace(v_txt_nums, '(?<![A-Za-z0-9_.])' || regexp_replace(v_h, '([.])', '\\\1', 'g') || '(?![A-Za-z0-9_])', ' ', 'gi');
  end loop;
  select coalesce(array_agg(n order by o), '{}') into v_nums
    from (select (m[1])::integer as n, min(o) as o
            from regexp_matches(v_txt_nums, '(?<![0-9])([0-9]{1,5})(?![0-9])', 'g') with ordinality as t(m, o)
           group by 1) s
   where not n = any (v_ligadas);

  if cardinality(v_nums) = 0 then
    if v_ligo then
      null;
    elsif v_live.id is not null then
      v_lineas := v_lineas || format('Hola %s 👋 Para apartar comenta el número de la etiqueta en el live, o mándalo aquí (por ejemplo: 23). Puedes mandar varios: 23 45 310.',
                                     split_part(v_cl.nombre, ' ', 1));
    else
      select * into v_c from live_cuentas
       where clienta_id = v_cl.id and estado in ('por_pagar', 'pago_incompleto')
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
    v_r := live_apartar(v_live.id, v_cl.id, v_nums, v_recibido, 'whatsapp', null);
    v_lineas := v_lineas || live_texto_apartar(v_r);
    v_tuyas := v_tuyas || live_ints(v_r->'tuyas');
    if jsonb_array_length(v_r->'provisional_de_otra') > 0
       and not exists (select 1 from clientas_redes where clienta_id = v_cl.id) then
      v_lineas := v_lineas || format('🙋 Si tú comentaste %s en el live, mándanos tu usuario (por ejemplo @tu_usuario) para ligártela.',
        case when jsonb_array_length(v_r->'provisional_de_otra') = 1 then 'la ' || live_num((v_r->'provisional_de_otra'->>0)::integer)
             else live_lista(live_ints(v_r->'provisional_de_otra')) end);
    end if;
  end if;

  if v_live.id is not null then
    v_lineas := v_lineas || live_texto_resumen(v_live.id, v_cl.id);
  end if;

  v_resp := array_to_string(v_lineas, E'\n');
  v_salida := wa_encolar(v_tel, v_resp, v_cl.id);

  return jsonb_build_object(
    'clienta_id', v_cl.id,
    'nueva', v_nueva,
    'ligada', v_ligo,
    'respuesta', v_resp,
    'mensaje_id', v_salida,
    'apartadas', to_jsonb(v_tuyas),
    'espera', coalesce(v_r->'espera', '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- 9. Borrar datos de prueba (también comentarios y avisos simulados)
-- ---------------------------------------------------------------------
create or replace function public.live_borrar_simulacion() returns jsonb
language plpgsql set search_path = public as $$
declare
  v_cl uuid[];
  v_pr integer[];
  v_lives uuid[];
  v_ped integer;
  r live_reservas;
begin
  -- Provisionales de usuarias simuladas: regresan la prenda
  for r in select x.* from live_reservas x join live_dm d on d.id = x.dm_id
            where d.simulado and x.estado = 'provisional' for update of x loop
    update live_reservas set estado = 'cancelada' where id = r.id;
    update prendas set estado = 'disponible', actualizada_en = now()
     where numero = r.prenda and estado = 'apartada'
       and not exists (select 1 from live_apartados a where a.prenda = r.prenda and a.estado in ('apartada', 'pagada'));
  end loop;
  select coalesce(array_agg(distinct live_id), '{}') into v_lives from live_dm where simulado;
  delete from live_dm where simulado;
  delete from live_comentarios where simulado;

  select coalesce(array_agg(id), '{}') into v_cl from clientas where telefono like '00%';
  select coalesce(array_agg(distinct prenda), '{}') into v_pr
    from live_apartados where clienta_id = any (v_cl) and estado in ('apartada', 'pagada') and prenda is not null;
  select coalesce(array_agg(distinct live_id), '{}') || v_lives into v_lives
    from (select live_id from live_apartados where clienta_id = any (v_cl)
          union select live_id from live_cuentas where clienta_id = any (v_cl)) s;

  update prime_prendas p set estado = 'disponible'
    from live_apartados a
   where a.clienta_id = any (v_cl) and a.estado in ('apartada', 'pagada') and p.id = a.prime_prenda;
  update live_reservas set apartado_id = null
   where apartado_id in (select id from live_apartados where clienta_id = any (v_cl));
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
     and not exists (select 1 from live_apartados a where a.prenda = p.numero and a.estado in ('apartada', 'pagada'))
     and not exists (select 1 from live_reservas x where x.prenda = p.numero and x.estado = 'provisional');
  delete from lives l
   where l.id = any (v_lives) and l.estado = 'cerrado' and l.tipo = 'redes'
     and not exists (select 1 from live_apartados a where a.live_id = l.id)
     and not exists (select 1 from live_cuentas c where c.live_id = l.id)
     and not exists (select 1 from live_dm d where d.live_id = l.id);

  return jsonb_build_object('clientas', cardinality(v_cl), 'prendas', cardinality(v_pr), 'pedidos', v_ped);
end $$;

-- ---------------------------------------------------------------------
-- 10. Vistas para el panel
-- ---------------------------------------------------------------------
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

drop view if exists public.live_dm_tablero;
create view public.live_dm_tablero with (security_invoker = true) as
select d.*,
       greatest(0, extract(epoch from (d.vence_en - now())))::integer as segundos,
       coalesce((select array_agg(r.prenda order by r.comentario_en) from live_reservas r
                  where r.dm_id = d.id and r.estado = 'provisional'), '{}') as provisionales,
       coalesce((select array_agg(r.prenda order by r.comentario_en) from live_reservas r
                  where r.dm_id = d.id and r.estado = 'espera'), '{}') as en_espera,
       coalesce((select array_agg(r.prenda order by r.comentario_en) from live_reservas r
                  where r.dm_id = d.id and r.estado = 'confirmada'), '{}') as confirmadas,
       trim(cl.nombre || coalesce(' ' || cl.apellidos, '')) as clienta,
       (select c.casillero from live_cuentas c
         where c.live_id = d.live_id and c.clienta_id = d.clienta_id
           and c.estado in ('abierta', 'por_pagar', 'pago_incompleto', 'pagada')
         order by c.creada_en desc limit 1) as casillero,
       -- mismo @usuario ya ligado en otra red: probablemente es ella
       (select r.clienta_id from clientas_redes r where r.usuario = d.usuario and r.red <> d.red
         order by r.ligada_en desc limit 1) as sugerida_id,
       (select trim(c2.nombre || coalesce(' ' || c2.apellidos, '')) || ' (' || live_red_nombre(r.red) || ')'
          from clientas_redes r join clientas c2 on c2.id = r.clienta_id
         where r.usuario = d.usuario and r.red <> d.red
         order by r.ligada_en desc limit 1) as sugerida
  from live_dm d
  left join clientas cl on cl.id = d.clienta_id;

create or replace view public.live_comentarios_tablero with (security_invoker = true) as
select k.*, trim(cl.nombre || coalesce(' ' || cl.apellidos, '')) as clienta
  from live_comentarios k
  left join clientas cl on cl.id = k.clienta_id;

create or replace view public.clientas_redes_tablero with (security_invoker = true) as
select r.*, trim(cl.nombre || coalesce(' ' || cl.apellidos, '')) as clienta, cl.telefono
  from clientas_redes r
  join clientas cl on cl.id = r.clienta_id;

revoke all on public.live_feed, public.live_dm_tablero, public.live_comentarios_tablero, public.clientas_redes_tablero from anon;
grant select on public.live_feed, public.live_dm_tablero, public.live_comentarios_tablero, public.clientas_redes_tablero
  to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 11. Permisos de las funciones (solo el equipo con sesión y el servidor)
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('live_usuario_norm', 'live_ints', 'live_red_nombre', 'live_texto_dm', 'live_apartar',
                                'live_texto_apartar', 'live_comentario', 'live_ligar_red', 'live_desligar_red',
                                'live_soltar_reserva', 'live_revisar_reservas', 'live_dm_pedido', 'live_dm_extender',
                                'live_dm_cancelar', 'live_reserva_quitar', 'bot_mensaje', 'live_borrar_simulacion') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 12. Cada minuto: soltar los provisionales que no se registraron a tiempo
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('live-reservas', '* * * * *', 'select public.live_revisar_reservas()');
  else
    raise notice 'pg_cron no está activo: live_revisar_reservas() hay que llamarla de otra forma.';
  end if;
end $$;
