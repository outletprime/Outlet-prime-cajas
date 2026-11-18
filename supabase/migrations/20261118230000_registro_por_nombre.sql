-- =====================================================================
-- Registro de clientas nuevas solo con nombre y apellido (sin pedir WhatsApp por TikTok).
--  1. Cada aviso "Pide DM" trae un código único para su enlace de registro (registro.html?t=…).
--  2. La clienta abre el enlace, escribe su nombre y apellido, y queda registrada con su usuario:
--     lo que pidió pasa a su casillero y a Operación live le llega el aviso para acomodarlo.
--  3. El equipo también puede registrarla a mano con solo su nombre (sin WhatsApp).
-- =====================================================================

-- 1. Código del enlace (difícil de adivinar: 20 caracteres al azar)
alter table public.live_dm add column if not exists token text
  default left(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 24);
update public.live_dm set token = left(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 24) where token is null;
alter table public.live_dm alter column token set not null;
create unique index if not exists live_dm_token_key on public.live_dm (token);

create or replace view public.live_dm_tablero with (security_invoker = true) as
 SELECT d.id, d.live_id, d.red, d.usuario, d.nombre_visible, d.estado, d.primer_comentario_en, d.vence_en,
    d.pedido_en, d.pedido_por, d.clienta_id, d.registrada_en, d.simulado, d.creado_en,
    (GREATEST((0)::numeric, EXTRACT(epoch FROM (d.vence_en - now()))))::integer AS segundos,
    COALESCE(( SELECT array_agg(r.prenda ORDER BY r.comentario_en) FROM live_reservas r
          WHERE r.dm_id = d.id AND r.estado = 'provisional'), '{}'::integer[]) AS provisionales,
    COALESCE(( SELECT array_agg(r.prenda ORDER BY r.comentario_en) FROM live_reservas r
          WHERE r.dm_id = d.id AND r.estado = 'espera'), '{}'::integer[]) AS en_espera,
    COALESCE(( SELECT array_agg(r.prenda ORDER BY r.comentario_en) FROM live_reservas r
          WHERE r.dm_id = d.id AND r.estado = 'confirmada'), '{}'::integer[]) AS confirmadas,
    TRIM(BOTH FROM (cl.nombre || COALESCE((' '::text || cl.apellidos), ''::text))) AS clienta,
    ( SELECT c.casillero FROM live_cuentas c
          WHERE c.live_id = d.live_id AND c.clienta_id = d.clienta_id
            AND c.estado = ANY (ARRAY['abierta', 'por_pagar', 'pago_incompleto', 'pagada'])
          ORDER BY c.creada_en DESC LIMIT 1) AS casillero,
    ( SELECT r.clienta_id FROM clientas_redes r
          WHERE r.usuario = d.usuario AND r.red <> d.red ORDER BY r.ligada_en DESC LIMIT 1) AS sugerida_id,
    ( SELECT TRIM(BOTH FROM (c2.nombre || COALESCE((' '::text || c2.apellidos), ''::text))) || ' (' || live_red_nombre(r.red) || ')'
           FROM clientas_redes r JOIN clientas c2 ON c2.id = r.clienta_id
          WHERE r.usuario = d.usuario AND r.red <> d.red ORDER BY r.ligada_en DESC LIMIT 1) AS sugerida,
    d.token
   FROM live_dm d
     LEFT JOIN clientas cl ON cl.id = d.clienta_id;

-- Nombre bonito: sin espacios de más y con mayúscula inicial
create or replace function public.live_nombre_limpio(p text) returns text
language sql immutable set search_path = public as $$
  select nullif(initcap(lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g'))), '')
$$;

-- 2. Registro con nombre y apellido (lo usan el enlace y el panel; nadie lo llama directo)
create or replace function public.live_dm_registrar(p_dm uuid, p_nombre text, p_apellidos text, p_por text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d live_dm;
  v_nom text := live_nombre_limpio(p_nombre);
  v_ape text := live_nombre_limpio(p_apellidos);
  v_cl uuid;
  v_cfg live_config;
  r jsonb;
  v_cas text;
begin
  select * into d from live_dm where id = p_dm for update;
  if not found then raise exception 'Ese aviso ya no existe.'; end if;
  if d.estado = 'cancelada' then raise exception 'Este registro ya no está activo.'; end if;
  if v_nom is null or length(v_nom) < 2 or length(v_nom) > 40 or v_nom !~ '^[[:alpha:] .''-]+$' then
    raise exception 'Escribe tu nombre (solo letras).';
  end if;
  if v_ape is null or length(v_ape) < 2 or length(v_ape) > 60 or v_ape !~ '^[[:alpha:] .''-]+$' then
    raise exception 'Escribe por lo menos un apellido (solo letras).';
  end if;

  -- Si ese usuario ya es de una clienta, se usa la misma (no se duplica)
  select clienta_id into v_cl from clientas_redes where red = d.red and usuario = d.usuario;
  if v_cl is null and d.red = 'tiktok' then
    select id into v_cl from clientas where lower(tiktok) = d.usuario order by telefono nulls last limit 1;
  end if;
  if v_cl is not null then
    -- Clienta que el agente dio de alta solo con su usuario: se le pone su nombre real
    update clientas set nombre = v_nom, apellidos = v_ape
     where id = v_cl and telefono is null and apellidos is null;
  else
    select * into v_cfg from live_config limit 1;
    insert into clientas (nombre, apellidos, fecha_registro, creado_por)
    values (v_nom, v_ape, (now() at time zone v_cfg.zona_horaria)::date, coalesce(p_por, 'Registro por enlace'))
    returning id into v_cl;
  end if;

  r := live_ligar_red(v_cl, d.red, d.usuario, coalesce(p_por, 'Registro por enlace'), true, false);
  -- Si su aviso ya había vencido, igual queda como registrada (lo que comente desde ahora se le aparta)
  update live_dm set estado = 'registrada', clienta_id = v_cl, registrada_en = now() where id = d.id and estado <> 'registrada';

  select c.casillero into v_cas from live_cuentas c
   where c.live_id = d.live_id and c.clienta_id = v_cl and c.estado in ('abierta', 'por_pagar', 'pago_incompleto')
   order by c.creada_en desc limit 1;
  perform avisos_encolar('tiktok', 'registro:' || d.id,
    format('🔗 @%s ya se registró · %s', d.usuario, (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = v_cl)),
    case when jsonb_array_length(coalesce(r->'tuyas', '[]')) > 0
         then format('%s → casillero %s', (select live_unir(array_agg(live_num(x::int))) from jsonb_array_elements_text(r->'tuyas') x),
                     coalesce(v_cas, 'CARRO'))
         else 'Sin prendas pendientes; lo que comente desde ahora se le aparta solo.' end,
    'live.html#vivo');

  return r || jsonb_build_object(
    'clienta', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = v_cl),
    'nombre', (select split_part(nombre, ' ', 1) from clientas where id = v_cl),
    'tuyas_txt', (select live_unir(array_agg(live_num(x::int))) from jsonb_array_elements_text(coalesce(r->'tuyas', '[]')) x),
    'espera_txt', (select live_unir(array_agg(live_num((x->>'n')::int))) from jsonb_array_elements(coalesce(r->'espera', '[]')) x),
    'vendidas_txt', (select live_unir(array_agg(live_num(x::int))) from jsonb_array_elements_text(coalesce(r->'vendidas', '[]')) x));
end $$;
revoke all on function public.live_dm_registrar(uuid, text, text, text) from public, anon, authenticated;

-- Desde el panel: registrar a mano con solo su nombre (Dueña, Operación y Supervisor)
create or replace function public.live_dm_nombre(p_dm uuid, p_nombre text, p_apellidos text, p_por text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion', 'supervisor')) then
    raise exception 'Tu nivel de acceso no permite hacer esto.';
  end if;
  return live_dm_registrar(p_dm, p_nombre, p_apellidos,
    coalesce(nullif(trim(p_por), ''), (select email from equipo where usuario_id = auth.uid())));
end $$;
revoke all on function public.live_dm_nombre(uuid, text, text, text) from public, anon;
grant execute on function public.live_dm_nombre(uuid, text, text, text) to authenticated, service_role;

-- Desde el enlace (sin iniciar sesión): ver a quién es el enlace y registrarse
create or replace function public.registro_ver(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d live_dm;
begin
  if length(coalesce(p_token, '')) < 16 then return jsonb_build_object('valido', false); end if;
  select * into d from live_dm where token = p_token;
  if not found or d.estado = 'cancelada' then return jsonb_build_object('valido', false); end if;
  return jsonb_build_object('valido', true, 'usuario', d.usuario, 'red', live_red_nombre(d.red),
    'registrada', d.estado = 'registrada',
    'nombre', (select split_part(nombre, ' ', 1) from clientas where id = d.clienta_id),
    'prendas', (select live_unir(array_agg(live_num(r.prenda) order by r.comentario_en))
                  from live_reservas r where r.dm_id = d.id and r.estado in ('provisional', 'espera')));
end $$;

create or replace function public.registro_enviar(p_token text, p_nombre text, p_apellidos text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d live_dm;
begin
  if length(coalesce(p_token, '')) < 16 then raise exception 'Este enlace no es válido.'; end if;
  select * into d from live_dm where token = p_token;
  if not found or d.estado = 'cancelada' then raise exception 'Este enlace no es válido. Escríbenos por DM.'; end if;
  if d.estado = 'registrada' then
    return jsonb_build_object('ya', true, 'nombre', (select split_part(nombre, ' ', 1) from clientas where id = d.clienta_id));
  end if;
  return live_dm_registrar(d.id, p_nombre, p_apellidos, 'Registro por enlace');
end $$;

revoke all on function public.registro_ver(text) from public;
revoke all on function public.registro_enviar(text, text, text) from public;
grant execute on function public.registro_ver(text) to anon, authenticated, service_role;
grant execute on function public.registro_enviar(text, text, text) to anon, authenticated, service_role;
