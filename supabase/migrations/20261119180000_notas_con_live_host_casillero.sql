-- Las notas (de cobro y de pedido pagado) llevan: el live al que corresponden, su fecha, la host y el casillero.
-- La caja de resguardo solo sale cuando el pedido ya está pagado.

-- 1. Host de cada live. Se toma de Ajustes al iniciar el live y se puede cambiar en ese live.
alter table public.live_config add column if not exists host text;
update public.live_config set host = 'Heidy' where host is null;
alter table public.lives add column if not exists host text;
update public.lives set host = 'Heidy' where host is null;

create or replace function public.lives_host_default() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.host := coalesce(nullif(trim(new.host), ''), (select nullif(trim(host), '') from live_config limit 1));
  return new;
end $$;
drop trigger if exists lives_host_default on public.lives;
create trigger lives_host_default before insert on public.lives
  for each row execute function public.lives_host_default();

-- Cambiar la host de un live (Dueña y Operación)
create or replace function public.live_host(p_live uuid, p_host text) returns text
language plpgsql security definer set search_path = public as $$
declare v text := nullif(trim(regexp_replace(coalesce(p_host, ''), '\s+', ' ', 'g')), '');
begin
  if not puede_operar() then raise exception 'Tu nivel de acceso no permite hacer esto.'; end if;
  if v is null or length(v) > 40 then raise exception 'Escribe el nombre de la host (máximo 40 letras).'; end if;
  update lives set host = v where id = p_live;
  if not found then raise exception 'No existe ese live.'; end if;
  return v;
end $$;
revoke all on function public.live_host(uuid, text) from public, anon;
grant execute on function public.live_host(uuid, text) to authenticated, service_role;

-- "18 de noviembre, 5:07 p.m."
create or replace function public.live_fecha_larga(p timestamptz) returns text
language sql stable set search_path = public as $$
  select extract(day from t)::int || ' de ' ||
         (array['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'])[extract(month from t)::int]
         || ', ' || ltrim(to_char(t, 'HH12:MI'), '0') || case when extract(hour from t) < 12 then ' a.m.' else ' p.m.' end
    from (select p at time zone coalesce((select zona_horaria from live_config limit 1), 'America/Mexico_City') as t) s
$$;

-- 2. Datos para la nota de cobro en PDF (Dueña): ahora con live, host y casillero
create or replace function public.live_nota_datos(p_cuenta uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c live_cuentas;
  v_cfg live_config;
  v_live lives;
begin
  if not es_duena() then raise exception 'Solo una Dueña puede descargar la nota de cobro.'; end if;
  select * into c from live_cuentas where id = p_cuenta;
  if not found then raise exception 'No existe esa cuenta.'; end if;
  if c.estado not in ('por_pagar', 'pago_incompleto') then
    raise exception 'Este pedido no tiene una nota de cobro pendiente.';
  end if;
  select * into v_cfg from live_config limit 1;
  select * into v_live from lives where id = c.live_id;
  return jsonb_build_object(
    'folio', live_folio(c.folio),
    'clienta', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = c.clienta_id),
    'fecha', coalesce(v_live.iniciado_en, c.creada_en),
    'tipo', v_live.tipo,
    'live_titulo', nullif(trim(v_live.titulo), ''),
    'host', nullif(trim(v_live.host), ''),
    'casilleros', coalesce(nullif(live_unir(live_casilleros_de(c.id)), ''), c.casillero),
    'total', c.total,
    'pagado', coalesce(c.monto_pagado, 0),
    'clabe', coalesce(nullif(trim(c.clabe), ''), nullif(trim(v_cfg.clabe), '')),
    'banco', nullif(trim(v_cfg.banco), ''),
    'titular', nullif(trim(v_cfg.titular), ''),
    'limite_pago', c.limite_pago,
    'liberar_en', c.liberar_en,
    'piezas', (select coalesce(jsonb_agg(jsonb_build_object('clave', coalesce(live_num(a.prenda), '#' || pp.num), 'precio', a.precio)
                 order by a.prenda nulls last, pp.num), '[]'::jsonb)
                 from live_apartados a left join prime_prendas pp on pp.id = a.prime_prenda
                where a.cuenta_id = c.id and a.estado = 'apartada'));
end $$;

-- 3. Datos del pedido ya pagado (Dueña y Supervisor): además lleva su caja de resguardo
create or replace function public.live_pedido_pagado_datos(p_cuenta uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c live_cuentas;
  v_live lives;
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'supervisor')) then
    raise exception 'Solo Dueña y Supervisor pueden sacar el PDF de un pedido pagado.';
  end if;
  select * into c from live_cuentas where id = p_cuenta;
  if not found then raise exception 'No existe ese pedido.'; end if;
  if c.estado <> 'pagada' then raise exception 'Ese pedido no está pagado.'; end if;
  select * into v_live from lives where id = c.live_id;
  return jsonb_build_object(
    'pagada', true,
    'folio', live_folio(c.folio),
    'clienta', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = c.clienta_id),
    'fecha', coalesce(v_live.iniciado_en, c.creada_en),
    'tipo', v_live.tipo,
    'live_titulo', nullif(trim(v_live.titulo), ''),
    'host', nullif(trim(v_live.host), ''),
    'casilleros', coalesce(nullif(live_unir(live_casilleros_de(c.id)), ''), c.casillero),
    'total', c.total,
    'pagado', c.monto_pagado,
    'pagada_en', c.pagada_en,
    'caja', c.caja,
    'piezas', (select coalesce(jsonb_agg(jsonb_build_object('clave', coalesce(live_num(a.prenda), '#' || pp.num), 'precio', a.precio)
                 order by a.prenda nulls last, pp.num), '[]'::jsonb)
                 from live_apartados a left join prime_prendas pp on pp.id = a.prime_prenda
                where a.cuenta_id = c.id and a.estado = 'pagada'));
end $$;

-- 4. La nota de texto (la que se manda por WhatsApp) también dice el live, la host y el casillero
create or replace function public.live_texto_cobro(p_cuenta uuid) returns text
language plpgsql stable set search_path = public as $$
declare
  c live_cuentas;
  v_cfg live_config;
  v_live lives;
  v_txt text;
  v_datos text;
  v_cas text;
begin
  select * into c from live_cuentas where id = p_cuenta;
  select * into v_cfg from live_config limit 1;
  select * into v_live from lives where id = c.live_id;

  v_txt := format('🧾 Tu total del %s: *%s* (%s %s: %s).',
    case when v_live.tipo = 'prime' then 'Prime Live' else 'live' end,
    live_dinero(c.total), c.piezas, case when c.piezas = 1 then 'prenda' else 'prendas' end,
    live_unir(live_etiquetas(c.id, array['apartada'])));

  v_cas := coalesce(nullif(live_unir(live_casilleros_de(c.id)), ''), c.casillero);
  v_txt := v_txt || E'\n' || concat_ws(' · ',
    format('📅 %s del %s', case when v_live.tipo = 'prime' then 'Prime Live' else 'Live' end, live_fecha_larga(coalesce(v_live.iniciado_en, c.creada_en))),
    case when nullif(trim(v_live.host), '') is not null then 'Host: ' || trim(v_live.host) end,
    case when v_cas is not null then 'Casillero ' || v_cas end);

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
