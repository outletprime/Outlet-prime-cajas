-- La burbuja de ayuda con clientas que tienen varias cajas: la consulta de clienta devuelve una fila por clienta
-- (antes se repetía por cada caja) y agrega "todas_sus_cajas" con las prendas y el estado de la guía de cada una.
-- La consulta de una caja también dice cómo va su guía.
do $$
declare
  def text;
  v_join constant text := 'left join asignaciones a on a.clienta_id = h.id and a.estado = ''activa''';
  v_caja constant text := '''telefono'', case when v_todo then nullif(h.telefono, '''') end,';
  v_una constant text := '''caja'', k.id, ''capacidad'', k.capacidad, ''libre'', a.id is null,';
begin
  select pg_get_functiondef('public.ayuda_consulta(text, text, date, date)'::regprocedure) into def;
  if position('todas_sus_cajas' in def) > 0 then return; end if;
  if position(v_join in def) = 0 or position(v_caja in def) = 0 or position(v_una in def) = 0 then
    raise exception 'No se encontró dónde cambiar ayuda_consulta.';
  end if;
  def := replace(def, v_join,
    'left join lateral (select x.* from asignaciones x where x.clienta_id = h.id and x.estado = ''activa'' order by x.asignada_en limit 1) a on true');
  def := replace(def, v_caja, v_caja || '
             ''todas_sus_cajas'', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                   ''caja'', x.caja,
                   ''prendas'', coalesce((select sum(p.prendas) from pedidos p where p.asignacion_id = x.id), 0),
                   ''guia'', case when x.guia_pegada_en is not null then ''guía pegada · '' || case x.entrega when ''sucursal'' then ''para llevar a sucursal'' else ''lista para recolección'' end
                                  when x.lista_guia_en is not null then ''lista para generar guía'' end)) order by x.caja)
                 from asignaciones x where x.clienta_id = h.id and x.estado = ''activa''),');
  def := replace(def, v_una, v_una || '
             ''guia'', case when a.guia_pegada_en is not null then ''guía pegada · '' || case a.entrega when ''sucursal'' then ''para llevar a sucursal'' else ''lista para recolección'' end
                            when a.lista_guia_en is not null then ''lista para generar guía'' end,');
  execute def;
end $$;
