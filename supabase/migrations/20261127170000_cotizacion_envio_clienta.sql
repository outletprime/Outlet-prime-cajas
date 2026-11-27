-- Cotización de envío para la clienta (pedido de la dueña, 27 nov 2026):
-- la Dueña elige la paquetería, se arma la hoja de cotización (precio de la guía + cargo fijo, en un solo monto),
-- la comparte con la clienta y queda pendiente de pago. La guía se compra hasta que la clienta paga.
alter table public.envios_config add column if not exists cargo_cliente numeric not null default 60;
alter table public.envios_skydrop
  add column if not exists cobro_cliente numeric,
  add column if not exists elegida_en timestamptz,
  add column if not exists elegida_por text,
  add column if not exists compartida_en timestamptz,
  add column if not exists compartida_por text;

-- La Dueña elige (o quita, con p_tarifa nulo) la paquetería de una cotización
create or replace function public.envio_elegir(p_envio uuid, p_tarifa text, p_usuario text default null)
returns envios_skydrop
language plpgsql security definer set search_path = public as $$
declare
  e envios_skydrop;
  t jsonb;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
begin
  if not es_duena() then raise exception 'Solo una Dueña elige la paquetería.'; end if;
  select * into e from envios_skydrop where id = p_envio for update;
  if not found or e.estado <> 'cotizada' then raise exception 'Esa cotización ya no existe. Actualiza la pantalla.'; end if;
  if p_tarifa is null then
    update envios_skydrop set tarifa_id = null, paqueteria = null, servicio = null, dias = null, costo = null,
           cobro_cliente = null, elegida_en = null, elegida_por = null, compartida_en = null, compartida_por = null
     where id = p_envio returning * into e;
    return e;
  end if;
  select x into t from jsonb_array_elements(coalesce(e.tarifas, '[]'::jsonb)) x where x->>'id' = p_tarifa limit 1;
  if t is null then raise exception 'Elige una de las opciones de la cotización.'; end if;
  update envios_skydrop set tarifa_id = p_tarifa, paqueteria = t->>'paqueteria', servicio = t->>'servicio',
         dias = nullif(t->>'dias', '')::integer, costo = (t->>'total')::numeric,
         cobro_cliente = (t->>'total')::numeric + coalesce((select cargo_cliente from envios_config limit 1), 60),
         elegida_en = now(), elegida_por = v_por, compartida_en = null, compartida_por = null
   where id = p_envio returning * into e;
  return e;
end $$;

-- La cotización ya se le mandó a la clienta: queda pendiente de pago
create or replace function public.envio_compartida(p_envio uuid, p_usuario text default null)
returns envios_skydrop
language plpgsql security definer set search_path = public as $$
declare
  e envios_skydrop;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
begin
  if not es_duena() then raise exception 'Solo una Dueña comparte la cotización.'; end if;
  update envios_skydrop set compartida_en = coalesce(compartida_en, now()), compartida_por = coalesce(compartida_por, v_por)
   where id = p_envio and estado = 'cotizada' and tarifa_id is not null returning * into e;
  if not found then raise exception 'Primero elige la paquetería.'; end if;
  return e;
end $$;

revoke all on function public.envio_elegir(uuid, text, text) from public, anon;
grant execute on function public.envio_elegir(uuid, text, text) to authenticated;
revoke all on function public.envio_compartida(uuid, text) from public, anon;
grant execute on function public.envio_compartida(uuid, text) to authenticated;

-- Tareas: la guía cotizada se separa en "por elegir paquetería" y "esperando el pago de la clienta"
create or replace function public.tareas_equipo() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_rol text := (select rol from equipo where usuario_id = auth.uid());
  g jsonb;
begin
  if v_rol is null then raise exception 'Tu cuenta todavía no tiene acceso.'; end if;

  select jsonb_build_object(
    'enviar',     count(*) filter (where paso = 'pegada'),
    'pegar',      count(*) filter (where paso = 'impresa'),
    'imprimir',   count(*) filter (where paso = 'comprada'),
    'pago_envio', count(*) filter (where paso = 'esperando'),
    'autorizar',  count(*) filter (where paso = 'cotizada'),
    'cotizar',    count(*) filter (where paso = 'sin'))
    into g
    from (select case
             when a.guia_pegada_en is not null then 'pegada'
             when a.guia_impresa_en is not null then 'impresa'
             when exists (select 1 from envios_skydrop e where e.asignacion_id = a.id and e.estado = 'comprada') then 'comprada'
             when exists (select 1 from envios_skydrop e where e.asignacion_id = a.id and e.estado = 'comprando') then 'comprando'
             when exists (select 1 from envios_skydrop e where e.asignacion_id = a.id and e.estado = 'cotizada'
                           and e.cotizada_en > now() - interval '23 hours' and e.compartida_en is not null) then 'esperando'
             when exists (select 1 from envios_skydrop e where e.asignacion_id = a.id and e.estado = 'cotizada'
                           and e.cotizada_en > now() - interval '23 hours') then 'cotizada'
             else 'sin' end as paso
            from asignaciones a
           where a.estado = 'por_entregar' and a.lista_para is distinct from 'tienda') x;

  return g || jsonb_build_object(
    'rol', v_rol,
    'revisar',  (select count(*) from live_tablero where estado = 'abierta' and live_estado = 'cerrado'),
    'cobrar',   (select count(*) from live_tablero where estado = 'por_pagar' and cobro_enviado_en is null),
    'pagos',    (select count(*) from live_tablero where (estado = 'por_pagar' and cobro_enviado_en is not null) or estado = 'pago_incompleto'),
    'mover',    (select count(*) from live_tablero where estado = 'pagada' and caja is not null and casillero_liberado_en is null),
    'sin_caja', (select count(*) from live_tablero where estado = 'pagada' and caja is null and casillero_liberado_en is null),
    'vaciar',   (select count(*) from live_tablero where estado in ('vencida', 'cancelada') and casillero is not null and casillero_liberado_en is null),
    'acomodo',  (select count(*) from live_acomodo where tarea <> 'hecho'),
    'dms',      (select count(*) from live_dm_tablero where estado = 'esperando'),
    'video',    (select count(*) from pedidos p join asignaciones a on a.id = p.asignacion_id
                  where a.estado in ('activa', 'por_entregar') and coalesce(p.video, '') = ''),
    'tienda',   (select count(*) from asignaciones where estado = 'por_entregar' and lista_para = 'tienda'),
    'ventas_privadas', (select count(*) from ventas_privadas where estado = 'por_cobrar' and cancelada_en is null),
    'resurtir', coalesce(resurtido_pendientes(), 0));
end $$;
