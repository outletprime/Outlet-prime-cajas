-- "Se arrepintió": quien acomoda (Operación live), además de Dueña y Operación, puede quitarle a una clienta
-- una prenda apartada que ya no quiere. Pasa sola a la primera en espera (o vuelve a estar disponible),
-- igual que "Liberar". Solo prendas sin pagar. Queda anotado quién lo hizo y se avisa al equipo.
alter table public.live_apartados add column if not exists liberada_por text;
alter table public.live_apartados add column if not exists liberada_motivo text;

-- Para la confirmación: de quién es y a quién pasaría
create or replace function public.live_arrepentimiento_info(p_apartado uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  a live_apartados;
  v_sig text;
begin
  if not puede_acomodar() then raise exception 'Tu nivel de acceso no permite hacer esto.'; end if;
  select * into a from live_apartados where id = p_apartado;
  if not found or a.estado <> 'apartada' then raise exception 'Esa prenda ya no está apartada (o ya se pagó).'; end if;
  if a.prenda is not null then
    select trim(cl.nombre || coalesce(' ' || cl.apellidos, '')) into v_sig
      from live_apartados e join clientas cl on cl.id = e.clienta_id
     where e.prenda = a.prenda and e.estado = 'espera'
     order by e.mensaje_en, e.creado_en limit 1;
  end if;
  return jsonb_build_object(
    'clave', coalesce(live_num(a.prenda), '#' || (select num from prime_prendas where id = a.prime_prenda)),
    'clienta', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = a.clienta_id),
    'siguiente', v_sig);
end $$;

create or replace function public.live_se_arrepintio(p_apartado uuid, p_por text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a live_apartados;
  v_por text := coalesce(nullif(trim(p_por), ''), (select email from equipo where usuario_id = auth.uid()));
  v_cl text;
  v_clave text;
  v_nueva text;
  v_cas text;
begin
  if not puede_acomodar() then raise exception 'Tu nivel de acceso no permite hacer esto.'; end if;
  select * into a from live_apartados where id = p_apartado for update;
  if not found or a.estado <> 'apartada' then raise exception 'Esa prenda ya no está apartada (o ya se pagó).'; end if;
  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;
  v_clave := coalesce(live_num(a.prenda), '#' || (select num from prime_prendas where id = a.prime_prenda));

  perform live_liberar_apartado(a.id);
  update live_apartados set liberada_por = v_por, liberada_motivo = 'se arrepintió' where id = a.id;

  -- ¿A quién le tocó?
  if a.prenda is not null then
    select trim(cl.nombre || coalesce(' ' || cl.apellidos, '')), coalesce(x.casillero, k.casillero) into v_nueva, v_cas
      from live_apartados x join clientas cl on cl.id = x.clienta_id left join live_cuentas k on k.id = x.cuenta_id
     where x.prenda = a.prenda and x.estado = 'apartada' and x.id <> a.id
     order by x.actualizado_en desc limit 1;
  end if;

  perform avisos_encolar('acomodo', 'arrepintio:' || a.id,
    format('↩️ %s: %s se arrepintió', v_clave, v_cl),
    case when v_nueva is not null then format('Pasó a %s (casillero %s). Lo marcó %s.', v_nueva, coalesce(v_cas, '—'), split_part(coalesce(v_por, 'acomodo'), '@', 1))
         else format('Nadie la esperaba: regresa al rack. Lo marcó %s.', split_part(coalesce(v_por, 'acomodo'), '@', 1)) end,
    'live.html#acomodo');
  return jsonb_build_object('clave', v_clave, 'clienta', v_cl, 'nueva', v_nueva, 'casillero', v_cas);
end $$;

revoke all on function public.live_arrepentimiento_info(uuid) from public, anon;
revoke all on function public.live_se_arrepintio(uuid, text) from public, anon;
grant execute on function public.live_arrepentimiento_info(uuid) to authenticated, service_role;
grant execute on function public.live_se_arrepintio(uuid, text) to authenticated, service_role;
