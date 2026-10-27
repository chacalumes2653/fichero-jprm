-- =====================================================================
-- FICHERO JPRM · LEGAJO DIGITAL (material escaneado por paciente)
-- Ejecutar completo en Supabase > SQL Editor (se puede correr más de una vez).
--
-- Seguridad: las tablas NO se pueden leer ni escribir directamente.
-- Todo pasa por funciones que validan el token de sesión del Fichero
-- (el mismo x-fichero-token del login, vía fichero_yo()).
-- Sin sesión válida no se ve ni una imagen.
-- =====================================================================

-- 1) Tablas -----------------------------------------------------------
create table if not exists public.fichero_escaneos (
  id             uuid primary key default gen_random_uuid(),
  material_id    text not null,                 -- id de fichero_materiales
  lote           uuid not null,                 -- agrupa las páginas de un mismo escaneo
  pagina         int  not null,
  descripcion    text,
  mime           text not null,
  bytes          int  not null,
  datos          bytea not null,                -- imagen comprimida (webp/jpeg, ~80-200 KB)
  usuario_id     text,
  usuario_nombre text,
  creado         timestamptz not null default now(),
  unique (lote, pagina)
);
create index if not exists fichero_escaneos_mat_idx on public.fichero_escaneos (material_id, creado desc);

create table if not exists public.fichero_escaneos_log (
  id             bigint generated always as identity primary key,
  usuario_id     text,
  usuario_nombre text,
  accion         text not null,                 -- abrir / escanear / ver / pdf / backup / backup_total / borrar
  material_id    text,
  detalle        text,
  creado         timestamptz not null default now()
);

alter table public.fichero_escaneos     enable row level security;   -- sin políticas = cerrado
alter table public.fichero_escaneos_log enable row level security;
revoke all on public.fichero_escaneos, public.fichero_escaneos_log from anon, authenticated;

-- 2) Sesión actual (usa el login del Fichero) ---------------------------
create or replace function public._fesc_yo() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  select to_jsonb(y) into v from public.fichero_yo() y limit 1;
  if v is null or v->>'id' is null then
    raise exception 'Sesión vencida o inválida. Ingresá de nuevo.' using errcode = '28000';
  end if;
  return v;
end $$;

create or replace function public._fesc_nombre(u jsonb) returns text
language sql immutable as $$
  select trim(coalesce(u->>'jerarquia','') || ' ' || coalesce(u->>'nombre',''))
$$;

create or replace function public._fesc_log(u jsonb, p_accion text, p_material text, p_detalle text) returns void
language sql security definer set search_path = public as $$
  insert into public.fichero_escaneos_log (usuario_id, usuario_nombre, accion, material_id, detalle)
  values (u->>'id', public._fesc_nombre(u), p_accion, p_material, p_detalle)
$$;

revoke execute on function public._fesc_yo(), public._fesc_log(jsonb,text,text,text) from public, anon, authenticated;

-- 3) Subir una página --------------------------------------------------
create or replace function public.fichero_esc_subir(
  p_material_id text, p_lote uuid, p_pagina int, p_descripcion text, p_mime text, p_datos text)
returns uuid language plpgsql security definer set search_path = public as $$
declare u jsonb := public._fesc_yo(); b bytea; nid uuid;
begin
  if p_mime not in ('image/webp','image/jpeg') then raise exception 'Formato de imagen no permitido'; end if;
  b := decode(p_datos, 'base64');
  if length(b) > 1500000 then raise exception 'La imagen supera 1,5 MB'; end if;
  if not exists (select 1 from public.fichero_materiales where id::text = p_material_id) then
    raise exception 'El material no existe';
  end if;
  insert into public.fichero_escaneos (material_id, lote, pagina, descripcion, mime, bytes, datos, usuario_id, usuario_nombre)
  values (p_material_id, p_lote, p_pagina, nullif(trim(p_descripcion), ''), p_mime, length(b), b, u->>'id', public._fesc_nombre(u))
  on conflict (lote, pagina) do nothing          -- reintentos de la cola no duplican
  returning id into nid;
  if nid is not null and p_pagina = 1 then
    perform public._fesc_log(u, 'escanear', p_material_id, coalesce(nullif(trim(p_descripcion), ''), 'Material escaneado'));
  end if;
  return nid;
end $$;

-- 4) Listar el legajo de un material (sin las imágenes) ----------------
create or replace function public.fichero_esc_listar(p_material_id text)
returns table (id uuid, lote uuid, pagina int, descripcion text, mime text, bytes int, usuario_nombre text, creado timestamptz)
language plpgsql security definer set search_path = public as $$
declare u jsonb := public._fesc_yo();
begin
  perform public._fesc_log(u, 'abrir', p_material_id, null);
  return query
    select e.id, e.lote, e.pagina, e.descripcion, e.mime, e.bytes, e.usuario_nombre, e.creado
    from public.fichero_escaneos e
    where e.material_id = p_material_id
    order by e.creado desc, e.pagina;
end $$;

-- 5) Ver una página (devuelve la imagen en base64) ----------------------
create or replace function public.fichero_esc_ver(p_id uuid)
returns table (mime text, datos text)
language plpgsql security definer set search_path = public as $$
declare u jsonb := public._fesc_yo();
begin
  return query
    select e.mime, translate(encode(e.datos, 'base64'), E'\n', '')
    from public.fichero_escaneos e where e.id = p_id;
end $$;

-- 6) Registrar acciones desde la app (ver, pdf, backup) -----------------
create or replace function public.fichero_esc_log(p_accion text, p_material_id text, p_detalle text default null)
returns void language plpgsql security definer set search_path = public as $$
declare u jsonb := public._fesc_yo();
begin
  if p_accion not in ('ver','pdf','backup','backup_total') then raise exception 'Acción inválida'; end if;
  perform public._fesc_log(u, p_accion, p_material_id, left(p_detalle, 200));
end $$;

-- 7) Borrar un escaneo completo (personal con panel) ----------------------------
create or replace function public.fichero_esc_borrar_lote(p_lote uuid)
returns int language plpgsql security definer set search_path = public as $$
declare u jsonb := public._fesc_yo(); n int; mat text; des text;
begin
  select material_id, descripcion into mat, des from public.fichero_escaneos where lote = p_lote limit 1;
  delete from public.fichero_escaneos where lote = p_lote;
  get diagnostics n = row_count;
  if n > 0 then perform public._fesc_log(u, 'borrar', mat, coalesce(des, '') || ' (' || n || ' pág.)'); end if;
  return n;
end $$;

-- 8) Índice completo para el backup total (personal con panel) ------------------
create or replace function public.fichero_esc_todos(p_desde timestamptz default null)
returns table (id uuid, material_id text, lote uuid, pagina int, descripcion text, mime text, bytes int,
               creado timestamptz, apellido_nombre text, dni text)
language plpgsql security definer set search_path = public as $$
declare u jsonb := public._fesc_yo();
begin
  return query
    select e.id, e.material_id, e.lote, e.pagina, e.descripcion, e.mime, e.bytes, e.creado,
           m.apellido_nombre::text, m.dni::text
    from public.fichero_escaneos e
    left join public.fichero_materiales m on m.id::text = e.material_id
    where p_desde is null or e.creado >= p_desde
    order by m.apellido_nombre, e.creado, e.pagina;
end $$;

-- 9) Espacio usado (para el panel) ---------------------------------------
create or replace function public.fichero_esc_uso()
returns table (paginas bigint, pacientes bigint, bytes bigint)
language plpgsql security definer set search_path = public as $$
declare u jsonb := public._fesc_yo();
begin
  return query select count(*), count(distinct material_id), coalesce(sum(e.bytes), 0)::bigint from public.fichero_escaneos e;
end $$;

-- 9b) Resumen por material para los resultados de búsqueda ----------------
create or replace function public.fichero_esc_resumen(p_ids text[])
returns table (material_id text, escaneos bigint, paginas bigint, ultimo timestamptz)
language plpgsql security definer set search_path = public as $$
declare u jsonb := public._fesc_yo();
begin
  return query
    select e.material_id, count(distinct e.lote), count(*), max(e.creado)
    from public.fichero_escaneos e
    where e.material_id = any (p_ids[1:100])
    group by e.material_id;
end $$;

-- 10) Permisos: solo se ejecutan las funciones (con token válido adentro)
grant execute on function
  public.fichero_esc_subir(text, uuid, int, text, text, text),
  public.fichero_esc_listar(text),
  public.fichero_esc_ver(uuid),
  public.fichero_esc_log(text, text, text),
  public.fichero_esc_borrar_lote(uuid),
  public.fichero_esc_todos(timestamptz),
  public.fichero_esc_uso(),
  public.fichero_esc_resumen(text[])
to anon, authenticated;

notify pgrst, 'reload schema';
