-- Nota de cobro en PDF: datos que necesita el panel para armarla (solo Dueña).
-- No cambia nada: solo lee el pedido, sus prendas y los datos para transferir de Ajustes.
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

revoke all on function public.live_nota_datos(uuid) from public, anon;
grant execute on function public.live_nota_datos(uuid) to authenticated, service_role;
