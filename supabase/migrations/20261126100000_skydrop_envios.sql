-- Guías con Skydrop desde Cajas: cotizar el envío de una caja y comprar la guía.
-- Solo la función "skydrop" (con la llave de servicio) escribe aquí; Dueña y Supervisor solo leen.

create table if not exists public.envios_config (
  id boolean primary key default true check (id),
  peso_prenda_kg numeric not null default 0.2,          -- peso estimado por prenda
  peso_empaque_kg numeric not null default 0.5,         -- caja o bolsa vacía
  medidas jsonb not null default '{"30":[40,30,30],"40":[50,40,30]}'::jsonb,   -- largo, ancho, alto (cm) según la capacidad de la caja
  origen jsonb,                                         -- domicilio de la tienda (se toma de Skydrop la primera vez)
  carta_porte text,                                     -- código SAT del contenido (ropa)
  tipo_empaque text not null default '4G',              -- 4G = caja de cartón
  formato text not null default 'standard' check (formato in ('standard', 'thermal')),   -- hoja carta o etiqueta térmica
  correo_destino text,                                  -- correo que se usa cuando la clienta no tiene
  llave_prueba text,                                    -- solo para diagnóstico al instalar; vacío = apagado
  actualizado_en timestamptz not null default now()
);
insert into public.envios_config (id) values (true) on conflict do nothing;
alter table public.envios_config enable row level security;

create table if not exists public.envios_skydrop (
  id uuid primary key default gen_random_uuid(),
  asignacion_id uuid not null references public.asignaciones(id) on delete cascade,
  estado text not null default 'cotizada' check (estado in ('cotizada', 'comprando', 'comprada', 'fallida', 'cancelada')),
  cotizacion_id text,
  tarifas jsonb not null default '[]'::jsonb,           -- opciones que devolvió Skydrop
  peso_kg numeric, largo integer, ancho integer, alto integer,
  destino jsonb,                                        -- domicilio con el que se cotizó
  tarifa_id text, paqueteria text, servicio text, dias integer, costo numeric,
  envio_id text, guia text, etiqueta_url text, rastreo_url text,
  error text,
  cotizada_en timestamptz not null default now(), cotizada_por text,
  comprada_en timestamptz, comprada_por text,
  cancelada_en timestamptz, cancelada_por text
);
create index if not exists envios_skydrop_asignacion on public.envios_skydrop (asignacion_id, cotizada_en desc);
-- Candado contra la doble compra: una sola guía viva por caja
create unique index if not exists envios_skydrop_una_viva on public.envios_skydrop (asignacion_id) where estado in ('comprando', 'comprada');

alter table public.envios_skydrop enable row level security;
drop policy if exists envios_skydrop_leer on public.envios_skydrop;
create policy envios_skydrop_leer on public.envios_skydrop for select to authenticated
  using (public.es_duena() or public.es_supervisor());

revoke all on public.envios_config from anon, authenticated;
revoke all on public.envios_skydrop from anon;
revoke insert, update, delete on public.envios_skydrop from authenticated;
grant select on public.envios_skydrop to authenticated;

-- Lo que la pantalla necesita saber para proponer peso y medidas (sin exponer el resto de la configuración)
create or replace function public.envio_sugerido(p_asignacion uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_cfg public.envios_config;
  v_prendas integer;
  v_cap integer;
  v_med jsonb;
begin
  if not (public.es_duena() or public.es_supervisor()) then raise exception 'SIN_PERMISO'; end if;
  select * into v_cfg from public.envios_config where id = true;
  select coalesce(sum(prendas), 0) into v_prendas from public.pedidos where asignacion_id = p_asignacion;
  select c.capacidad into v_cap from public.asignaciones a join public.cajas c on c.id = a.caja where a.id = p_asignacion;
  v_med := coalesce(v_cfg.medidas -> coalesce(v_cap, 30)::text, v_cfg.medidas -> '30', '[40,30,30]'::jsonb);
  return jsonb_build_object(
    'prendas', v_prendas,
    'peso_kg', greatest(1, ceil(v_prendas * v_cfg.peso_prenda_kg + v_cfg.peso_empaque_kg)),
    'largo', (v_med ->> 0)::integer, 'ancho', (v_med ->> 1)::integer, 'alto', (v_med ->> 2)::integer);
end $$;
revoke all on function public.envio_sugerido(uuid) from public, anon;
grant execute on function public.envio_sugerido(uuid) to authenticated;
