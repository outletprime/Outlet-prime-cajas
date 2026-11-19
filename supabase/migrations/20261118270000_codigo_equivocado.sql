-- Acomodo: botón X "código equivocado". Quien acomoda marca una prenda cuya clave no corresponde
-- (no aparece esa etiqueta o no es la prenda). La prenda sale de su lista de "Llevar a su casillero",
-- queda señalada en el pedido y al equipo le llega un aviso para revisarlo con la clienta.
-- No se le quita la prenda a nadie: eso lo decide una Dueña u Operación.
alter table public.live_apartados add column if not exists codigo_equivocado_en timestamptz;
alter table public.live_apartados add column if not exists codigo_equivocado_por text;

create or replace view public.live_acomodo with (security_invoker = true) as
 SELECT a.id, a.live_id, a.prenda, a.prime_prenda, a.estado, a.creado_en, a.actualizado_en,
    a.acomodada_en, a.acomodada_por, a.regresada_en, a.regresada_por,
    COALESCE(live_num(a.prenda), '#' || pp.num) AS etiqueta,
    COALESCE(a.casillero, c.casillero) AS casillero,
    TRIM(BOTH FROM cl.nombre || COALESCE(' ' || cl.apellidos, '')) AS clienta,
    CASE
      WHEN a.estado = 'apartada' AND a.acomodada_en IS NULL AND a.codigo_equivocado_en IS NULL THEN 'acomodar'
      WHEN a.estado = 'liberada' AND a.regresada_en IS NULL AND NOT o.otra THEN 'regresar'
      ELSE 'hecho'
    END AS tarea,
    a.codigo_equivocado_en, a.codigo_equivocado_por
   FROM live_apartados a
     JOIN clientas cl ON cl.id = a.clienta_id
     LEFT JOIN live_cuentas c ON c.id = a.cuenta_id
     LEFT JOIN prime_prendas pp ON pp.id = a.prime_prenda
     CROSS JOIN LATERAL ( SELECT EXISTS ( SELECT 1 FROM live_apartados x
                  WHERE x.estado = ANY (ARRAY['apartada', 'pagada']) AND x.id <> a.id
                    AND (x.prenda = a.prenda OR x.prime_prenda = a.prime_prenda)) AS otra) o
  WHERE (a.estado = 'apartada' AND a.acomodada_en IS NULL AND a.codigo_equivocado_en IS NULL)
     OR (a.estado = 'liberada' AND a.regresada_en IS NULL AND NOT o.otra)
     OR a.acomodada_en > now() - interval '12 hours'
     OR a.regresada_en > now() - interval '12 hours'
     OR a.codigo_equivocado_en > now() - interval '12 hours';

create or replace function public.live_codigo_equivocado(p_apartado uuid, p_por text default null, p_deshacer boolean default false)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_por text := coalesce(nullif(trim(p_por), ''), (select email from equipo where usuario_id = auth.uid()));
  a live_apartados;
  v_cl text;
  v_cas text;
begin
  if auth.uid() is not null and not puede_acomodar() then
    raise exception 'Tu nivel de acceso no permite hacer esto.';
  end if;
  if coalesce(p_deshacer, false) then
    update live_apartados set codigo_equivocado_en = null, codigo_equivocado_por = null where id = p_apartado;
    return;
  end if;
  update live_apartados set codigo_equivocado_en = now(), codigo_equivocado_por = v_por
   where id = p_apartado and estado = 'apartada' and codigo_equivocado_en is null
  returning * into a;
  if not found then return; end if;
  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;
  select coalesce(a.casillero, casillero) into v_cas from live_cuentas where id = a.cuenta_id;
  perform avisos_encolar('acomodo', 'codigo:' || a.id || ':' || extract(epoch from now())::bigint,
    format('⚠️ Código equivocado: %s', coalesce(live_num(a.prenda), 'prenda')),
    format('%s · casillero %s · lo marcó %s. Revisar con la clienta: si pidió otra clave, quítala del pedido y captura la correcta.',
           v_cl, coalesce(v_cas, '—'), split_part(coalesce(v_por, 'acomodo'), '@', 1)),
    'live.html#casilleros');
end $$;
revoke all on function public.live_codigo_equivocado(uuid, text, boolean) from public, anon;
grant execute on function public.live_codigo_equivocado(uuid, text, boolean) to authenticated, service_role;

-- El detalle del pedido también dice cuáles prendas se marcaron con código equivocado
create or replace function public.live_pedido_detalle(p_cuenta uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c live_cuentas;
  v_live lives;
begin
  if not puede_ver() then raise exception 'Tu nivel de acceso no permite ver esto.'; end if;
  select * into c from live_cuentas where id = p_cuenta;
  if not found then raise exception 'No existe esa cuenta.'; end if;
  select * into v_live from lives where id = c.live_id;
  return jsonb_build_object(
    'id', c.id, 'folio', live_folio(c.folio), 'casillero', c.casillero, 'estado', c.estado, 'total', c.total,
    'casilleros', live_unir(live_casilleros_de(c.id)),
    'clienta', (select trim(nombre || coalesce(' ' || apellidos, '')) from clientas where id = c.clienta_id),
    'revisable', c.estado = 'abierta' and v_live.estado = 'cerrado',
    'piezas', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', a.id, 'clave', coalesce(live_num(a.prenda), '#' || pp.num), 'estado', a.estado,
                  'casillero', coalesce(a.casillero, c.casillero), 'precio', a.precio,
                  'revision', a.revision, 'revision_por', a.revision_por, 'revision_en', a.revision_en,
                  'codigo_equivocado', a.codigo_equivocado_en is not null)
                  order by coalesce(a.casillero, c.casillero), a.prenda nulls last, pp.num), '[]'::jsonb)
                 from live_apartados a left join prime_prendas pp on pp.id = a.prime_prenda
                where a.cuenta_id = c.id and a.estado in ('apartada', 'pagada')));
end $$;
