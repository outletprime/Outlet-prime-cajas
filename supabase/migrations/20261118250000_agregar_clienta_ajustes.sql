-- Ajustes → Agregar clienta (Dueña y Supervisor): con los datos que mandó por DM se registra a la
-- clienta con su @usuario, nombre y apellido (WhatsApp opcional). Si tenía un aviso "Pide DM"
-- pendiente, lo que pidió pasa a su casillero igual que con "Registrar a mano".
create or replace function public.live_clienta_agregar(p_red text, p_usuario text, p_nombre text, p_apellidos text,
                                                      p_telefono text default null, p_por text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_red text := lower(trim(coalesce(nullif(p_red, ''), 'tiktok')));
  v_usr text := live_usuario_norm(p_usuario);
  v_nom text := live_nombre_limpio(p_nombre);
  v_ape text := live_nombre_limpio(p_apellidos);
  v_tel text;
  v_por text := coalesce(nullif(trim(p_por), ''), (select email from equipo where usuario_id = auth.uid()));
  v_otra uuid;
  v_cl clientas;
  v_cfg live_config;
  r jsonb;
  v_nueva boolean := false;
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'supervisor')) then
    raise exception 'Solo Dueña y Supervisor pueden agregar clientas.';
  end if;
  if v_red not in ('tiktok', 'facebook', 'instagram', 'youtube') then raise exception 'Elige la red social.'; end if;
  if v_usr is null then raise exception 'Escribe su usuario.'; end if;
  if v_nom is null or length(v_nom) < 2 or length(v_nom) > 40 or v_nom !~ '^[[:alpha:] .''-]+$' then
    raise exception 'Escribe su nombre (solo letras).';
  end if;
  if v_ape is null or length(v_ape) < 2 or length(v_ape) > 60 or v_ape !~ '^[[:alpha:] .''-]+$' then
    raise exception 'Escribe por lo menos un apellido (solo letras).';
  end if;
  if nullif(trim(coalesce(p_telefono, '')), '') is not null then
    v_tel := live_tel10(p_telefono);
    if length(v_tel) <> 10 then raise exception 'El WhatsApp debe tener 10 dígitos (o déjalo vacío).'; end if;
  end if;

  -- Ese usuario ya es de alguien: no se duplica ni se le quita a otra
  select clienta_id into v_otra from clientas_redes where red = v_red and usuario = v_usr;
  if v_otra is null and v_red = 'tiktok' then
    select id into v_otra from clientas where lower(tiktok) = v_usr and telefono is not null limit 1;
  end if;
  if v_otra is not null then
    raise exception '@% ya está registrado como %.', v_usr,
      (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = v_otra);
  end if;

  -- Si dio un WhatsApp que ya es de una clienta, se le liga a ella; si no, se crea
  if v_tel is not null then select * into v_cl from clientas where telefono = v_tel; end if;
  if v_cl.id is null then
    select * into v_cfg from live_config limit 1;
    insert into clientas (nombre, apellidos, telefono, fecha_registro, creado_por)
    values (v_nom, v_ape, v_tel, (now() at time zone v_cfg.zona_horaria)::date, coalesce(v_por, 'Panel'))
    returning * into v_cl;
    v_nueva := true;
  end if;

  r := live_ligar_red(v_cl.id, v_red, v_usr, v_por, false, false);
  if coalesce((r->>'conflicto')::boolean, false) then
    raise exception '@% ya está registrado como %.', v_usr, r->>'clienta_actual';
  end if;
  -- Un aviso "Pide DM" que ya había vencido también queda como registrado
  update live_dm set estado = 'registrada', clienta_id = v_cl.id, registrada_en = now()
   where red = v_red and usuario = v_usr and estado = 'vencida';

  return r || jsonb_build_object(
    'clienta', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = v_cl.id),
    'existente', not v_nueva,
    'tuyas_txt', (select live_unir(array_agg(live_num(x::int))) from jsonb_array_elements_text(coalesce(r->'tuyas', '[]')) x),
    'espera_txt', (select live_unir(array_agg(live_num((x->>'n')::int))) from jsonb_array_elements(coalesce(r->'espera', '[]')) x),
    'vendidas_txt', (select live_unir(array_agg(live_num(x::int))) from jsonb_array_elements_text(coalesce(r->'vendidas', '[]')) x));
end $$;

revoke all on function public.live_clienta_agregar(text, text, text, text, text, text) from public, anon;
grant execute on function public.live_clienta_agregar(text, text, text, text, text, text) to authenticated, service_role;
