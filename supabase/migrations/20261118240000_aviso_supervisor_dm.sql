-- Clientas nuevas: además del aviso "Pide DM" a quien presenta, le llega un aviso al Supervisor para que
-- la registre a mano con su usuario, nombre y apellido cuando mande su DM (uno por clienta, no por comentario).
-- El mensaje del DM ya no pide WhatsApp: solo nombre y por lo menos un apellido.
create or replace function public.avisos_pide_dm() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  d live_dm;
  v_prendas integer[];
  v_min integer;
begin
  if new.estado <> 'provisional' then return null; end if;
  select * into d from live_dm where id = new.dm_id;
  if not found or d.estado <> 'esperando' then return null; end if;
  select coalesce(array_agg(prenda order by prenda), '{}') into v_prendas
    from live_reservas where dm_id = d.id and estado = 'provisional' and comentario_en = new.comentario_en;
  if cardinality(v_prendas) = 0 then return null; end if;
  v_min := greatest(1, ceil(extract(epoch from (d.vence_en - now())) / 60))::integer;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('dm', 'dm:' || d.id || ':' || extract(epoch from new.comentario_en),
          format('🙋 Pide DM a @%s%s', d.usuario, case when d.simulado then ' (prueba)' else '' end),
          format('%s · fue la primera en pedir %s · tiene %s min para registrarse',
                 live_red_nombre(d.red),
                 case when cardinality(v_prendas) = 1 then 'la ' || live_num(v_prendas[1]) else live_lista(v_prendas) end,
                 v_min),
          'live.html#dm', 'presentadora')
  on conflict (clave) do nothing;
  -- Al Supervisor: registrarla cuando mande su nombre por DM
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('dm', 'dm-sup:' || d.id,
          format('📝 Registrar a @%s%s', d.usuario, case when d.simulado then ' (prueba)' else '' end),
          format('Clienta nueva de %s · pidió %s. Cuando mande por DM su nombre y apellido: En vivo → Pide DM → Registrar a mano. Tiene %s min.',
                 live_red_nombre(d.red),
                 case when cardinality(v_prendas) = 1 then 'la ' || live_num(v_prendas[1]) else live_lista(v_prendas) end,
                 v_min),
          'live.html#vivo', 'supervisor')
  on conflict (clave) do nothing;
  return null;
end $$;

update public.live_config set mensaje_dm =
  '¡Hola {usuario}! 💕 Para apartarte tus prendas mándanos por aquí tu nombre y por lo menos un apellido. Después de eso, todo lo que comentes en el live se te aparta solo.';
