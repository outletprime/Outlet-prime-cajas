-- =====================================================================
-- Niveles preasignados: se guarda el correo y el nivel ANTES de que exista la cuenta.
-- Cuando se crea el usuario en Supabase (Authentication → Users → Add user), entra
-- directo con ese nivel, sin tener que asignarlo después en Ajustes → Equipo.
-- Se puede pegar varias veces sin dañar nada.
-- =====================================================================
create table if not exists public.equipo_invitaciones (
  email text primary key check (email = lower(btrim(email))),
  rol text not null check (rol in ('supervisor', 'operacion', 'live', 'presentadora')),
  creada_en timestamptz not null default now(),
  usada_en timestamptz
);
alter table public.equipo_invitaciones enable row level security;   -- sin políticas: solo el servidor
revoke all on public.equipo_invitaciones from anon, authenticated;

create or replace function public.equipo_aplicar_invitacion() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_rol text;
begin
  select rol into v_rol from public.equipo_invitaciones
   where email = lower(btrim(new.email)) and usada_en is null;
  if v_rol is not null then
    insert into public.equipo (usuario_id, email, rol, asignado_por)
    values (new.id, lower(btrim(new.email)), v_rol, 'invitación')
    on conflict (usuario_id) do nothing;
    update public.equipo_invitaciones set usada_en = now() where email = lower(btrim(new.email));
  end if;
  return new;
end $$;
revoke all on function public.equipo_aplicar_invitacion() from public, anon, authenticated;

drop trigger if exists equipo_aplicar_invitacion on auth.users;
create trigger equipo_aplicar_invitacion after insert on auth.users
  for each row execute function public.equipo_aplicar_invitacion();
