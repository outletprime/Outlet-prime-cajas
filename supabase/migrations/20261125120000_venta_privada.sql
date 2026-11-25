-- Venta privada (solo Dueñas): venta fuera de un live a una clienta ya registrada.
-- Se escriben o escanean las claves de las prendas y se elige a qué precio va cada una.
-- La venta se registra ya pagada: las prendas quedan vendidas (no se pueden apartar en un live)
-- y entran como un pedido a la caja de resguardo de la clienta. El pedido nace sin video.
-- Borrar ese pedido en Cajas deshace la venta: las prendas regresan a disponibles.

create table if not exists public.ventas_privadas (
  id uuid primary key default gen_random_uuid(),
  clienta_id uuid not null references public.clientas(id),
  precio numeric not null check (precio > 0),
  piezas integer[] not null,
  total numeric not null,
  pedido_id uuid references public.pedidos(id) on delete set null,
  caja text,
  creada_en timestamptz not null default now(),
  creada_por text,
  cancelada_en timestamptz
);
create index if not exists ventas_privadas_clienta on public.ventas_privadas (clienta_id, creada_en desc);
create index if not exists ventas_privadas_pedido on public.ventas_privadas (pedido_id);

alter table public.ventas_privadas enable row level security;
drop policy if exists ver on public.ventas_privadas;
create policy ver on public.ventas_privadas for select using ((select puede_ver()));

-- p_confirmar = false: solo revisa las claves y dice cuáles se pueden vender y cuáles no.
-- p_confirmar = true : registra la venta con las que sí se pueden.
create or replace function public.venta_privada(
  p_clienta uuid, p_claves text, p_precio numeric, p_confirmar boolean default false, p_usuario text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
  v_cl clientas;
  v_txt text;
  v_num integer;
  p prendas;
  v_si integer[] := '{}';
  v_no jsonb := '[]'::jsonb;
  v_vistas integer[] := '{}';
  v_claves text[];
  v_n integer;
  v_total numeric;
  v_tz text;
  a asignaciones;
  v_ped uuid;
begin
  if not es_duena() then raise exception 'Solo una Dueña puede registrar una venta privada.'; end if;
  select * into v_cl from clientas where id = p_clienta;
  if not found then raise exception 'No se encontró la clienta.'; end if;
  if p_precio is null or p_precio <= 0 or p_precio > 100000 then raise exception 'Escribe un precio válido, mayor a cero.'; end if;

  for v_txt in select t from regexp_split_to_table(upper(coalesce(p_claves, '')), '[^A-Z0-9]+') t where t <> '' loop
    v_num := clave_a_num(v_txt);
    if v_num is null then
      v_no := v_no || jsonb_build_object('clave', v_txt, 'motivo', 'no es una clave válida');
      continue;
    end if;
    if v_num = any (v_vistas) then continue; end if;
    v_vistas := v_vistas || v_num;

    perform prenda_asegurar(v_num);
    select * into p from prendas where numero = v_num for update;
    if not found then
      v_no := v_no || jsonb_build_object('clave', v_txt, 'motivo', 'no tiene etiqueta impresa');
      continue;
    end if;
    if p.estado <> 'disponible' then
      v_no := v_no || jsonb_build_object('clave', live_num(v_num), 'motivo',
        case p.estado
          when 'apartada' then 'está apartada' || coalesce(' por ' || (
            select trim(c.nombre || coalesce(' ' || c.apellidos, '')) from live_apartados x join clientas c on c.id = x.clienta_id
             where x.prenda = v_num and x.estado = 'apartada' limit 1), '')
          when 'pagada' then 'ya está vendida'
          when 'enviada' then 'ya se envió'
          else 'está dada de baja' end);
      continue;
    end if;
    v_si := v_si || v_num;
  end loop;

  v_n := cardinality(v_si);
  if v_n = 0 and jsonb_array_length(v_no) = 0 then raise exception 'Escribe por lo menos una clave.'; end if;
  select coalesce(array_agg(live_num(n) order by o), '{}') into v_claves from unnest(v_si) with ordinality t(n, o);
  v_total := v_n * p_precio;

  if not coalesce(p_confirmar, false) then
    return jsonb_build_object('confirmada', false, 'precio', p_precio, 'prendas', v_n, 'total', v_total,
      'si', to_jsonb(v_claves), 'no', v_no);
  end if;

  if v_n = 0 then raise exception 'Ninguna de esas claves se puede vender.'; end if;

  -- Las ventas de una misma clienta se acomodan una por una (igual que los pagos del live)
  perform pg_advisory_xact_lock(hashtext('cajas-de-' || p_clienta));
  a := caja_para_pedido(p_clienta, v_n);
  if a.id is null then raise exception 'No hay cajas de resguardo libres. Libera una caja y vuelve a intentar.'; end if;

  select zona_horaria into v_tz from live_config limit 1;
  insert into pedidos (asignacion_id, clienta_id, caja, fecha, items, prendas, total, notas, creado_por)
  values (a.id, p_clienta, a.caja, now(),
          jsonb_build_array(jsonb_build_object('cat', 'privada', 'nombre', 'Venta privada', 'precio', p_precio, 'cantidad', v_n)),
          v_n, v_total,
          format('Venta privada del %s · piezas %s',
                 to_char(now() at time zone coalesce(v_tz, 'America/Mexico_City'), 'DD/MM/YYYY'), array_to_string(v_claves, ', ')),
          coalesce(v_por, 'Venta privada'))
  returning id into v_ped;

  update prendas set estado = 'pagada', actualizada_en = now() where numero = any (v_si);

  insert into ventas_privadas (clienta_id, precio, piezas, total, pedido_id, caja, creada_por)
  values (p_clienta, p_precio, v_si, v_total, v_ped, a.caja, v_por);

  perform bitacora_anotar('venta privada', jsonb_build_object(
    'clienta', trim(v_cl.nombre || coalesce(' ' || v_cl.apellidos, '')), 'piezas', to_jsonb(v_claves),
    'precio', p_precio, 'total', v_total, 'caja', a.caja, 'por', v_por));

  return jsonb_build_object('confirmada', true, 'precio', p_precio, 'prendas', v_n, 'total', v_total,
    'si', to_jsonb(v_claves), 'no', v_no, 'caja', a.caja, 'pedido', v_ped);
end $$;

revoke all on function public.venta_privada(uuid, text, numeric, boolean, text) from public, anon;
grant execute on function public.venta_privada(uuid, text, numeric, boolean, text) to authenticated;

-- Deshacer: al borrar el pedido de una venta privada, sus prendas regresan a disponibles
create or replace function public.ventas_privadas_al_borrar_pedido() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update prendas set estado = 'disponible', actualizada_en = now()
   where estado = 'pagada'
     and numero in (select unnest(v.piezas) from ventas_privadas v where v.pedido_id = old.id and v.cancelada_en is null);
  update ventas_privadas set cancelada_en = now() where pedido_id = old.id and cancelada_en is null;
  return old;
end $$;

drop trigger if exists ventas_privadas_al_borrar_pedido on public.pedidos;
create trigger ventas_privadas_al_borrar_pedido before delete on public.pedidos
  for each row execute function public.ventas_privadas_al_borrar_pedido();
