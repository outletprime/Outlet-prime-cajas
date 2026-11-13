-- Estructura de la base de datos de Outlet Prime Cajas (proyecto Supabase "outlet-prime").
-- Copia de referencia tomada el 13 nov 2026. Solo tiene la ESTRUCTURA, no los datos de clientas.
-- Sirve para reconstruir la base en un proyecto nuevo si algún día hiciera falta.
-- No hace falta ejecutarlo en el proyecto actual: ahí ya existe todo.

-- ---------- Tablas ----------
create table if not exists public.cajas (
  id text primary key,
  creada_en timestamptz not null default now()
);

create table if not exists public.categorias (
  id text primary key,
  nombre text not null,
  precio numeric not null default 0,
  editable boolean not null default false,
  activa boolean not null default true,
  orden integer not null default 0
);

create table if not exists public.clientas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  apellidos text,
  fecha_registro date,
  telefono text,
  correo text,
  calle text,
  numero text,
  interior text,
  colonia text,
  cp text,
  ciudad text,
  estado text,
  referencia text,
  creado_por text,
  creada_en timestamptz not null default now()
);

create table if not exists public.asignaciones (
  id uuid primary key default gen_random_uuid(),
  caja text not null references public.cajas(id) on update cascade,
  clienta_id uuid not null references public.clientas(id),
  estado text not null default 'activa' check (estado in ('activa', 'enviada')),
  asignada_en timestamptz not null default now(),
  asignada_por text,
  movimientos jsonb not null default '[]'::jsonb,
  enviada_en timestamptz,
  enviada_por text,
  paqueteria text,
  guia text,
  peso_kg numeric,
  medidas text,
  costo_envio numeric,
  notas_envio text,
  foto_guia text
);
create unique index if not exists una_clienta_por_caja on public.asignaciones (caja) where estado = 'activa';
create unique index if not exists una_caja_por_clienta on public.asignaciones (clienta_id) where estado = 'activa';
create index if not exists asignaciones_clienta on public.asignaciones (clienta_id);

create table if not exists public.pedidos (
  id uuid primary key default gen_random_uuid(),
  asignacion_id uuid not null references public.asignaciones(id) on delete cascade,
  clienta_id uuid not null references public.clientas(id),
  caja text not null,
  fecha timestamptz not null default now(),
  items jsonb not null default '[]'::jsonb,
  prendas integer not null default 0,
  total numeric not null default 0,
  notas text,
  video text,
  video_mb numeric,
  video_comprimido boolean not null default false,
  creado_por text
);
create index if not exists pedidos_fecha on public.pedidos (fecha);
create index if not exists pedidos_asignacion on public.pedidos (asignacion_id);
create index if not exists pedidos_clienta on public.pedidos (clienta_id);

-- ---------- Categorías iniciales ----------
insert into public.categorias (id, nombre, precio, editable, activa, orden) values
  ('target', 'Target', 89, false, true, 1),
  ('costco', 'Costco', 289, false, true, 2),
  ('cremas', 'Cremas', 189, false, true, 3),
  ('perfumes', 'Perfumes', 589, false, true, 4),
  ('calzado', 'Calzado', 0, true, true, 5)
on conflict (id) do nothing;

-- ---------- Seguridad: solo usuarios con sesión iniciada ----------
alter table public.cajas enable row level security;
alter table public.categorias enable row level security;
alter table public.clientas enable row level security;
alter table public.asignaciones enable row level security;
alter table public.pedidos enable row level security;

create policy equipo on public.cajas for all to authenticated using (true) with check (true);
create policy equipo on public.categorias for all to authenticated using (true) with check (true);
create policy equipo on public.clientas for all to authenticated using (true) with check (true);
create policy equipo on public.asignaciones for all to authenticated using (true) with check (true);
create policy equipo on public.pedidos for all to authenticated using (true) with check (true);

-- ---------- Archivos (fotos de guías y videos de pedidos) ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('archivos', 'archivos', false, 52428800)
on conflict (id) do nothing;

create policy "equipo lee archivos" on storage.objects for select to authenticated using (bucket_id = 'archivos');
create policy "equipo sube archivos" on storage.objects for insert to authenticated with check (bucket_id = 'archivos');
create policy "equipo cambia archivos" on storage.objects for update to authenticated using (bucket_id = 'archivos');
create policy "equipo borra archivos" on storage.objects for delete to authenticated using (bucket_id = 'archivos');

-- ---------- Conexión con Outlet Prime Live ----------
-- Devuelve la caja activa de una clienta a partir de su correo.
-- Necesita la tabla privado.llaves con una fila nombre = 'outlet_live' (la llave NO se guarda aquí).
create or replace function public.caja_activa_por_correo(p_correo text, p_llave text)
returns text
language plpgsql
security definer
set search_path to 'public', 'privado'
as $function$
declare
  v_caja text;
begin
  if p_llave is null or not exists (
    select 1 from privado.llaves where nombre = 'outlet_live' and valor = p_llave
  ) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;

  select a.caja into v_caja
    from public.asignaciones a
    join public.clientas c on c.id = a.clienta_id
   where lower(trim(c.correo)) = lower(trim(p_correo))
     and a.estado = 'activa'
   order by a.asignada_en desc
   limit 1;

  return v_caja;
end;
$function$;
