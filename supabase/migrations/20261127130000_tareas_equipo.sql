-- Franja "Tareas por hacer" del panel (pedido de la dueña, 27 nov 2026):
-- cuenta lo que falta por hacer en casilleros, acomodo, cajas, guías y cobros.
-- El panel decide qué tareas ve cada nivel (Dueñas ven todas).
create or replace function public.tareas_equipo() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_rol text := (select rol from equipo where usuario_id = auth.uid());
  g jsonb;
begin
  if v_rol is null then raise exception 'Tu cuenta todavía no tiene acceso.'; end if;

  -- Pedidos que ya salieron de su caja para enviarse: en qué paso va su guía
  select jsonb_build_object(
    'enviar',    count(*) filter (where paso = 'pegada'),
    'pegar',     count(*) filter (where paso = 'impresa'),
    'imprimir',  count(*) filter (where paso = 'comprada'),
    'autorizar', count(*) filter (where paso = 'cotizada'),
    'cotizar',   count(*) filter (where paso = 'sin'))
    into g
    from (select case
             when a.guia_pegada_en is not null then 'pegada'
             when a.guia_impresa_en is not null then 'impresa'
             when exists (select 1 from envios_skydrop e where e.asignacion_id = a.id and e.estado = 'comprada') then 'comprada'
             when exists (select 1 from envios_skydrop e where e.asignacion_id = a.id and e.estado = 'comprando') then 'comprando'
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
revoke all on function public.tareas_equipo() from public, anon;
grant execute on function public.tareas_equipo() to authenticated;
