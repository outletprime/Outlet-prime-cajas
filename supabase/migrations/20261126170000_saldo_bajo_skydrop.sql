-- Aviso a las Dueñas cuando el saldo de Skydrop baja de cierto monto, con sugerencia de recarga
-- según los pedidos que están esperando guía. Lo llama la función "skydrop" cada vez que consulta el saldo.

alter table public.envios_config
  add column if not exists saldo_minimo numeric not null default 450,
  add column if not exists costo_guia_estimado numeric not null default 320;   -- se usa mientras no haya guías compradas aquí

create or replace function public.envios_saldo_aviso(p_saldo numeric)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_min numeric; v_prom numeric; v_esperan integer; v_abiertas integer; v_alcanza integer; v_guias integer; v_recarga numeric;
  v_hoy text := to_char(now() at time zone 'America/Mexico_City', 'YYYY-MM-DD');
begin
  if p_saldo is null then return false; end if;
  select saldo_minimo, costo_guia_estimado into v_min, v_prom from envios_config where id = true;
  if p_saldo > v_min then return false; end if;

  -- costo promedio: las últimas 30 guías compradas aquí; si aún no hay, el estimado
  select coalesce(avg(costo), v_prom) into v_prom
    from (select costo from envios_skydrop where estado = 'comprada' and costo > 0 order by comprada_en desc limit 30) x;
  select count(*) into v_esperan from asignaciones a
   where a.estado = 'por_entregar' and a.lista_para = 'guia' and a.guia is null;
  select count(*) into v_abiertas from asignaciones where estado = 'activa';
  v_alcanza := floor(p_saldo / v_prom);
  v_guias := greatest(v_esperan, 5);                                   -- al menos para 5 guías
  v_recarga := greatest(500, ceil((v_guias * v_prom - p_saldo) / 500) * 500);

  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('caja', 'saldo-bajo:' || v_hoy || ':' || round(p_saldo),
          format('💳 Recarga Skydrop · quedan $%s', to_char(p_saldo, 'FM999,990.00')),
          format('%s Hay %s %s esperando guía (cada una ronda $%s). Sugerencia: recargar $%s para cubrir %s guías.%s',
                 case v_alcanza when 0 then 'Ya no alcanza ni para una guía.' when 1 then 'Solo alcanza para una guía.' else format('Alcanza para %s guías.', v_alcanza) end,
                 v_esperan, case when v_esperan = 1 then 'pedido' else 'pedidos' end, round(v_prom),
                 to_char(v_recarga, 'FM999,990'), v_guias,
                 case when v_abiertas > 0 then format(' Además hay %s cajas abiertas que después pedirán guía.', v_abiertas) else '' end),
          'index.html', 'duena')
  on conflict (clave) do nothing;
  return true;
end $$;
revoke all on function public.envios_saldo_aviso(numeric) from public, anon, authenticated;
