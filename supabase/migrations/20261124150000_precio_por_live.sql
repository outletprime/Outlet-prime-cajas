-- Precio por live: antes de empezar se confirma a cuánto va cada prenda en ese live ($89 o $129).
-- Si nadie elige, el live arranca en $89. Lo elegido vale solo para el siguiente live: al iniciar
-- (lo inicie el agente o una persona) el live se queda con ese precio y la elección regresa a $89.
-- Las prendas con precio especial (Prendas → Precios especiales) conservan el suyo.

alter table public.live_config add column if not exists precio_proximo numeric;
comment on column public.live_config.precio_proximo is 'Precio elegido para el siguiente live de redes; vacío = el normal ($89). Se vacía al iniciar el live.';

-- Precios que se pueden elegir para un live
create or replace function public.live_precios_validos() returns numeric[]
language sql immutable as $$ select array[89, 129]::numeric[] $$;

-- 1. Elegir el precio del siguiente live (Dueña u Operación)
create or replace function public.live_precio_proximo(p_precio numeric) returns numeric
language plpgsql security definer set search_path = public as $$
begin
  if not puede_operar() then raise exception 'Tu nivel de acceso no permite hacer esto.'; end if;
  if p_precio is null or not (p_precio = any (live_precios_validos())) then
    raise exception 'El precio del live solo puede ser $89 o $129.';
  end if;
  update live_config set precio_proximo = p_precio;
  return p_precio;
end $$;

-- 2. Cambiar el precio del live que ya está en curso: vale para lo que se aparte desde ese momento
create or replace function public.live_precio(p_live uuid, p_precio numeric) returns numeric
language plpgsql security definer set search_path = public as $$
begin
  if not puede_operar() then raise exception 'Tu nivel de acceso no permite hacer esto.'; end if;
  if p_precio is null or not (p_precio = any (live_precios_validos())) then
    raise exception 'El precio del live solo puede ser $89 o $129.';
  end if;
  update lives set precio = p_precio where id = p_live and tipo = 'redes' and estado = 'activo';
  if not found then raise exception 'Ese live ya no está en curso.'; end if;
  return p_precio;
end $$;

-- 3. Al iniciar un live de redes toma el precio elegido (o $89) y la elección se borra
create or replace function public.lives_precio_default() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_cfg live_config;
begin
  if new.tipo is distinct from 'redes' or new.precio is not null then return new; end if;
  select * into v_cfg from live_config limit 1;
  new.precio := coalesce(v_cfg.precio_proximo, v_cfg.precio, 89);
  update live_config set precio_proximo = null where precio_proximo is not null;
  return new;
end $$;

drop trigger if exists lives_precio_default on public.lives;
create trigger lives_precio_default before insert on public.lives
  for each row execute function public.lives_precio_default();

-- 4. Cada prenda que se aparta (o entra a la espera) en un live de redes va al precio de ese live,
--    salvo que la prenda tenga precio especial (distinto del precio normal)
create or replace function public.live_apartado_precio() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_live lives;
  v_normal numeric;
  v_prenda numeric;
begin
  select * into v_live from lives where id = new.live_id;
  if not found or v_live.tipo is distinct from 'redes' or v_live.precio is null then return new; end if;
  select precio into v_normal from live_config limit 1;
  select precio into v_prenda from prendas where numero = new.prenda;
  if v_prenda is null or v_prenda is not distinct from coalesce(v_normal, 89) then
    new.precio := v_live.precio;
  end if;
  return new;
end $$;

drop trigger if exists live_apartado_precio on public.live_apartados;
create trigger live_apartado_precio before insert on public.live_apartados
  for each row execute function public.live_apartado_precio();

revoke all on function public.live_precio_proximo(numeric) from public, anon;
revoke all on function public.live_precio(uuid, numeric) from public, anon;
grant execute on function public.live_precio_proximo(numeric) to authenticated;
grant execute on function public.live_precio(uuid, numeric) to authenticated;
