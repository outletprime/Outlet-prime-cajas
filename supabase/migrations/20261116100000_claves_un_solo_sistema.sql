-- =====================================================================
-- Claves de prenda con letras y un solo sistema para el live
--
-- Claves: de A1 a ZY98, pensadas para no confundirse:
--   · letras sin O, I, L ni Ñ (no se confunden con 0, 1 ni N)
--   · dos letras siempre distintas (AB sí, AA no)
--   · números del 1 al 98 sin dígitos repetidos (11, 22 … 88 y 99 no existen)
-- Cada clave equivale a un número interno (prendas.numero, 1..52371); el panel, los
-- mensajes y los avisos muestran la clave.
--
-- Un solo sistema: el agente con IA (live_comentario) y el bot de WhatsApp con registro
-- por @usuario. Lo del 14 nov (clientas.tiktok, tiktok_ligar) se respeta: quien se
-- registró con "tiktok @usuario" también se reconoce al comentar.
-- Se puede pegar varias veces sin dañar nada. Ya está aplicada en Supabase (16 nov 2026, como
-- claves_a1_zy98 + un_solo_sistema_live).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Claves
-- ---------------------------------------------------------------------
-- ¿El número interno corresponde a una clave válida? (sin 11, 22 … 99)
create or replace function public.clave_valida(p integer)
returns boolean language sql immutable as $$
  select p between 1 and 52371 and ((p - 1) % 99 + 1) <= 98 and ((p - 1) % 99 + 1) % 11 <> 0
$$;

create or replace function public.clave_a_num(p text)
returns integer language plpgsql immutable set search_path to 'public' as $$
declare
  l constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ';
  s text := upper(regexp_replace(coalesce(p, ''), '[[:space:]#-]', '', 'g'));
  m text[]; a int; b int; n int;
begin
  m := regexp_match(s, '^([A-Z]{1,2})([0-9]{1,2})$');
  if m is null then return null; end if;
  n := m[2]::int;
  if n < 1 or n > 98 or n % 11 = 0 then return null; end if;   -- sin 11, 22 … 88
  a := strpos(l, substr(m[1], 1, 1)) - 1;
  if a < 0 then return null; end if;
  if length(m[1]) = 1 then return a * 99 + n; end if;
  b := strpos(l, substr(m[1], 2, 1)) - 1;
  if b < 0 or b = a then return null; end if;                   -- sin AA, BB…
  if b > a then b := b - 1; end if;
  return 2277 + (a * 22 + b) * 99 + n;
end $$;

create or replace function public.num_a_clave(p integer)
returns text language plpgsql immutable set search_path to 'public' as $$
declare
  l constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ';
  k int; a int; b int; n int;
begin
  if p is null or p < 1 or p > 52371 then return null; end if;
  if p <= 2277 then
    return substr(l, (p - 1) / 99 + 1, 1) || ((p - 1) % 99 + 1);
  end if;
  k := p - 2278;
  n := k % 99 + 1;
  k := k / 99;
  a := k / 22;
  b := k % 22;
  if b >= a then b := b + 1; end if;
  return substr(l, a + 1, 1) || substr(l, b + 1, 1) || n;
end $$;

-- Mensajes, avisos y etiquetas muestran la clave (AB12) en lugar del número interno
create or replace function public.live_num(p integer)
returns text language sql immutable set search_path to 'public' as $$
  select coalesce(public.num_a_clave(p), lpad(p::text, 4, '0'))
$$;

alter table public.prendas
  add column if not exists clave text generated always as (public.num_a_clave(numero)) stored;
create unique index if not exists prendas_clave_key on public.prendas (clave);
alter table public.prendas drop constraint if exists prendas_numero_clave;
alter table public.prendas add constraint prendas_numero_clave check (numero <= 52371);

-- Usuario de TikTok de la clienta (también lo usa el registro "tiktok @usuario")
alter table public.clientas add column if not exists tiktok text;
create unique index if not exists clientas_tiktok_key on public.clientas (lower(tiktok)) where tiktok is not null;

-- Registrar prendas por rango de claves, p. ej. ('A1', 'C98'): solo las claves válidas
create or replace function public.live_registrar_claves(p_desde text, p_hasta text, p_precio numeric default null, p_usuario text default null)
returns integer language plpgsql set search_path to 'public' as $$
declare
  d int := clave_a_num(p_desde);
  h int := clave_a_num(p_hasta);
  v_precio numeric;
  v_n integer;
begin
  if d is null then raise exception 'Clave inválida: % (usa de A1 a ZY98, sin O, I, L, sin letras repetidas y sin 11, 22…)', p_desde; end if;
  if h is null then raise exception 'Clave inválida: % (usa de A1 a ZY98, sin O, I, L, sin letras repetidas y sin 11, 22…)', p_hasta; end if;
  if h < d then raise exception 'La segunda clave debe ir después de la primera.'; end if;
  if h - d >= 5000 then raise exception 'Registra como máximo 5,000 prendas a la vez.'; end if;
  select coalesce(p_precio, precio) into v_precio from live_config limit 1;
  insert into prendas (numero, precio, registrada_por)
  select g, v_precio, p_usuario from generate_series(d, h) g where clave_valida(g)
  on conflict (numero) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Cuántas claves válidas hay en un rango (para el mensaje del panel)
create or replace function public.claves_en_rango(p_desde text, p_hasta text)
returns integer language sql immutable set search_path to 'public' as $$
  select count(*)::integer from generate_series(clave_a_num(p_desde), clave_a_num(p_hasta)) g where clave_valida(g)
$$;

-- Claves escritas en un texto: "AB12", "ab12", "AB-12"; con espacio ("ab 12") solo si es todo el texto
create or replace function public.tiktok_claves(p_texto text)
returns integer[] language plpgsql immutable set search_path to 'public' as $$
declare
  v text := upper(coalesce(p_texto, ''));
  r integer[];
  m text[];
begin
  select coalesce(array_agg(n order by o), '{}') into r from (
    select clave_a_num(x[1] || x[2]) n, min(o) o
      from regexp_matches(v, '(?<![[:alnum:]_])([A-Z]{1,2})-?([0-9]{1,2})(?![[:alnum:]_])', 'g') with ordinality t(x, o)
     group by 1) s
   where n is not null;
  if cardinality(r) > 0 then return r; end if;
  m := regexp_match(v, '^[^[:alnum:]]*([A-Z]{1,2})[[:space:]]+([0-9]{1,2})[^[:alnum:]]*$');
  if m is not null and clave_a_num(m[1] || m[2]) is not null then
    return array[clave_a_num(m[1] || m[2])];
  end if;
  return '{}';
end $$;

-- Prendas que se registraron antes con 11, 22 … 99: se dan de baja si nunca se usaron
update public.prendas p set estado = 'baja', actualizada_en = now()
 where not clave_valida(p.numero) and p.estado = 'disponible'
   and not exists (select 1 from live_apartados a where a.prenda = p.numero);

-- El mensaje de bienvenida del DM habla de claves
update public.live_config set mensaje_dm =
  '¡Hola! 💕 Para apartar tu prenda mándanos un WhatsApp al {whatsapp} con tu nombre, tu usuario ({usuario}) y la clave de la prenda (por ejemplo A23). Después de eso, todo lo que comentes en el live se te aparta solo.'
 where mensaje_dm like '%y el número de la prenda.%';
alter table public.live_config alter column mensaje_dm set default
  '¡Hola! 💕 Para apartar tu prenda mándanos un WhatsApp al {whatsapp} con tu nombre, tu usuario ({usuario}) y la clave de la prenda (por ejemplo A23). Después de eso, todo lo que comentes en el live se te aparta solo.';

-- ---------------------------------------------------------------------
-- 2. Comentario del live: también reconoce a quien se registró con "tiktok @usuario"
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
    if not found and v_red = 'tiktok' then
      -- Registrada con "tiktok @usuario" (columna clientas.tiktok): se liga sola
      select * into v_cl from clientas where lower(tiktok) = v_usr and telefono is not null;
      if found then
        insert into clientas_redes (clienta_id, red, usuario, ligada_por)
        values (v_cl.id, 'tiktok', v_usr, 'clientas.tiktok') on conflict (red, usuario) do nothing;
      end if;
    end if;

    if v_cl.id is not null then
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
-- 3. Ligar @usuario ↔ clienta: mantiene al día clientas.tiktok y junta lo del agente anterior
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
  if not found and v_red = 'tiktok' then
    -- también cuenta quien ya lo registró con "tiktok @usuario" (y tiene WhatsApp)
    select id into v_otra from clientas where lower(tiktok) = v_usr and id <> p_clienta and telefono is not null;
    if found then
      if not coalesce(p_forzar, false) then
        return jsonb_build_object('conflicto', true, 'red', v_red, 'usuario', v_usr,
          'clienta_actual', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = v_otra));
      end if;
      update clientas set tiktok = null where id = v_otra;
    end if;
    v_otra := null;
  end if;
  if v_otra is not null and v_otra <> p_clienta then
    if not coalesce(p_forzar, false) then
      return jsonb_build_object('conflicto', true, 'red', v_red, 'usuario', v_usr,
        'clienta_actual', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = v_otra));
    end if;
    update clientas_redes set clienta_id = p_clienta, ligada_en = now(), ligada_por = p_por
     where red = v_red and usuario = v_usr;
  elsif v_otra is null then
    insert into clientas_redes (clienta_id, red, usuario, ligada_por) values (p_clienta, v_red, v_usr, p_por);
  end if;

  if v_red = 'tiktok' then
    if exists (select 1 from clientas where lower(tiktok) = v_usr and id <> p_clienta and telefono is null)
       and to_regprocedure('public.tiktok_ligar(uuid,text)') is not null then
      -- Clienta provisional del agente anterior: se juntan sus apartados con esta clienta
      execute 'select public.tiktok_ligar($1, $2)' using p_clienta, v_usr;
    else
      update clientas set tiktok = v_usr where id = p_clienta and tiktok is null
        and not exists (select 1 from clientas x where lower(x.tiktok) = v_usr and x.id <> p_clienta);
    end if;
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


-- ---------------------------------------------------------------------
-- 4. Bot de WhatsApp (uno solo): registra con @usuario o "tiktok @usuario", liga lo que
--    comentó en el live y también aparta por clave mandada por WhatsApp (respaldo)
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
            from regexp_matches(v_txt, '(?:usuario|user|cuenta|perfil|tik\s*tok)\s*(?:de\s+[[:alpha:]]+\s*)?(?:es\s+|:\s*)?@?([A-Za-z0-9_.]{2,40})', 'gi') m) s
   where length(h) >= 2
     and h !~ '^(es|de|del|el|la|las|los|lo|mi|me|yo|en|por|para|quiero|soy|y|live|tiktok|tik|tok|facebook|face|fb|instagram|insta|ig|youtube|yt)$'
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
  -- Claves de prenda (A23, AB7, ab-7…), sin contar las que ya se resolvieron al ligarla
  select coalesce(array_agg(n order by o), '{}') into v_nums
    from unnest(tiktok_claves(v_txt_nums)) with ordinality t(n, o)
   where not n = any (v_ligadas);

  if cardinality(v_nums) = 0 then
    if v_ligo then
      null;
    elsif v_live.id is not null then
      v_lineas := v_lineas || format('Hola %s 👋 Para apartar comenta la clave de la prenda en el live, o mándala aquí (por ejemplo: A23). Puedes mandar varias: A23 B7 AC15.',
                                     split_part(v_cl.nombre, ' ', 1));
      if not exists (select 1 from clientas_redes where clienta_id = v_cl.id) and v_cl.tiktok is null then
        v_lineas := v_lineas || 'Para reconocerte en el live, mándanos tu usuario así: tiktok @tuusuario'::text;
      end if;
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
-- 5. Permisos
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('live_comentario', 'live_ligar_red', 'bot_mensaje', 'live_registrar_claves') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;
grant execute on function public.clave_valida(integer), public.clave_a_num(text), public.num_a_clave(integer),
  public.live_num(integer), public.tiktok_claves(text), public.claves_en_rango(text, text) to authenticated, service_role;
