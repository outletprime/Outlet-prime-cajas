-- Corrección: la base rechaza un "update" sin condición cuando lo hace una persona del equipo.
create or replace function public.live_precio_proximo(p_precio numeric) returns numeric
language plpgsql security definer set search_path = public as $$
begin
  if not puede_operar() then raise exception 'Tu nivel de acceso no permite hacer esto.'; end if;
  if p_precio is null or not (p_precio = any (live_precios_validos())) then
    raise exception 'El precio del live solo puede ser $89 o $129.';
  end if;
  update live_config set precio_proximo = p_precio where id = true;
  if not found then raise exception 'No se encontró la configuración del live.'; end if;
  return p_precio;
end $$;

revoke all on function public.live_precio_proximo(numeric) from public, anon;
grant execute on function public.live_precio_proximo(numeric) to authenticated;
