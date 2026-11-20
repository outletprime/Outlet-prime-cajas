-- Reporte por live (Cajas → Reportes → "Ventas por live"). Solo Dueña y Supervisor.
-- Por cada live que empezó entre las dos fechas:
--   prendas pedidas   = las que se le apartaron a una clienta (no cuenta la lista de espera)
--   prendas pagadas   = las que sí se pagaron
--   por cobrar        = las que siguen apartadas esperando pago
--   clientas          = cuántas pidieron y cuántas pagaron
--   venta             = importe de las prendas pagadas
-- El cheque promedio (venta ÷ clientas que pagaron) lo calcula la app.
-- Solo CONSULTA: no cambia ningún dato.
create or replace function public.reporte_lives(p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text := coalesce((select zona_horaria from live_config limit 1), 'America/Mexico_City');
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'supervisor')) then
    raise exception 'Solo Dueña y Supervisor pueden ver los reportes.';
  end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(s) order by s.iniciado_en desc), '[]'::jsonb)
      from (
        select l.id, l.tipo, l.estado, nullif(trim(l.titulo), '') as titulo, nullif(trim(l.host), '') as host,
               l.iniciado_en, l.cerrado_en,
               count(a.id)::integer as prendas_pedidas,
               (count(a.id) filter (where a.estado = 'pagada'))::integer as prendas_pagadas,
               (count(a.id) filter (where a.estado = 'apartada'))::integer as prendas_por_cobrar,
               (count(distinct a.clienta_id))::integer as clientas_pidieron,
               (count(distinct a.clienta_id) filter (where a.estado = 'pagada'))::integer as clientas_pagaron,
               coalesce(sum(a.precio), 0) as pedido,
               coalesce(sum(a.precio) filter (where a.estado = 'pagada'), 0) as venta,
               coalesce(sum(a.precio) filter (where a.estado = 'apartada'), 0) as por_cobrar
          from lives l
          left join live_apartados a on a.live_id = l.id and a.cuenta_id is not null
         where l.estado in ('activo', 'cerrado')
           and (p_desde is null or (l.iniciado_en at time zone v_tz)::date >= p_desde)
           and (p_hasta is null or (l.iniciado_en at time zone v_tz)::date <= p_hasta)
         group by l.id
      ) s
  );
end $$;

revoke all on function public.reporte_lives(date, date) from public, anon;
grant execute on function public.reporte_lives(date, date) to authenticated, service_role;
