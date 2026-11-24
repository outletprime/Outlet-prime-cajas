-- Todo el live va a un solo precio. Si el live arrancó con el precio equivocado, corregirlo cambia
-- TODO el live: lo ya apartado, lo que está en espera y lo que se aparte después.
-- (Las prendas con precio especial conservan el suyo.)

create or replace function public.live_precio(p_live uuid, p_precio numeric) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_normal numeric;
  v_cuenta uuid;
begin
  if not puede_operar() then raise exception 'Tu nivel de acceso no permite hacer esto.'; end if;
  if p_precio is null or not (p_precio = any (live_precios_validos())) then
    raise exception 'El precio del live solo puede ser $89 o $129.';
  end if;
  update lives set precio = p_precio where id = p_live and tipo = 'redes' and estado = 'activo';
  if not found then raise exception 'Ese live ya no está en curso.'; end if;

  select coalesce(precio, 89) into v_normal from live_config limit 1;
  update live_apartados a set precio = p_precio, actualizado_en = now()
   where a.live_id = p_live and a.estado in ('apartada', 'espera') and a.precio is distinct from p_precio
     and exists (select 1 from prendas p where p.numero = a.prenda and p.precio is not distinct from v_normal);

  for v_cuenta in select id from live_cuentas where live_id = p_live and estado = 'abierta' loop
    perform live_recalcular(v_cuenta);
  end loop;
  return p_precio;
end $$;

revoke all on function public.live_precio(uuid, numeric) from public, anon;
grant execute on function public.live_precio(uuid, numeric) to authenticated;
