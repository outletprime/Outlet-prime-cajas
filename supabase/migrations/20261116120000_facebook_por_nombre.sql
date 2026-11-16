-- =====================================================================
-- Facebook no tiene @usuario: el agente usa el nombre de la persona sin espacios ni acentos
-- ("Ana Gómez" → anagomez). Cuando una clienta escribe al bot, si su nombre (el que escribe
-- "soy Ana Gómez", el de su perfil de WhatsApp o el que ya tenemos) coincide con alguien que
-- comentó en Facebook y está esperando DM, se liga sola y lo que pidió pasa a su casillero.
-- Se puede pegar varias veces sin dañar nada.
-- =====================================================================
do $m$
declare d text; n text;
begin
  d := pg_get_functiondef('public.bot_mensaje(text,text,text,text,timestamptz)'::regprocedure);
  if position('Facebook no tiene @usuario' in d) > 0 then return; end if;   -- ya estaba
  n := replace(d,
    $x$  if v_ligo then
    v_lineas := v_lineas || 'A partir de ahora, lo que comentes en el live se te aparta solo. 💕'::text;
  end if;$x$,
    $x$  -- Facebook no tiene @usuario: si su nombre coincide con quien comentó en Facebook y espera DM, se liga sola
  for v_h in select distinct d.usuario from live_dm d
              where d.estado = 'esperando' and d.red = 'facebook'
                and d.usuario in (live_usuario_norm(v_nombre), live_usuario_norm(p_nombre),
                                  live_usuario_norm(v_cl.nombre || coalesce(' ' || v_cl.apellidos, '')))
                and not exists (select 1 from clientas_redes r where r.red = 'facebook' and r.usuario = d.usuario) loop
    v_l := live_ligar_red(v_cl.id, 'facebook', v_h, case when v_sim then 'Simulador' else 'Bot WhatsApp' end);
    if not coalesce((v_l->>'conflicto')::boolean, false) then
      v_ligo := true;
      v_lineas := v_lineas || format('✅ Listo %s, te reconocimos de tu comentario en Facebook.', split_part(v_cl.nombre, ' ', 1));
      v_lineas := v_lineas || array(select jsonb_array_elements_text(v_l->'lineas'));
      v_ligadas := v_ligadas || live_ints(v_l->'tuyas') || live_ints(v_l->'ya');
      v_tuyas := v_tuyas || live_ints(v_l->'tuyas');
      v_ligadas := v_ligadas || array(select (e->>'n')::integer from jsonb_array_elements(v_l->'espera') e)
                             || live_ints(v_l->'vendidas') || live_ints(v_l->'limite');
    end if;
  end loop;

  if v_ligo then
    v_lineas := v_lineas || 'A partir de ahora, lo que comentes en el live se te aparta solo. 💕'::text;
  end if;$x$);
  if n = d then raise exception 'bot_mensaje: no se encontró dónde agregar lo de Facebook'; end if;
  execute n;
end $m$;

revoke all on function public.bot_mensaje(text, text, text, text, timestamptz) from public, anon;
grant execute on function public.bot_mensaje(text, text, text, text, timestamptz) to authenticated, service_role;
