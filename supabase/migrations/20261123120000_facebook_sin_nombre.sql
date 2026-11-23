-- Comentarios del live que llegan SIN el nombre de quien comentó (Facebook no lo comparte mientras la app de
-- Meta no tenga "acceso avanzado"). El agente los guarda aquí si traen una clave; en el panel (En vivo →
-- "Facebook: falta el nombre") alguien del equipo escribe el nombre que ve en Facebook y toca Apartar.
-- Se aparta con la hora ORIGINAL del comentario, igual que si el agente lo hubiera leído completo.

create table if not exists public.live_sin_autor (
  id            bigserial primary key,
  live_id       uuid not null references public.lives(id) on delete cascade,
  red           text not null check (red in ('tiktok', 'facebook', 'instagram', 'youtube', 'otra')),
  comentario_id text not null,
  texto         text not null default '',
  prendas       integer[] not null default '{}',
  comentado_en  timestamptz not null default now(),
  recibido_en   timestamptz not null default now(),
  estado        text not null default 'pendiente' check (estado in ('pendiente', 'apartado', 'descartado')),
  usuario       text,
  resultado     jsonb,
  resuelto_por  text,
  resuelto_en   timestamptz,
  unique (red, comentario_id)
);
create index if not exists live_sin_autor_pendientes on public.live_sin_autor (live_id, comentado_en) where estado = 'pendiente';

alter table public.live_sin_autor enable row level security;
drop policy if exists "ver" on public.live_sin_autor;
create policy "ver" on public.live_sin_autor for select to authenticated using ((select public.puede_ver()));
-- Escribir solo por las funciones de abajo
revoke insert, update, delete on public.live_sin_autor from anon, authenticated;

-- El agente manda el comentario sin nombre (solo si trae claves y hay un live de redes activo)
create or replace function public.live_sin_autor_agregar(p_red text, p_comentario_id text, p_texto text,
                                                         p_prendas integer[], p_comentado_en timestamptz default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_live uuid;
  v_nums integer[];
begin
  if not puede_operar() then raise exception 'SIN_PERMISO: tu nivel de acceso no permite esto' using errcode = 'P0001'; end if;
  select coalesce(array_agg(distinct n), '{}') into v_nums from unnest(coalesce(p_prendas, '{}')) n where n between 1 and 99999;
  if cardinality(v_nums) = 0 or coalesce(trim(p_comentario_id), '') = '' then return false; end if;
  select id into v_live from lives where estado = 'activo' and tipo = 'redes' limit 1;
  if v_live is null then return false; end if;
  insert into live_sin_autor (live_id, red, comentario_id, texto, prendas, comentado_en)
  values (v_live, lower(trim(p_red)), p_comentario_id, left(coalesce(p_texto, ''), 500), v_nums,
          least(coalesce(p_comentado_en, now()), now()))
  on conflict (red, comentario_id) do nothing;
  return found;
end $$;

-- El equipo escribe el nombre que ve en Facebook: se aparta con la hora original del comentario
create or replace function public.live_sin_autor_apartar(p_id bigint, p_usuario text, p_por text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s live_sin_autor;
  v_res jsonb;
  v_por text := coalesce(nullif(trim(p_por), ''), (select email from equipo where usuario_id = auth.uid()));
begin
  if not puede_operar() then raise exception 'SIN_PERMISO: tu nivel de acceso no permite esto' using errcode = 'P0001'; end if;
  if live_usuario_norm(p_usuario) is null then raise exception 'Escribe el nombre de quien comentó, como aparece en Facebook.'; end if;
  select * into s from live_sin_autor where id = p_id for update;
  if not found then raise exception 'Ese comentario ya no existe.'; end if;
  if s.estado <> 'pendiente' then raise exception 'Ese comentario ya se resolvió.'; end if;
  if not exists (select 1 from lives where id = s.live_id and estado = 'activo') then
    raise exception 'El live de ese comentario ya terminó: captúralo a mano si todavía aplica.';
  end if;
  v_res := live_comentario(s.red, p_usuario, s.texto, s.prendas, s.comentado_en, s.comentario_id, trim(p_usuario), 'manual', false);
  update live_sin_autor
     set estado = 'apartado', usuario = live_usuario_norm(p_usuario), resultado = v_res, resuelto_por = v_por, resuelto_en = now()
   where id = s.id;
  return v_res;
end $$;

-- No era un pedido (o ya se capturó de otra forma)
create or replace function public.live_sin_autor_descartar(p_id bigint, p_por text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not puede_operar() then raise exception 'SIN_PERMISO: tu nivel de acceso no permite esto' using errcode = 'P0001'; end if;
  update live_sin_autor
     set estado = 'descartado', resuelto_por = coalesce(nullif(trim(p_por), ''), (select email from equipo where usuario_id = auth.uid())), resuelto_en = now()
   where id = p_id and estado = 'pendiente';
end $$;

revoke all on function public.live_sin_autor_agregar(text, text, text, integer[], timestamptz) from public, anon;
revoke all on function public.live_sin_autor_apartar(bigint, text, text) from public, anon;
revoke all on function public.live_sin_autor_descartar(bigint, text) from public, anon;
grant execute on function public.live_sin_autor_agregar(text, text, text, integer[], timestamptz) to authenticated;
grant execute on function public.live_sin_autor_apartar(bigint, text, text) to authenticated;
grant execute on function public.live_sin_autor_descartar(bigint, text) to authenticated;
