-- La venta privada se registra POR COBRAR: las prendas entran desde ese momento a la caja de la clienta
-- (cuentan para el límite de prendas y para los días de la caja), pero la venta queda como pagada
-- hasta que una Dueña confirma el pago.

alter table public.ventas_privadas add column if not exists estado text not null default 'por_cobrar';
alter table public.ventas_privadas add column if not exists pagada_en timestamptz;
alter table public.ventas_privadas add column if not exists pagada_por text;
alter table public.ventas_privadas add column if not exists referencia text;
alter table public.ventas_privadas drop constraint if exists ventas_privadas_estado_check;
alter table public.ventas_privadas add constraint ventas_privadas_estado_check
  check (estado in ('por_cobrar', 'pagada', 'cancelada'));

-- Confirmar el pago (o quitar la confirmación si fue un error). Solo Dueñas.
create or replace function public.venta_privada_pagar(
  p_venta uuid, p_pagada boolean default true, p_usuario text default null, p_referencia text default null
) returns ventas_privadas
language plpgsql security definer set search_path = public as $$
declare
  v ventas_privadas;
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
    update ventas_privadas set estado = 'por_cobrar', pagada_en = null, pagada_por = null, referencia = null
     where id = p_venta returning * into v;
    perform bitacora_anotar('venta privada: se quitó el pago', jsonb_build_object('venta', v.id, 'total', v.total, 'caja', v.caja, 'por', v_por));
  end if;
  return v;
end $$;

revoke all on function public.venta_privada_pagar(uuid, boolean, text, text) from public, anon;
grant execute on function public.venta_privada_pagar(uuid, boolean, text, text) to authenticated;

-- Al borrar el pedido de una venta privada: prendas a disponibles y la venta queda cancelada
create or replace function public.ventas_privadas_al_borrar_pedido() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update prendas set estado = 'disponible', actualizada_en = now()
   where estado = 'pagada'
     and numero in (select unnest(v.piezas) from ventas_privadas v where v.pedido_id = old.id and v.cancelada_en is null);
  update ventas_privadas set cancelada_en = now(), estado = 'cancelada' where pedido_id = old.id and cancelada_en is null;
  return old;
end $$;
