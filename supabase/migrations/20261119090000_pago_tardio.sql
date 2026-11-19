-- Pago tardío (solo Dueñas): un pedido que ya venció ("Sin pago · regresar las prendas a racks") se puede
-- rescatar cuando la clienta paga tarde. Sus prendas vuelven a su pedido, se registra el pago y pasan a
-- su caja de resguardo.
--  - Prenda que sigue libre: se recupera.
--  - Prenda que al vencer pasó sola a otra clienta de la lista de espera y esa clienta NO ha pagado:
--    la Dueña decide si se le quita para devolvérsela a quien pagó tarde.
--  - Prenda que otra clienta ya pagó (o dada de baja): no se puede recuperar.

alter table public.live_cuentas add column if not exists pago_tardio_en timestamptz;
alter table public.live_cuentas add column if not exists pago_tardio_por text;

-- Desde ahora, lo que se libera por falta de pago queda marcado (para saber qué se puede rescatar)
do $$
declare def text;
begin
  select pg_get_functiondef(p.oid) into def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'live_revisar_vencimientos';
  if position('liberada_motivo' in def) = 0 then
    if position('update live_apartados set estado = ''liberada'', actualizado_en = now()' in def) = 0 then
      raise exception 'No se encontró dónde se liberan las prendas al vencer.';
    end if;
    execute replace(def, 'update live_apartados set estado = ''liberada'', actualizado_en = now()',
                         'update live_apartados set estado = ''liberada'', liberada_motivo = ''sin pago'', actualizado_en = now()');
  end if;
end $$;
update public.live_apartados a set liberada_motivo = 'sin pago'
  from public.live_cuentas c
 where c.id = a.cuenta_id and c.estado = 'vencida' and a.estado = 'liberada'
   and a.liberada_motivo is null and a.actualizado_en = c.vencida_en;

-- Qué se puede rescatar de un pedido vencido
create or replace function public.live_pago_tardio_info(p_cuenta uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c live_cuentas;
begin
  if not es_duena() then raise exception 'Solo una Dueña puede registrar un pago tardío.'; end if;
  select * into c from live_cuentas where id = p_cuenta;
  if not found then raise exception 'No existe ese pedido.'; end if;
  if c.estado <> 'vencida' then raise exception 'Este pedido no está vencido.'; end if;
  return jsonb_build_object(
    'id', c.id, 'folio', live_folio(c.folio),
    'clienta', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = c.clienta_id),
    'casillero', c.casillero,
    'en_rack', c.casillero_liberado_en is not null,
    'prendas', (select coalesce(jsonb_agg(x order by x->>'clave'), '[]'::jsonb) from (
      select jsonb_build_object(
        'id', a.id,
        'clave', coalesce(live_num(a.prenda), '#' || pp.num),
        'precio', a.precio,
        'en_rack', a.regresada_en is not null or c.casillero_liberado_en is not null,
        'estado', case
          when o.id is null and coalesce(p.estado, pp.estado) = 'disponible' then 'libre'
          when o.id is not null and o.estado = 'apartada' and coalesce(k.monto_pagado, 0) = 0
               and coalesce(k.estado, 'abierta') in ('abierta', 'por_pagar') then 'otra'
          else 'no' end,
        'otra', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = o.clienta_id),
        'otra_folio', live_folio(k.folio),
        'motivo', case when o.estado = 'pagada' then 'ya la pagó otra clienta' when o.id is not null then 'otra clienta ya abonó a su pedido'
                       when coalesce(p.estado, pp.estado) = 'baja' then 'se dio de baja' else 'ya no está disponible' end) x
      from live_apartados a
      left join prendas p on p.numero = a.prenda
      left join prime_prendas pp on pp.id = a.prime_prenda
      left join live_apartados o on o.id <> a.id and o.estado in ('apartada', 'pagada')
            and ((a.prenda is not null and o.prenda = a.prenda) or (a.prime_prenda is not null and o.prime_prenda = a.prime_prenda))
      left join live_cuentas k on k.id = o.cuenta_id
      where a.cuenta_id = c.id and a.estado = 'liberada' and a.liberada_motivo = 'sin pago') s));
end $$;

-- El pago tardío siempre es por el total de lo que se rescata: el pedido pasa directo de vencido a pagado
-- (la clienta puede tener otro pedido abierto en el mismo live, y solo puede haber uno abierto a la vez).
drop function if exists public.live_pago_tardio(uuid, boolean, numeric, text, text);
create or replace function public.live_pago_tardio(p_cuenta uuid, p_quitar_a_otras boolean default false,
                                                   p_usuario text default null, p_referencia text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c live_cuentas;
  r record;
  o live_apartados;
  k live_cuentas;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
  v_cl text;
  v_tel text;
  v_rec text[] := '{}';
  v_no text[] := '{}';
  v_quit text[] := '{}';
  v_rack text[] := '{}';
  v_est text;
  v_nombre_otra text;
  v_caja text;
begin
  if not es_duena() then raise exception 'Solo una Dueña puede registrar un pago tardío.'; end if;
  select * into c from live_cuentas where id = p_cuenta for update;
  if not found then raise exception 'No existe ese pedido.'; end if;
  if c.estado <> 'vencida' then raise exception 'Este pedido no está vencido.'; end if;
  select trim(nombre || coalesce(' ' || apellidos, '')), telefono into v_cl, v_tel from clientas where id = c.clienta_id;

  for r in select a.* from live_apartados a
            where a.cuenta_id = c.id and a.estado = 'liberada' and a.liberada_motivo = 'sin pago'
            order by a.prenda nulls last for update loop
    o := null;
    if r.prenda is not null then
      perform 1 from prendas where numero = r.prenda for update;
      select estado into v_est from prendas where numero = r.prenda;
      select * into o from live_apartados x where x.prenda = r.prenda and x.id <> r.id and x.estado in ('apartada', 'pagada') for update;
    else
      perform 1 from prime_prendas where id = r.prime_prenda for update;
      select estado into v_est from prime_prendas where id = r.prime_prenda;
      select * into o from live_apartados x where x.prime_prenda = r.prime_prenda and x.id <> r.id and x.estado in ('apartada', 'pagada') for update;
    end if;

    if o.id is not null then
      select * into k from live_cuentas where id = o.cuenta_id for update;
      if not (coalesce(p_quitar_a_otras, false) and o.estado = 'apartada' and coalesce(k.monto_pagado, 0) = 0
              and coalesce(k.estado, 'abierta') in ('abierta', 'por_pagar')) then
        v_no := v_no || coalesce(live_num(r.prenda), 'prenda');
        continue;
      end if;
      -- Se le quita a quien la recibió de la lista de espera (no había pagado)
      select split_part(nombre, ' ', 1) into v_nombre_otra from clientas where id = o.clienta_id;
      update live_apartados set estado = 'liberada', liberada_motivo = 'pago tardío de otra clienta', liberada_por = v_por,
                                regresada_en = coalesce(regresada_en, now()), actualizado_en = now()
       where id = o.id;
      if k.id is not null then
        perform live_recalcular(k.id);
        update live_cuentas set estado = 'cancelada', casillero_liberado_en = coalesce(casillero_liberado_en, now())
         where id = k.id and piezas = 0 and estado in ('abierta', 'por_pagar');
      end if;
      v_quit := v_quit || format('%s (%s)', coalesce(live_num(r.prenda), 'prenda'), v_nombre_otra);
    elsif v_est is distinct from 'disponible' then
      v_no := v_no || coalesce(live_num(r.prenda), 'prenda');
      continue;
    end if;

    if r.regresada_en is not null or c.casillero_liberado_en is not null then
      v_rack := v_rack || coalesce(live_num(r.prenda), 'prenda');
    end if;
    -- Vuelve a su pedido, ya pagada
    update live_apartados set estado = 'pagada', liberada_motivo = null, liberada_por = null,
                              regresada_en = null, regresada_por = null, actualizado_en = now()
     where id = r.id;
    if r.prenda is not null then
      update prendas set estado = 'pagada', actualizada_en = now() where numero = r.prenda;
      update live_apartados set estado = 'cancelada', actualizado_en = now() where prenda = r.prenda and estado = 'espera';
    else
      update prime_prendas set estado = 'pagada' where id = r.prime_prenda;
    end if;
    v_rec := v_rec || coalesce(live_num(r.prenda), 'prenda');
  end loop;

  if cardinality(v_rec) = 0 then
    raise exception 'Ya no se puede recuperar ninguna prenda de este pedido: % ya son de otra clienta o no están disponibles.', live_unir(v_no);
  end if;

  perform live_recalcular(c.id);
  update live_cuentas set estado = 'pagada', monto_pagado = total, pagada_en = now(), pagada_por = v_por,
         pago_tardio_en = now(), pago_tardio_por = v_por,
         proveedor_ref = coalesce(nullif(trim(p_referencia), ''), proveedor_ref)
   where id = c.id;
  v_caja := live_pasar_a_caja(c.id);
  select * into c from live_cuentas where id = p_cuenta;
  perform wa_encolar(v_tel, format('✅ Pago recibido (%s). Tus prendas ya van a tu caja. Te avisamos cuando la enviemos.',
    live_dinero(c.monto_pagado)), c.clienta_id);

  perform avisos_encolar('pago', 'pago-tardio:' || c.id || ':' || extract(epoch from now())::bigint,
    format('💸 Pago tardío %s · %s', live_folio(c.folio), v_cl),
    concat_ws(' ',
      format('Se rescató su pedido: %s. Van a la caja %s.', live_unir(v_rec), coalesce(c.caja, '(sin caja libre)')),
      case when cardinality(v_rack) > 0 then format('Ya estaban en el rack: %s (hay que sacarlas).', live_unir(v_rack)) end,
      case when cardinality(v_quit) > 0 then format('Se le quitaron a quien las recibió de la espera: %s.', live_unir(v_quit)) end,
      case when cardinality(v_no) > 0 then format('No se pudieron recuperar: %s.', live_unir(v_no)) end),
    'live.html#casilleros');

  return jsonb_build_object('estado', c.estado, 'caja', c.caja, 'total', c.total, 'monto_pagado', c.monto_pagado,
    'folio', live_folio(c.folio), 'clienta', v_cl, 'casillero', c.casillero,
    'recuperadas', to_jsonb(v_rec), 'no_recuperadas', to_jsonb(v_no), 'quitadas', to_jsonb(v_quit), 'en_rack', to_jsonb(v_rack));
end $$;

revoke all on function public.live_pago_tardio_info(uuid) from public, anon;
revoke all on function public.live_pago_tardio(uuid, boolean, text, text) from public, anon;
grant execute on function public.live_pago_tardio_info(uuid) to authenticated, service_role;
grant execute on function public.live_pago_tardio(uuid, boolean, text, text) to authenticated, service_role;
