-- El Supervisor puede editar los datos de las clientas (nombre, teléfono, domicilio…).
-- Solo cambiar: no puede borrarlas. Crear clientas lo sigue haciendo desde Ajustes → Agregar clienta.
create or replace function public.es_supervisor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from equipo where usuario_id = auth.uid() and rol = 'supervisor')
$$;
revoke all on function public.es_supervisor() from public, anon;
grant execute on function public.es_supervisor() to authenticated, service_role;

drop policy if exists cambiar_supervisor on public.clientas;
create policy cambiar_supervisor on public.clientas for update to authenticated
  using ((select es_supervisor())) with check ((select es_supervisor()));
