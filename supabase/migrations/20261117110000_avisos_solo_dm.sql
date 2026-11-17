-- =====================================================================
-- Quien presenta el live sin tener el nivel Presentadora (por ejemplo una dueña):
-- con avisos_solo_dm = true, en su celular recibe únicamente los avisos "🙋 Pide DM a @usuaria"
-- y ninguno más (pagos, vencidos, cajas, acomodo). En el panel sigue viendo todo lo de su nivel.
-- La función de avisos (supabase/functions/avisos) lee esta columna al repartir cada aviso.
-- Para marcar a alguien:  update equipo set avisos_solo_dm = true where email = 'correo@ejemplo.com';
-- Se puede pegar varias veces sin dañar nada.
-- =====================================================================
alter table public.equipo add column if not exists avisos_solo_dm boolean not null default false;
comment on column public.equipo.avisos_solo_dm is
  'true = presenta el live: en su celular solo recibe los avisos de "Pide DM", sea cual sea su nivel';
