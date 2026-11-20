-- Precios especiales: una Dueña le cambia el precio a una o varias prendas por su clave
-- (panel del live → Prendas). Quien la aparte la paga a ese precio.
--   · Prenda disponible                      → se cambia.
--   · Apartada y todavía sin nota de cobro   → se cambia y el total de ese pedido se ajusta solo.
--   · Con nota de cobro mandada, con abono, pagada, enviada o dada de baja → no se cambia.
-- Queda anotado en la bitácora quién cambió qué.
create or replace function public.prendas_precio(p_claves text, p_precio numeric, p_usuario text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
  v_txt text;
  v_num integer;
  p prendas;
  a live_apartados;
  k live_cuentas;
  v_si jsonb := '[]'::jsonb;
  v_no jsonb := '[]'::jsonb;
  v_vistas integer[] := '{}';
begin
  if not es_duena() then raise exception 'Solo una Dueña puede cambiar precios.'; end if;
  if p_precio is null or p_precio <= 0 or p_precio > 100000 then raise exception 'Escribe un precio válido, mayor a cero.'; end if;

  for v_txt in select t from regexp_split_to_table(upper(coalesce(p_claves, '')), '[^A-Z0-9]+') t where t <> '' loop
    v_num := clave_a_num(v_txt);
    if v_num is null then
      v_no := v_no || jsonb_build_object('clave', v_txt, 'motivo', 'no es una clave válida');
      continue;
    end if;
    if v_num = any (v_vistas) then continue; end if;
    v_vistas := v_vistas || v_num;

    select * into p from prendas where numero = v_num for update;
    if not found then
      v_no := v_no || jsonb_build_object('clave', v_txt, 'motivo', 'no tiene etiqueta impresa');
      continue;
    end if;
    if p.estado not in ('disponible', 'apartada') then
      v_no := v_no || jsonb_build_object('clave', live_num(v_num), 'motivo',
        case p.estado when 'pagada' then 'ya está pagada' when 'enviada' then 'ya se envió' else 'está dada de baja' end);
      continue;
    end if;

    a := null; k := null;
    if p.estado = 'apartada' then
      select * into a from live_apartados where prenda = v_num and estado = 'apartada' limit 1 for update;
      if a.cuenta_id is not null then
        select * into k from live_cuentas where id = a.cuenta_id for update;
        if k.cobro_enviado_en is not null or coalesce(k.monto_pagado, 0) > 0 or k.estado not in ('abierta', 'por_pagar') then
          v_no := v_no || jsonb_build_object('clave', live_num(v_num), 'motivo',
            format('ya se le mandó su nota de cobro a %s', (select split_part(nombre, ' ', 1) from clientas where id = k.clienta_id)));
          continue;
        end if;
      end if;
    end if;

    if p.precio is distinct from p_precio then
      update prendas set precio = p_precio, actualizada_en = now() where numero = v_num;
      update live_apartados set precio = p_precio, actualizado_en = now() where prenda = v_num and estado in ('apartada', 'espera');
      if k.id is not null then perform live_recalcular(k.id); end if;
      perform bitacora_anotar('precio de prenda', jsonb_build_object('clave', live_num(v_num), 'antes', p.precio, 'ahora', p_precio, 'por', v_por));
    end if;
    v_si := v_si || jsonb_build_object('clave', live_num(v_num), 'antes', p.precio,
      'apartada_por', case when a.id is not null then (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = a.clienta_id) end);
  end loop;

  if jsonb_array_length(v_si) = 0 and jsonb_array_length(v_no) = 0 then raise exception 'Escribe por lo menos una clave.'; end if;
  return jsonb_build_object('precio', p_precio, 'cambiadas', v_si, 'sin_cambio', v_no);
end $$;

revoke all on function public.prendas_precio(text, numeric, text) from public, anon;
grant execute on function public.prendas_precio(text, numeric, text) to authenticated, service_role;
