-- Una caja no se puede marcar como enviada si alguno de sus pedidos no tiene video.
-- El video se graba o se carga desde la app de Cajas (botón "Sin video · Agregar" en cada pedido).

create or replace function public.asignaciones_envio_con_video() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_faltan int;
begin
  if new.estado = 'enviada' and old.estado is distinct from 'enviada' then
    select count(*) into v_faltan from pedidos where asignacion_id = new.id and coalesce(trim(video), '') = '';
    if v_faltan > 0 then
      raise exception 'FALTA_VIDEO: % sin video', v_faltan using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists envio_con_video on public.asignaciones;
create trigger envio_con_video before update of estado on public.asignaciones
  for each row execute function public.asignaciones_envio_con_video();
