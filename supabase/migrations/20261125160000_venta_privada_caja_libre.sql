-- Reglas de la venta privada (decisión de la dueña, 25 nov 2026):
-- 1. Siempre se le asigna una caja LIBRE (no se mezcla con lo ya pagado de la clienta, porque no se sabe si pagará).
-- 2. Mientras esté por cobrar, su caja no se puede marcar para guía, ni enviar, ni entregar.
-- 3. No cuenta para "prendas por resurtir".

-- Los pedidos pagados del live no entran a una caja que tiene una venta privada por cobrar
create or replace function public.caja_para_pedido(p_clienta uuid, p_prendas integer, p_excluir uuid default null, p_desde timestamptz default null)
returns asignaciones
language plpgsql set search_path = public as $$
declare
  a asignaciones;
  v_caja text;
  v_grande boolean;
begin
  select x.* into a
    from asignaciones x join cajas k on k.id = x.caja
   where x.clienta_id = p_clienta and x.estado = 'activa' and x.lista_guia_en is null
     and (p_excluir is null or x.id <> p_excluir)
     and not exists (select 1 from ventas_privadas v join pedidos pp on pp.id = v.pedido_id
                      where pp.asignacion_id = x.id and v.estado = 'por_cobrar')
     and coalesce((select sum(p.prendas) from pedidos p where p.asignacion_id = x.id), 0) + p_prendas <= k.capacidad
   order by x.asignada_en desc
   limit 1;
  if found then return a; end if;

  v_grande := coalesce((select sum(p.prendas) from pedidos p where p.clienta_id = p_clienta), 0) + p_prendas
              >= coalesce((select clienta_grande_prendas from live_config limit 1), 30);
  select k.id into v_caja from cajas k
   where not exists (select 1 from asignaciones x where x.caja = k.id and x.estado = 'activa')
   order by (k.capacidad >= p_prendas) desc,
            case when v_grande or k.capacidad < p_prendas then -k.capacidad else k.capacidad end,
            substring(k.id from '^[^0-9]*'), nullif(substring(k.id from '[0-9]+'), '')::integer nulls first, k.id
   limit 1
   for update skip locked;
  if v_caja is null then return null; end if;

  insert into asignaciones (caja, clienta_id, estado, asignada_en, asignada_por, movimientos)
  values (v_caja, p_clienta, 'activa', coalesce(p_desde, now()), 'Sistema de lives', '[]'::jsonb)
  returning * into a;
  return a;
end $$;

-- Venta privada: siempre a una caja libre
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
  v_caja text;
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

  -- Siempre una caja libre: la más chica en la que quepan (o la más grande si no caben en ninguna)
  perform pg_advisory_xact_lock(hashtext('cajas-de-' || p_clienta));
  select k.id into v_caja from cajas k
   where not exists (select 1 from asignaciones x where x.caja = k.id and x.estado = 'activa')
   order by (k.capacidad >= v_n) desc,
            case when k.capacidad < v_n then -k.capacidad else k.capacidad end,
            substring(k.id from '^[^0-9]*'), nullif(substring(k.id from '[0-9]+'), '')::integer nulls first, k.id
   limit 1
   for update skip locked;
  if v_caja is null then raise exception 'No hay cajas de resguardo libres. Libera una caja y vuelve a intentar.'; end if;
  insert into asignaciones (caja, clienta_id, estado, asignada_en, asignada_por, movimientos)
  values (v_caja, p_clienta, 'activa', now(), coalesce(v_por, 'Venta privada'), '[]'::jsonb)
  returning * into a;

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

  insert into ventas_privadas (clienta_id, precio, piezas, total, pedido_id, caja, creada_por, estado)
  values (p_clienta, p_precio, v_si, v_total, v_ped, a.caja, v_por, 'por_cobrar');

  perform bitacora_anotar('venta privada', jsonb_build_object(
    'clienta', trim(v_cl.nombre || coalesce(' ' || v_cl.apellidos, '')), 'piezas', to_jsonb(v_claves),
    'precio', p_precio, 'total', v_total, 'caja', a.caja, 'por', v_por));

  return jsonb_build_object('confirmada', true, 'precio', p_precio, 'prendas', v_n, 'total', v_total,
    'si', to_jsonb(v_claves), 'no', v_no, 'caja', a.caja, 'pedido', v_ped);
end $$;

-- Una caja con venta privada por cobrar no se marca para guía, ni sale de la caja, ni se envía, ni se entrega
create or replace function public.asignaciones_por_cobrar() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.lista_guia_en is not null and old.lista_guia_en is null)
     or (new.guia_pegada_en is not null and old.guia_pegada_en is null)
     or (new.recogida_en is not null and old.recogida_en is null)
     or (old.estado = 'activa' and new.estado is distinct from 'activa') then
    if exists (select 1 from ventas_privadas v join pedidos p on p.id = v.pedido_id
                where p.asignacion_id = new.id and v.estado = 'por_cobrar') then
      raise exception 'POR_COBRAR: la caja tiene una venta privada sin pagar' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists por_cobrar on public.asignaciones;
create trigger por_cobrar before update on public.asignaciones
  for each row execute function public.asignaciones_por_cobrar();

-- Quitar el pago solo mientras la caja sigue en su lugar (si ya se marcó para guía o salió, ya no)
create or replace function public.venta_privada_pagar(
  p_venta uuid, p_pagada boolean default true, p_usuario text default null, p_referencia text default null
) returns ventas_privadas
language plpgsql security definer set search_path = public as $$
declare
  v ventas_privadas;
  a asignaciones;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
begin
  if not es_duena() then raise exception 'Solo una Dueña puede confirmar el pago de una venta privada.'; end if;
  select * into v from ventas_privadas where id = p_venta for update;
  if not found or v.estado = 'cancelada' then raise exception 'Esa venta privada ya no existe.'; end if;
  if coalesce(p_pagada, true) then
    if v.estado = 'pagada' then return v; end if;
    update ventas_privadas set estado = 'pagada', pagada_en = now(), pagada_por = v_por,
           referencia = nullif(trim(coalesce(p_referencia, '')), '')
     where id = p_venta returning * into v;
    perform bitacora_anotar('venta privada pagada', jsonb_build_object('venta', v.id, 'total', v.total, 'caja', v.caja, 'por', v_por, 'referencia', v.referencia));
  else
    if v.estado = 'por_cobrar' then return v; end if;
    select x.* into a from asignaciones x join pedidos p on p.asignacion_id = x.id where p.id = v.pedido_id;
    if found and (a.estado <> 'activa' or a.lista_guia_en is not null) then
      raise exception 'Esa caja ya se marcó para guía o ya salió: ya no se puede quitar el pago.';
    end if;
    update ventas_privadas set estado = 'por_cobrar', pagada_en = null, pagada_por = null, referencia = null
     where id = p_venta returning * into v;
    perform bitacora_anotar('venta privada: se quitó el pago', jsonb_build_object('venta', v.id, 'total', v.total, 'caja', v.caja, 'por', v_por));
  end if;
  return v;
end $$;

revoke all on function public.venta_privada(uuid, text, numeric, boolean, text) from public, anon;
grant execute on function public.venta_privada(uuid, text, numeric, boolean, text) to authenticated;
revoke all on function public.venta_privada_pagar(uuid, boolean, text, text) from public, anon;
grant execute on function public.venta_privada_pagar(uuid, boolean, text, text) to authenticated;
