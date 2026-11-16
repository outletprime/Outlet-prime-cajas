-- Aplicada en Supabase el 16 nov 2026 (ya está en la base; no hace falta pegarla).
-- Regresa live_num (claves con letras) y bot_mensaje (registro con usuario de TikTok) a como estaban
-- antes de comentarios_live, usando el texto original de sus migraciones del 14 de noviembre,
-- que la base guarda en supabase_migrations.schema_migrations.
do $r$
declare s text; f text;
begin
  select statements[1] into s from supabase_migrations.schema_migrations where name = 'claves_con_letras';
  f := substring(s from '(create or replace function public\.live_num\(p integer\).*?\$\$;)');
  if f is null then raise exception 'No encontré live_num en claves_con_letras'; end if;
  execute f;

  select statements[1] into s from supabase_migrations.schema_migrations where name = 'bot_whatsapp_liga_tiktok';
  if s is null then raise exception 'No encontré bot_whatsapp_liga_tiktok'; end if;
  execute s;

  select statements[1] into s from supabase_migrations.schema_migrations where name = 'bot_whatsapp_usuario_tiktok_fix';
  if s is null then raise exception 'No encontré bot_whatsapp_usuario_tiktok_fix'; end if;
  execute s;
end $r$;

revoke all on function public.bot_mensaje(text, text, text, text, timestamptz) from public, anon;
grant execute on function public.bot_mensaje(text, text, text, text, timestamptz) to authenticated, service_role;
