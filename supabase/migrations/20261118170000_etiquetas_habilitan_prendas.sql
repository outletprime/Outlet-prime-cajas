-- =====================================================================
-- Las etiquetas que se mandan a imprimir quedan dadas de alta como prendas.
--
--  - Ya no hay que registrar ningún rango: al generar un lote de etiquetas, esas claves quedan
--    en el sistema como prendas disponibles. Así se pueden buscar aunque nadie las haya pedido,
--    y el inventario cuadra con lo impreso.
--  - Se dan de alta las etiquetas de los lotes que ya se imprimieron (AB10 a AJ52).
--  - Una clave que alguien comenta y NO está en ningún lote impreso se sigue apartando (para no
--    perder una venta en vivo), pero queda señalada para revisarla: puede ser un error de dedo.
-- =====================================================================

-- Etiquetas ya impresas
insert into public.prendas (numero, precio, registrada_por)
select n, coalesce((select precio from public.live_config limit 1), 89), 'etiqueta impresa'
  from public.etiquetas_lotes l, unnest(public.etiquetas_siguientes(l.desde, l.cantidad)) n
on conflict (numero) do nothing;

-- Al generar un lote, sus claves quedan dadas de alta
create or replace function public.etiquetas_generar(p_cantidad integer, p_usuario text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_nums integer[];
  l etiquetas_lotes;
begin
  if not puede_imprimir_etiquetas() then raise exception 'Tu nivel de acceso no permite imprimir etiquetas.'; end if;
  if p_cantidad is null or p_cantidad < 6 or p_cantidad > 600 then
    raise exception 'Escribe entre 6 y 600 etiquetas.';
  end if;
  if p_cantidad % 6 <> 0 then
    raise exception 'Deben ser múltiplos de 6 para imprimir hojas completas (por ejemplo % o %).',
      greatest(p_cantidad - p_cantidad % 6, 6), p_cantidad - p_cantidad % 6 + 6;
  end if;
  perform pg_advisory_xact_lock(hashtext('etiquetas'));
  v_nums := etiquetas_siguientes(coalesce((select max(hasta) + 1 from etiquetas_lotes), 2278), p_cantidad);
  if cardinality(v_nums) < p_cantidad then
    raise exception 'Solo quedan % claves por imprimir.', cardinality(v_nums);
  end if;
  insert into etiquetas_lotes (desde, hasta, cantidad, hecho_por)
  values (v_nums[1], v_nums[p_cantidad], p_cantidad,
          coalesce(nullif(trim(p_usuario), ''), (select email from auth.users where id = auth.uid())))
  returning * into l;
  insert into prendas (numero, precio, registrada_por)
  select n, coalesce((select precio from live_config limit 1), 89), 'etiqueta impresa' from unnest(v_nums) n
  on conflict (numero) do nothing;
  return etiquetas_lote_json(l)
    || jsonb_build_object('claves', (select jsonb_agg(num_a_clave(n) order by n) from unnest(v_nums) n));
end $$;

-- Conciliación: prendas que alguien pidió con una clave que no está en ninguna etiqueta impresa
create or replace function public.prendas_fuera_de_etiquetas() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not puede_ver() then raise exception 'Tu nivel de acceso no permite ver esto.'; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'clave', num_a_clave(p.numero), 'estado', p.estado,
             'clienta', x.clienta, 'casillero', x.casillero, 'usuario', x.usuario) order by p.numero), '[]'::jsonb)
      from prendas p
      left join lateral (
        select trim(c.nombre || coalesce(' ' || c.apellidos, '')) as clienta, cu.casillero, a.origen_usuario as usuario
          from live_apartados a
          join clientas c on c.id = a.clienta_id
          left join live_cuentas cu on cu.id = a.cuenta_id
         where a.prenda = p.numero and a.estado in ('apartada', 'pagada')
         order by a.mensaje_en limit 1) x on true
     where not exists (select 1 from etiquetas_lotes l where p.numero between l.desde and l.hasta)
       and x.clienta is not null);
end $$;

revoke all on function public.prendas_fuera_de_etiquetas() from public, anon;
grant execute on function public.prendas_fuera_de_etiquetas() to authenticated, service_role;
