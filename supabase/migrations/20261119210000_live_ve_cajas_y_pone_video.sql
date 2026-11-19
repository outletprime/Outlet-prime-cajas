-- Operación live entra a la app de Cajas: ve las cajas (ya podía leerlas) y puede agregar
-- el video de un pedido que todavía no lo tiene. No cambia nada más: ni pedidos, ni clientas,
-- ni envíos. Dueña y Operación siguen pudiendo poner o reemplazar el video.

create or replace function public.puede_poner_video() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion', 'live'))
$$;

-- Guarda el video ya subido en su pedido. Operación live solo si el pedido no tenía video.
create or replace function public.pedido_poner_video(p_pedido uuid, p_ruta text, p_mb numeric)
returns public.pedidos
language plpgsql security definer set search_path = public as $$
declare v pedidos;
begin
  if not puede_poner_video() then
    raise exception 'SIN_PERMISO: tu nivel de acceso no permite agregar videos' using errcode = 'P0001';
  end if;
  select * into v from pedidos where id = p_pedido for update;
  if not found then
    raise exception 'PEDIDO_NO_EXISTE' using errcode = 'P0001';
  end if;
  if coalesce(p_ruta, '') not like 'videos/' || p_pedido::text || '.%' then
    raise exception 'RUTA_INVALIDA' using errcode = 'P0001';
  end if;
  if coalesce(trim(v.video), '') <> '' and not puede_operar() then
    raise exception 'YA_TIENE_VIDEO' using errcode = 'P0001';
  end if;
  update pedidos set video = p_ruta, video_mb = p_mb, video_comprimido = false
   where id = p_pedido returning * into v;
  return v;
end $$;

revoke all on function public.pedido_poner_video(uuid, text, numeric) from public, anon;
grant execute on function public.pedido_poner_video(uuid, text, numeric) to authenticated;
revoke all on function public.puede_poner_video() from public, anon;
grant execute on function public.puede_poner_video() to authenticated;

-- Subir el archivo: Operación live solo en la carpeta de videos y solo si ese archivo
-- todavía no es el video guardado de algún pedido (no puede encimar uno ya puesto).
drop policy if exists "live sube video de pedido" on storage.objects;
create policy "live sube video de pedido" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'archivos' and name like 'videos/%'
    and (select public.mi_rol()) = 'live'
    and not exists (select 1 from public.pedidos p where p.video = objects.name)
  );

drop policy if exists "live repite video de pedido" on storage.objects;
create policy "live repite video de pedido" on storage.objects for update to authenticated
  using (
    bucket_id = 'archivos' and name like 'videos/%'
    and (select public.mi_rol()) = 'live'
    and not exists (select 1 from public.pedidos p where p.video = objects.name)
  )
  with check (
    bucket_id = 'archivos' and name like 'videos/%'
    and (select public.mi_rol()) = 'live'
  );
