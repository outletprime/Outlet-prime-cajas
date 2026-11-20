-- Una caja con todos sus pedidos adentro se marca de una de dos formas (Dueña, Operación u Operación live):
--   · "Lista para generar guía"      → sigue el flujo de la guía (aviso al Supervisor).
--   · "Lista para recoger en tienda" → la clienta pasa por ella. Aviso a las Dueñas. No lleva guía.
-- Cuando la clienta la recoge, Dueña u Operación la marcan "Entregada en tienda" y la caja queda libre.

alter table public.asignaciones add column if not exists lista_para text
  constraint asignaciones_lista_para_check check (lista_para is null or lista_para in ('guia', 'tienda'));

-- Si se quita la marca de "lista", también se olvida para qué era
create or replace function public.asignaciones_lista_para() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.lista_guia_en is null then new.lista_para := null; end if;
  return new;
end $$;
create or replace trigger lista_para before update on public.asignaciones
  for each row execute function public.asignaciones_lista_para();

create or replace function public.caja_lista_para_tienda(p_asignacion uuid, p_lista boolean default true, p_usuario text default null)
returns public.asignaciones
language plpgsql security definer set search_path = public as $$
declare
  a asignaciones;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
  v_cl text;
  v_ped integer;
  v_pren integer;
  v_falta text;
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion', 'live')) then
    raise exception 'Tu nivel de acceso no permite marcar la caja como lista para recoger.';
  end if;
  select * into a from asignaciones where id = p_asignacion for update;
  if not found or a.estado <> 'activa' then raise exception 'Esa caja ya se entregó o cambió. Revisa de nuevo.'; end if;

  if not coalesce(p_lista, true) then
    if a.lista_para is distinct from 'tienda' then return a; end if;
    update asignaciones set lista_guia_en = null, lista_guia_por = null where id = a.id returning * into a;
    return a;
  end if;
  if a.lista_guia_en is not null then
    if a.lista_para = 'tienda' then return a; end if;
    raise exception 'Esta caja ya está marcada como lista para generar guía. Deshaz esa marca primero.';
  end if;

  select count(*), coalesce(sum(prendas), 0) into v_ped, v_pren from pedidos where asignacion_id = a.id;
  if v_ped = 0 then raise exception 'Esta caja todavía no tiene pedidos.'; end if;
  select string_agg(live_folio(c.folio), ', ' order by c.folio) into v_falta
    from live_cuentas c
   where c.asignacion_id = a.id and c.estado = 'pagada' and c.pedido_id is not null and c.en_caja_en is null;
  if v_falta is not null then
    raise exception 'Todavía falta pasar a la caja: %. Márcalo con "Ya está en la caja" en el panel del live → Casilleros.', v_falta;
  end if;

  update asignaciones set lista_guia_en = now(), lista_guia_por = v_por, lista_para = 'tienda' where id = a.id returning * into a;
  select trim(nombre || coalesce(' ' || apellidos, '')) into v_cl from clientas where id = a.clienta_id;
  insert into avisos (tipo, clave, titulo, cuerpo, url, para_rol)
  values ('caja', 'lista-tienda:' || a.id || ':' || extract(epoch from now())::bigint,
          format('🛍️ Caja %s lista para recoger en tienda', a.caja),
          format('%s · %s %s en %s %s. Avísale que ya puede pasar por su pedido. La marcó %s.',
                 v_cl, v_pren, case when v_pren = 1 then 'prenda' else 'prendas' end,
                 v_ped, case when v_ped = 1 then 'pedido' else 'pedidos' end, split_part(coalesce(v_por, 'el equipo'), '@', 1)),
          'index.html#/caja/' || a.caja, 'duena')
  on conflict (clave) do nothing;
  return a;
end $$;

-- La clienta ya recogió su caja en la tienda: queda entregada y la caja libre (Dueña u Operación)
create or replace function public.caja_entregada_en_tienda(p_asignacion uuid, p_usuario text default null)
returns public.asignaciones
language plpgsql security definer set search_path = public as $$
declare
  a asignaciones;
  v_por text := coalesce(nullif(trim(p_usuario), ''), (select email from equipo where usuario_id = auth.uid()));
begin
  if not exists (select 1 from equipo where usuario_id = auth.uid() and rol in ('duena', 'operacion')) then
    raise exception 'Solo una Dueña u Operación pueden marcar la caja como entregada.';
  end if;
  select * into a from asignaciones where id = p_asignacion for update;
  if not found or a.estado <> 'activa' then raise exception 'Esa caja ya se entregó o cambió. Revisa de nuevo.'; end if;
  if a.lista_para is distinct from 'tienda' then raise exception 'Esta caja no está marcada para recoger en tienda.'; end if;
  update asignaciones set estado = 'enviada', enviada_en = now(), enviada_por = v_por,
         paqueteria = 'Recoge en tienda', notas_envio = coalesce(notas_envio, 'Entregada a la clienta en tienda')
   where id = a.id returning * into a;
  return a;
end $$;

revoke all on function public.caja_lista_para_tienda(uuid, boolean, text) from public, anon;
revoke all on function public.caja_entregada_en_tienda(uuid, text) from public, anon;
grant execute on function public.caja_lista_para_tienda(uuid, boolean, text) to authenticated, service_role;
grant execute on function public.caja_entregada_en_tienda(uuid, text) to authenticated, service_role;

-- La guía no aplica a una caja que se recoge en tienda, y la burbuja de ayuda dice cuál de las dos es
do $$
declare
  def text;
  v_ancla constant text := 'if a.lista_guia_en is null then raise exception ''Primero hay que marcar la caja como lista para generar guía.''; end if;';
begin
  select pg_get_functiondef('public.caja_guia_pegada(uuid, text, text, text, text)'::regprocedure) into def;
  if position('recoger en tienda' in def) = 0 then
    if position(v_ancla in def) = 0 then raise exception 'No se encontró dónde cambiar caja_guia_pegada.'; end if;
    execute replace(def, v_ancla, v_ancla || '
  if a.lista_para = ''tienda'' then raise exception ''Esta caja es para recoger en tienda: no lleva guía.''; end if;');
  end if;

  select pg_get_functiondef('public.ayuda_consulta(text, text, date, date)'::regprocedure) into def;
  if position('lista para recoger en tienda' in def) = 0 then
    def := replace(def, 'when x.lista_guia_en is not null then ''lista para generar guía''',
      'when x.lista_guia_en is not null then case when x.lista_para = ''tienda'' then ''lista para recoger en tienda'' else ''lista para generar guía'' end');
    def := replace(def, 'when a.lista_guia_en is not null then ''lista para generar guía''',
      'when a.lista_guia_en is not null then case when a.lista_para = ''tienda'' then ''lista para recoger en tienda'' else ''lista para generar guía'' end');
    execute def;
  end if;
end $$;
