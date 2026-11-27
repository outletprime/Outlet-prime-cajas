-- Venta privada (decisión de la dueña, 27 nov 2026):
-- 1. El precio abre en $89 y sube de $10 en $10 con el botón +.
-- 2. La pueden registrar las Dueñas y quien tenga el permiso (equipo.venta_privada): hoy Esmeralda, de Operación live.
--    Confirmar el pago, quitarlo y eliminar la venta sigue siendo solo de Dueñas.

alter table public.equipo add column if not exists venta_privada boolean not null default false;

update public.equipo set venta_privada = true where email = 'esmeraldahernandez6636@gmail.com';

create or replace function public.puede_venta_privada() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from equipo where usuario_id = auth.uid() and (rol = 'duena' or venta_privada))
$$;
revoke all on function public.puede_venta_privada() from public, anon;
grant execute on function public.puede_venta_privada() to authenticated;

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
  if not puede_venta_privada() then raise exception 'No tienes permiso para registrar una venta privada.'; end if;
  select * into v_cl from clientas where id = p_clienta;
  if not found then raise exception 'No se encontró la clienta.'; end if;
  if p_precio is null or p_precio <= 0 or p_precio > 100000 then raise exception 'Escribe un precio válido, mayor a cero.'; end if;
  -- Quien no es Dueña solo vende a $89 o subiendo de $10 en $10 ($99, $109…)
  if not es_duena() and (p_precio < 89 or (p_precio - 89) % 10 <> 0) then
    raise exception 'El precio empieza en $89 y sube de $10 en $10.';
  end if;

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
