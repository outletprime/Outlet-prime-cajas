-- Impresión automática de guías: un programa en la computadora de la tienda ("impresor") pregunta
-- qué guías compradas faltan por imprimir, las manda a la impresora y avisa el resultado.
-- Si el impresor está apagado, todo sigue como antes: el Supervisor recibe su aviso y la imprime a mano.

alter table public.envios_config
  add column if not exists impresion_auto boolean not null default false,
  add column if not exists impresor_visto_en timestamptz;          -- última vez que el impresor preguntó

alter table public.envios_skydrop
  add column if not exists impresion_intentos integer not null default 0,
  add column if not exists impresion_error text,
  add column if not exists impresa_auto_en timestamptz;

-- ¿El impresor está prendido? (preguntó hace menos de 2 minutos)
create or replace function public.impresor_activo() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select impresion_auto and impresor_visto_en > now() - interval '2 minutes' from envios_config where id = true), false);
$$;
revoke all on function public.impresor_activo() from public, anon;
grant execute on function public.impresor_activo() to authenticated;

-- Guías por imprimir (solo el agente de la tienda o una Dueña)
create or replace function public.impresion_pendientes()
returns table (envio uuid, asignacion uuid, etiqueta_url text, clienta text, paqueteria text, guia text)
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion')) then
    raise exception 'SIN_PERMISO';
  end if;
  update envios_config set impresor_visto_en = now() where id = true;
  if not (select impresion_auto from envios_config where id = true) then return; end if;
  return query
    select e.id, a.id, e.etiqueta_url, trim(c.nombre || coalesce(' ' || c.apellidos, '')), e.paqueteria, e.guia
      from envios_skydrop e
      join asignaciones a on a.id = e.asignacion_id
      join clientas c on c.id = a.clienta_id
     where e.estado = 'comprada' and e.etiqueta_url is not null
       and a.guia_impresa_en is null and a.guia_pegada_en is null and a.estado <> 'enviada'
       and e.impresion_intentos < 3
     order by e.comprada_en;
end $$;
revoke all on function public.impresion_pendientes() from public, anon;
grant execute on function public.impresion_pendientes() to authenticated;

-- Resultado de la impresión
create or replace function public.impresion_resultado(p_envio uuid, p_ok boolean, p_error text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  e envios_skydrop;
  a asignaciones;
  v_cl text;
  v_pren integer;
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion')) then
    raise exception 'SIN_PERMISO';
  end if;
  select * into e from envios_skydrop where id = p_envio for update;
  if not found or e.estado <> 'comprada' then return; end if;
  select * into a from asignaciones where id = e.asignacion_id for update;
  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;

  if coalesce(p_ok, false) then
    update envios_skydrop set impresa_auto_en = now(), impresion_error = null where id = e.id;
    if a.guia_impresa_en is not null or a.estado = 'enviada' then return; end if;
    update asignaciones set guia_impresa_en = now(), guia_impresa_por = 'impresora' where id = a.id;
    select coalesce(sum(prendas), 0) into v_pren from pedidos where asignacion_id = a.id;
    insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
    values ('caja', 'guia-impresa:' || a.id || ':' || extract(epoch from now())::bigint,
            format('🖨️ Guía de %s lista para pegar', v_cl),
            concat_ws(' · ', format('%s %s', v_pren, case when v_pren = 1 then 'prenda' else 'prendas' end),
                      nullif(concat_ws(' ', a.paqueteria, a.guia), ''),
                      'Ya salió de la impresora. Pégala en su paquete y márcala en Cajas → Falta guía.'),
            'index.html#/salida/' || a.id, 'operacion')
    on conflict (clave) do nothing;
    return;
  end if;

  update envios_skydrop set impresion_intentos = impresion_intentos + 1, impresion_error = left(coalesce(p_error, 'sin detalle'), 300)
   where id = e.id returning * into e;
  if e.impresion_intentos = 3 then
    insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
    select 'caja', 'guia-no-imprimio:' || e.id || case when r = 'duena' then '' else ':' || r end,
           format('⚠️ La guía de %s no se pudo imprimir sola', v_cl),
           'Revisa que la impresora esté prendida y con papel. Mientras, imprímela a mano desde Cajas → Falta guía.',
           'index.html#/salida/' || a.id, r
      from unnest(array['supervisor', 'duena']) r
    on conflict (clave) do nothing;
  end if;
end $$;
revoke all on function public.impresion_resultado(uuid, boolean, text) from public, anon;
grant execute on function public.impresion_resultado(uuid, boolean, text) to authenticated;

-- Con el impresor prendido, el Supervisor ya no recibe "Guía lista para imprimir" (sale sola)
create or replace function public.avisos_sin_imprimir_a_mano() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.clave like 'guia-comprada:%' and new.para_rol = 'supervisor' and public.impresor_activo() then return null; end if;
  return new;
end $$;
drop trigger if exists avisos_sin_imprimir_a_mano on public.avisos;
create trigger avisos_sin_imprimir_a_mano before insert on public.avisos
  for each row execute function public.avisos_sin_imprimir_a_mano();
