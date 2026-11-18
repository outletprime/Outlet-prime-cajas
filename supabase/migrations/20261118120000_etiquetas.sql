-- =====================================================================
-- Etiquetas de las prendas: qué claves ya se mandaron a imprimir.
--
--  - Quien imprime (Supervisor o Dueña) pide N etiquetas, siempre en múltiplos de 6
--    (una hoja Janel J-5164 trae 6). El sistema le da las N claves que siguen y las
--    anota como impresas, para que nunca se imprima dos veces la misma clave.
--  - Solo claves de dos letras y dos números (AB10 … ZY98), en el orden del sistema.
--  - El PDF se arma en el panel; aquí solo se lleva la cuenta. Un lote se puede volver
--    a descargar con etiquetas_lote() si la impresión falló.
-- =====================================================================

create table if not exists public.etiquetas_lotes (
  id uuid primary key default gen_random_uuid(),
  desde integer not null,
  hasta integer not null,
  cantidad integer not null check (cantidad > 0),
  hecho_por text,
  hecho_en timestamptz not null default now(),
  check (hasta >= desde)
);
alter table public.etiquetas_lotes enable row level security;   -- sin políticas: solo se usa por funciones

create or replace function public.puede_imprimir_etiquetas() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'supervisor'))
$$;

-- Las siguientes p_cantidad claves de etiqueta a partir de p_desde (incluida)
create or replace function public.etiquetas_siguientes(p_desde integer, p_cantidad integer) returns integer[]
language sql stable set search_path = public as $$
  select coalesce(array_agg(p order by p), '{}')
    from (select p from generate_series(greatest(p_desde, 2278), 52371) p
           where clave_valida(p) and (p - 2278) % 99 + 1 >= 10
           limit greatest(p_cantidad, 0)) t
$$;

create or replace function public.etiquetas_lote_json(l public.etiquetas_lotes) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', l.id, 'desde', num_a_clave(l.desde), 'hasta', num_a_clave(l.hasta),
                            'cantidad', l.cantidad, 'hojas', l.cantidad / 6, 'hecho_por', l.hecho_por, 'hecho_en', l.hecho_en)
$$;

create or replace function public.etiquetas_estado() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_sig integer[];
begin
  if not puede_imprimir_etiquetas() then raise exception 'Tu nivel de acceso no permite imprimir etiquetas.'; end if;
  v_sig := etiquetas_siguientes(coalesce((select max(hasta) + 1 from etiquetas_lotes), 2278), 1);
  return jsonb_build_object(
    'siguiente', case when cardinality(v_sig) > 0 then num_a_clave(v_sig[1]) end,
    'impresas', (select coalesce(sum(cantidad), 0) from etiquetas_lotes),
    'lotes', (select coalesce(jsonb_agg(etiquetas_lote_json(x) order by x.hecho_en desc), '[]'::jsonb)
                from (select * from etiquetas_lotes order by hecho_en desc limit 8) x));
end $$;

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
  return etiquetas_lote_json(l)
    || jsonb_build_object('claves', (select jsonb_agg(num_a_clave(n) order by n) from unnest(v_nums) n));
end $$;

-- Para volver a descargar un lote que ya se generó
create or replace function public.etiquetas_lote(p_lote uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l etiquetas_lotes;
begin
  if not puede_imprimir_etiquetas() then raise exception 'Tu nivel de acceso no permite imprimir etiquetas.'; end if;
  select * into l from etiquetas_lotes where id = p_lote;
  if not found then raise exception 'No existe ese lote de etiquetas.'; end if;
  return etiquetas_lote_json(l)
    || jsonb_build_object('claves', (select jsonb_agg(num_a_clave(n) order by n)
                                       from unnest(etiquetas_siguientes(l.desde, l.cantidad)) n));
end $$;

-- Lo que ya se imprimió antes de que existiera esta pantalla (PDFs del 17 y 18 de nov)
insert into public.etiquetas_lotes (desde, hasta, cantidad, hecho_por, hecho_en)
select clave_a_num(d), clave_a_num(h), c, 'PDF entregado', f::timestamptz
  from (values ('AB10', 'AC79', 144, '2026-11-17 18:00-06'), ('AC80', 'AJ52', 462, '2026-11-18 10:30-06')) t(d, h, c, f)
 where not exists (select 1 from public.etiquetas_lotes);

revoke all on function public.puede_imprimir_etiquetas(), public.etiquetas_siguientes(integer, integer),
  public.etiquetas_lote_json(public.etiquetas_lotes), public.etiquetas_estado(),
  public.etiquetas_generar(integer, text), public.etiquetas_lote(uuid) from public, anon, authenticated;
grant execute on function public.puede_imprimir_etiquetas(), public.etiquetas_estado(),
  public.etiquetas_generar(integer, text), public.etiquetas_lote(uuid) to authenticated, service_role;
