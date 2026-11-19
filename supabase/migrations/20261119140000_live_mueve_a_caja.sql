-- Operación live (acomodo) también puede marcar "Ya está en la caja": pasó las prendas de un pedido PAGADO
-- del casillero a su caja de resguardo, y con eso el casillero queda libre.
-- Lo demás sigue igual: "Ya las regresé" (pedido sin pago) y "Ya está vacío" (cancelado) son de Dueña y Operación.
create or replace function public.live_casillero_listo(p_cuenta uuid, p_usuario text default null) returns void
language plpgsql security definer set search_path = public as $$
declare c live_cuentas;
begin
  select * into c from live_cuentas where id = p_cuenta for update;
  if not found then raise exception 'No existe esa cuenta.'; end if;
  if auth.uid() is not null and not (puede_operar() or (puede_acomodar() and c.estado = 'pagada')) then
    raise exception 'Tu nivel de acceso no permite hacer esto.';
  end if;
  if c.casillero_liberado_en is not null then return; end if;
  if c.estado = 'pagada' then
    if c.pedido_id is null then raise exception 'Primero hay que asignarle una caja.'; end if;
    update live_cuentas set en_caja_en = now(), casillero_liberado_en = now(), casillero_liberado_por = p_usuario
     where id = c.id;
  elsif c.estado in ('vencida', 'cancelada') then
    update live_cuentas set casillero_liberado_en = now(), casillero_liberado_por = p_usuario where id = c.id;
  else
    raise exception 'Este casillero todavía no se vacía: la cuenta está %.', replace(c.estado, '_', ' ');
  end if;
end $$;
revoke all on function public.live_casillero_listo(uuid, text) from public, anon;
grant execute on function public.live_casillero_listo(uuid, text) to authenticated, service_role;
