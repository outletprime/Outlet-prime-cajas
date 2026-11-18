-- Cajas de resguardo: cuántas prendas caben en cada una (para sus etiquetas y el mapa).
-- A a H: 30 prendas (las 40 que ya existían). I y J: cajas grandes de 40 prendas (I1 a J5, nuevas).
alter table public.cajas add column if not exists capacidad integer not null default 30
  check (capacidad between 1 and 500);
update public.cajas set capacidad = 40 where id ~ '^[IJ][0-9]+$';
insert into public.cajas (id, capacidad)
select l || n, 40 from unnest(array['I', 'J']) l, generate_series(1, 5) n
on conflict (id) do update set capacidad = excluded.capacidad;
