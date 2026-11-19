-- Datos de un pedido ya pagado, para verlo e imprimir su PDF (Dueña y Supervisor). Solo lee.
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
    'total', c.total,
    'pagado', c.monto_pagado,
    'pagada_en', c.pagada_en,
    'caja', c.caja,
    'piezas', (select coalesce(jsonb_agg(jsonb_build_object('clave', coalesce(live_num(a.prenda), '#' || pp.num), 'precio', a.precio)
                 order by a.prenda nulls last, pp.num), '[]'::jsonb)
                 from live_apartados a left join prime_prendas pp on pp.id = a.prime_prenda
                where a.cuenta_id = c.id and a.estado = 'pagada'));
end $$;
revoke all on function public.live_pedido_pagado_datos(uuid) from public, anon;
grant execute on function public.live_pedido_pagado_datos(uuid) to authenticated, service_role;
