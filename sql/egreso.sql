-- =====================================================================
-- FICHERO JPRM · EGRESO DEFINITIVO (baja del material) desde el servidor
-- Ejecutar completo en Supabase > SQL Editor (se puede correr más de una vez).
--
-- Hace el cambio de estado + el movimiento en un solo paso, validando el
-- token de sesión del Fichero (fichero_yo). Así cualquier usuario logueado,
-- sea o no admin, puede dar de baja definitiva, sin depender
-- de los permisos de las tablas.
-- =====================================================================

create or replace function public.fichero_egreso(
  p_material_id  text,
  p_estado_ant   text,
  p_destino      text default null,
  p_motivo       text default null,
  p_solicitante  text default null,
  p_observaciones text default null
) returns public.fichero_movimientos
language plpgsql security definer set search_path = public as $$
declare
  y   record;
  n   int;
  mov public.fichero_movimientos;
begin
  select * into y from public.fichero_yo() limit 1;
  if y is null or y.id is null then
    raise exception 'Sesión vencida o inválida. Ingresá de nuevo.' using errcode = '28000';
  end if;
  -- cualquier usuario con sesión válida puede hacer el egreso (sin importar el rol)

  update public.fichero_materiales
     set estado = 'baja'
   where id::text = p_material_id
     and estado::text = p_estado_ant
     and estado::text <> 'baja';
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'El material cambió de estado mientras tanto. Buscalo de nuevo.';
  end if;

  insert into public.fichero_movimientos
         (material_id, tipo, usuario_id, usuario_nombre, destino, motivo, solicitante, observaciones)
  select m.id, 'baja', y.id, trim(coalesce(y.jerarquia::text, '') || ' ' || coalesce(y.nombre::text, '')),
         nullif(trim(p_destino), ''), nullif(trim(p_motivo), ''), nullif(trim(p_solicitante), ''), nullif(trim(p_observaciones), '')
    from public.fichero_materiales m
   where m.id::text = p_material_id
  returning * into mov;

  return mov;
end $$;

grant execute on function public.fichero_egreso(text, text, text, text, text, text) to anon, authenticated;
