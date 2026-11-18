-- =====================================================================
-- Casilleros sin la "C-": A1 … F5, igual que las etiquetas que ya están pegadas.
--
-- Las cajas de resguardo de la app de Cajas también se llaman A1 … H5, así que para que no se
-- confundan, los avisos donde aparecen las dos cosas ahora dicen la palabra completa:
--   ✅ Pagado …  → "Mover casillero A1 → caja B3 · piezas …"
--   ⏰ Sin pago · casillero A1 · Ana
-- Los avisos de acomodo ("📦 AB23 → A1") no cambian: ahí siempre es un casillero.
-- =====================================================================
update public.casilleros
   set id = substr(id, 3)
 where orden between 1 and 30
   and id ~ '^C-[A-F][1-5]$';

do $$
declare def text;
begin
  select pg_get_functiondef(p.oid) into def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'avisos_por_cuenta';
  if position('''casillero '' || c.casillero' in def) = 0 then
    def := replace(def, 'coalesce(c.casillero, ''sus prendas'')', 'coalesce(''casillero '' || c.casillero, ''sus prendas'')');
    def := replace(def, 'coalesce(c.casillero, ''sin casillero'')', 'coalesce(''casillero '' || c.casillero, ''sin casillero'')');
    if position('''casillero '' || c.casillero' in def) = 0 then
      raise exception 'No se encontró el texto de los avisos de pago: revisar avisos_por_cuenta().';
    end if;
    execute def;
  end if;
end $$;
