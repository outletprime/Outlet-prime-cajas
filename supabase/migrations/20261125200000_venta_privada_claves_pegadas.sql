-- Venta privada: si el lector deja dos claves pegadas en el mismo renglón (AZ59BT73), se separan solas.
do $$
declare
  v_def text := pg_get_functiondef('public.venta_privada(uuid,text,numeric,boolean,text)'::regprocedure);
  v_antes text := $a$regexp_split_to_table(upper(coalesce(p_claves, '')), '[^A-Z0-9]+')$a$;
  v_ahora text := $b$regexp_split_to_table(regexp_replace(upper(coalesce(p_claves, '')), '([0-9])([A-Z])', '\1 \2', 'g'), '[^A-Z0-9]+')$b$;
begin
  if position(v_ahora in v_def) > 0 then return; end if;
  if position(v_antes in v_def) = 0 then raise exception 'No encontré la línea que separa las claves en venta_privada.'; end if;
  execute replace(v_def, v_antes, v_ahora);
end $$;
