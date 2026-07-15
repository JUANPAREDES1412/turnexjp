-- =====================================================================
-- ESQUEMA DE BASE DE DATOS - APP DE CONTROL DE TURNOS MULTI-EMPRESA
-- Motor: PostgreSQL (Supabase)
-- Ejecutar completo en: Supabase > SQL Editor > New query > Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. PROPIETARIO DE LA APP (único, controla todo el sistema)
-- ---------------------------------------------------------------------
create table if not exists app_owner (
  id int primary key default 1,
  username text not null unique,
  password_hash text not null,
  full_name text,
  created_at timestamptz default now(),
  check (id = 1)
);

-- ---------------------------------------------------------------------
-- 2. EMPRESAS (ilimitadas, creadas solo por el propietario)
-- ---------------------------------------------------------------------
create table if not exists companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  legal_id text,               -- NIT (Colombia) / EIN (USA) / CIF-NIF (España/Europa)
  country text not null,       -- Código ISO: CO, US, ES, MX, etc.
  address text,
  city text,
  phone text,
  email text,
  default_currency text not null default 'USD', -- COP, USD, EUR, etc.
  logo_url text,
  active boolean not null default true,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------------
-- 3. USUARIOS (admins de empresa y empleados). El "owner" vive en app_owner.
-- ---------------------------------------------------------------------
create type user_role as enum ('admin','employee');

create table if not exists app_users (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  role user_role not null,
  username text not null,          -- ID de acceso (puede ser cédula, código, etc.)
  password_hash text not null,
  full_name text not null,
  email text,
  phone text,
  active boolean not null default true,
  must_change_password boolean not null default true,
  created_at timestamptz default now(),
  unique (company_id, username)
);

-- ---------------------------------------------------------------------
-- 4. UBICACIONES / SEDES de cada empresa
-- ---------------------------------------------------------------------
create table if not exists locations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  name text not null,
  address text,
  city text,
  country text,
  active boolean not null default true,
  created_at timestamptz default now()
);

-- ---------------------------------------------------------------------
-- 5. FICHA DE EMPLEADO (datos laborales, ligados a un app_users con rol employee)
-- ---------------------------------------------------------------------
create table if not exists employees (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_users(id) on delete cascade,
  company_id uuid not null references companies(id) on delete cascade,
  employee_code text,
  position text,
  default_location_id uuid references locations(id) on delete set null,
  hourly_rate numeric(14,2) not null default 0,
  currency text not null default 'USD',
  contracted_hours_week numeric(6,2) not null default 40,
  hire_date date,
  active boolean not null default true,
  created_at timestamptz default now(),
  unique (user_id)
);

-- ---------------------------------------------------------------------
-- 6. TURNOS PROGRAMADOS (calendario)
-- ---------------------------------------------------------------------
create table if not exists shifts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  employee_id uuid not null references employees(id) on delete cascade,
  location_id uuid references locations(id) on delete set null,
  shift_date date not null,
  start_time time not null,
  end_time time not null,
  status text not null default 'scheduled', -- scheduled | completed | absent | cancelled
  notes text,
  created_by uuid references app_users(id),
  created_at timestamptz default now()
);
create index if not exists idx_shifts_company_date on shifts(company_id, shift_date);
create index if not exists idx_shifts_employee on shifts(employee_id);

-- ---------------------------------------------------------------------
-- 7. REGISTROS DE HORAS TRABAJADAS REALES (para liquidación)
-- ---------------------------------------------------------------------
create table if not exists time_entries (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid references shifts(id) on delete set null,
  employee_id uuid not null references employees(id) on delete cascade,
  company_id uuid not null references companies(id) on delete cascade,
  work_date date not null,
  hours_worked numeric(6,2) not null default 0,
  notes text,
  created_at timestamptz default now()
);
create index if not exists idx_time_entries_company_date on time_entries(company_id, work_date);

-- ---------------------------------------------------------------------
-- 8. TAREAS asignadas a empleados
-- ---------------------------------------------------------------------
create table if not exists tasks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  employee_id uuid references employees(id) on delete cascade,
  title text not null,
  description text,
  due_date date,
  status text not null default 'pending', -- pending | in_progress | done
  assigned_by uuid references app_users(id),
  created_at timestamptz default now()
);
create index if not exists idx_tasks_company on tasks(company_id);

-- ---------------------------------------------------------------------
-- 9. TASAS DE CAMBIO (definidas manualmente por el propietario o el admin)
-- ---------------------------------------------------------------------
create table if not exists exchange_rates (
  currency_code text primary key,  -- USD, COP, EUR, MXN, etc.
  rate_to_usd numeric(18,6) not null,
  updated_at timestamptz default now()
);

insert into exchange_rates (currency_code, rate_to_usd) values
  ('USD', 1),
  ('EUR', 0.92),
  ('COP', 4100),
  ('MXN', 18.5)
on conflict (currency_code) do nothing;

-- =====================================================================
-- FUNCIONES DE AUTENTICACIÓN Y SEGURIDAD (security definer)
-- Las contraseñas nunca se comparan en texto plano desde el navegador.
-- =====================================================================

-- Login del propietario
create or replace function login_owner(p_username text, p_password text)
returns table(id int, full_name text) as $$
begin
  return query
  select o.id, o.full_name
  from app_owner o
  where o.username = p_username
    and o.password_hash = crypt(p_password, o.password_hash);
end;
$$ language plpgsql security definer;

-- Login de admin/empleado (requiere el id de empresa, elegido en el selector de login)
create or replace function login_company_user(p_company_id uuid, p_username text, p_password text)
returns table(id uuid, company_id uuid, role user_role, full_name text, must_change_password boolean) as $$
begin
  return query
  select u.id, u.company_id, u.role, u.full_name, u.must_change_password
  from app_users u
  where u.company_id = p_company_id
    and u.username = p_username
    and u.active = true
    and u.password_hash = crypt(p_password, u.password_hash);
end;
$$ language plpgsql security definer;

-- Crear usuario (admin o empleado) con contraseña ya hasheada
create or replace function create_company_user(
  p_company_id uuid, p_role user_role, p_username text, p_password text,
  p_full_name text, p_email text, p_phone text
) returns uuid as $$
declare
  v_id uuid;
begin
  insert into app_users (company_id, role, username, password_hash, full_name, email, phone)
  values (p_company_id, p_role, p_username, crypt(p_password, gen_salt('bf')), p_full_name, p_email, p_phone)
  returning id into v_id;
  return v_id;
end;
$$ language plpgsql security definer;

-- Crear propietario inicial (ejecutar UNA sola vez manualmente, ver instrucciones abajo)
create or replace function bootstrap_owner(p_username text, p_password text, p_full_name text)
returns void as $$
begin
  insert into app_owner (id, username, password_hash, full_name)
  values (1, p_username, crypt(p_password, gen_salt('bf')), p_full_name)
  on conflict (id) do update
    set username = excluded.username,
        password_hash = excluded.password_hash,
        full_name = excluded.full_name;
end;
$$ language plpgsql security definer;

-- Cambiar contraseña de un usuario de empresa (admin/empleado)
create or replace function set_company_user_password(p_user_id uuid, p_new_password text)
returns void as $$
begin
  update app_users
  set password_hash = crypt(p_new_password, gen_salt('bf')),
      must_change_password = false
  where id = p_user_id;
end;
$$ language plpgsql security definer;

-- Cambiar contraseña del propietario
create or replace function set_owner_password(p_new_password text)
returns void as $$
begin
  update app_owner set password_hash = crypt(p_new_password, gen_salt('bf')) where id = 1;
end;
$$ language plpgsql security definer;

-- =====================================================================
-- SEGURIDAD DE FILAS (RLS) — sistema de sesiones con token
-- Cada login genera un token temporal (12h). Todas las tablas quedan
-- aisladas por empresa y por rol usando ese token; sin token válido,
-- la API no entrega ni permite modificar nada.
-- =====================================================================

create table if not exists sessions (
  token text primary key default encode(gen_random_bytes(32), 'hex'),
  actor_type text not null,
  user_id uuid references app_users(id) on delete cascade,
  company_id uuid references companies(id) on delete cascade,
  created_at timestamptz default now(),
  expires_at timestamptz default now() + interval '12 hours'
);

create or replace function purge_expired_sessions() returns void as $$
  delete from sessions where expires_at < now();
$$ language sql security definer;

create or replace view companies_public as
  select id, name from companies where active = true;
grant select on companies_public to anon;

create or replace function login_owner(p_username text, p_password text)
returns table(token text, id int, full_name text) as $$
declare
  v_owner app_owner%rowtype;
  v_token text;
begin
  select * into v_owner from app_owner o
    where o.username = p_username and o.password_hash = crypt(p_password, o.password_hash);
  if not found then
    return;
  end if;
  insert into sessions(actor_type, user_id, company_id) values ('owner', null, null)
    returning sessions.token into v_token;
  return query select v_token, v_owner.id, v_owner.full_name;
end;
$$ language plpgsql security definer;

create or replace function login_company_user(p_company_id uuid, p_username text, p_password text)
returns table(token text, id uuid, company_id uuid, role user_role, full_name text, must_change_password boolean) as $$
declare
  v_user app_users%rowtype;
  v_token text;
begin
  select * into v_user from app_users u
    where u.company_id = p_company_id and u.username = p_username and u.active = true
      and u.password_hash = crypt(p_password, u.password_hash);
  if not found then
    return;
  end if;
  insert into sessions(actor_type, user_id, company_id) values (v_user.role::text, v_user.id, v_user.company_id)
    returning sessions.token into v_token;
  return query select v_token, v_user.id, v_user.company_id, v_user.role, v_user.full_name, v_user.must_change_password;
end;
$$ language plpgsql security definer;

create or replace function logout_session(p_token text) returns void as $$
  delete from sessions where token = p_token;
$$ language sql security definer;

create or replace function rls_context() returns void as $$
declare
  v_headers json;
  v_token text;
  v_actor text;
  v_company uuid;
  v_user uuid;
begin
  begin
    v_headers := current_setting('request.headers', true)::json;
    v_token := v_headers->>'x-session-token';
  exception when others then
    v_token := null;
  end;
  if v_token is null or v_token = '' then
    perform set_config('app.actor_type', '', true);
    perform set_config('app.company_id', '', true);
    perform set_config('app.user_id', '', true);
    return;
  end if;
  select actor_type, company_id, user_id into v_actor, v_company, v_user
    from sessions where token = v_token and expires_at > now();
  perform set_config('app.actor_type', coalesce(v_actor, ''), true);
  perform set_config('app.company_id', coalesce(v_company::text, ''), true);
  perform set_config('app.user_id', coalesce(v_user::text, ''), true);
end;
$$ language plpgsql security definer;

alter role authenticator set pgrst.db_pre_request = 'public.rls_context';

alter table companies enable row level security;
alter table app_users enable row level security;
alter table locations enable row level security;
alter table employees enable row level security;
alter table shifts enable row level security;
alter table time_entries enable row level security;
alter table tasks enable row level security;
alter table exchange_rates enable row level security;
alter table app_owner enable row level security;
revoke all on app_owner from anon, authenticated;
alter table sessions enable row level security;
revoke all on sessions from anon, authenticated;

create policy companies_owner_all on companies for all
  using (current_setting('app.actor_type', true) = 'owner')
  with check (current_setting('app.actor_type', true) = 'owner');

create policy app_users_owner_all on app_users for all
  using (current_setting('app.actor_type', true) = 'owner')
  with check (current_setting('app.actor_type', true) = 'owner');
create policy app_users_admin_scope on app_users for all
  using (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true))
  with check (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true));
revoke select on app_users from anon, authenticated;
grant select (id, company_id, role, username, full_name, email, phone, active, must_change_password, created_at)
  on app_users to anon, authenticated;
grant insert, delete on app_users to anon, authenticated;
grant update (full_name, email, phone, active) on app_users to anon, authenticated;

create policy locations_admin_all on locations for all
  using (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true))
  with check (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true));
create policy locations_employee_read on locations for select
  using (current_setting('app.actor_type', true) = 'employee'
         and company_id::text = current_setting('app.company_id', true));

create policy employees_admin_all on employees for all
  using (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true))
  with check (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true));
create policy employees_self_read on employees for select
  using (current_setting('app.actor_type', true) = 'employee'
         and user_id::text = current_setting('app.user_id', true));

create policy shifts_admin_all on shifts for all
  using (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true))
  with check (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true));
create policy shifts_employee_read on shifts for select
  using (current_setting('app.actor_type', true) = 'employee'
         and employee_id in (select id from employees where user_id::text = current_setting('app.user_id', true)));

create policy time_entries_admin_all on time_entries for all
  using (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true))
  with check (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true));

create policy tasks_admin_all on tasks for all
  using (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true))
  with check (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true));
create policy tasks_employee_read on tasks for select
  using (current_setting('app.actor_type', true) = 'employee'
         and company_id::text = current_setting('app.company_id', true)
         and (employee_id is null or employee_id in (select id from employees where user_id::text = current_setting('app.user_id', true))));

create policy rates_owner_all on exchange_rates for all
  using (current_setting('app.actor_type', true) = 'owner')
  with check (current_setting('app.actor_type', true) = 'owner');
create policy rates_read on exchange_rates for select
  using (current_setting('app.actor_type', true) in ('admin','employee'));

notify pgrst, 'reload schema';
notify pgrst, 'reload config';

-- =====================================================================
-- FIN DEL ESQUEMA
-- Después de correr este script, crea el propietario ejecutando UNA VEZ
-- (cambia el usuario y la clave):
--
--   select bootstrap_owner('admin', 'TuClaveSegura123', 'Propietario Principal');
--
-- =====================================================================


-- =====================================================================
-- -- ACTUALIZACIÓN 2 — TURNEX
-- Ejecutar completo, UNA VEZ, en el SQL Editor de Supabase.
-- Es aditivo y seguro de correr aunque ya tengas datos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Requisito: habilita la extensión pg_cron para las copias diarias.
--    Ve a Database → Extensions → busca "pg_cron" → actívala,
--    ANTES de correr el resto de este script.
-- ---------------------------------------------------------------------
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------
-- 1. Columnas nuevas para marcación real de entrada/salida
-- ---------------------------------------------------------------------
alter table time_entries add column if not exists clock_in timestamptz;
alter table time_entries add column if not exists clock_out timestamptz;

-- ---------------------------------------------------------------------
-- 2. Tareas: marca de "requiere evidencia fotográfica" + tabla de fotos
-- ---------------------------------------------------------------------
alter table tasks add column if not exists requires_photo boolean not null default false;

create table if not exists task_photos (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references tasks(id) on delete cascade,
  employee_id uuid references employees(id) on delete set null,
  company_id uuid not null references companies(id) on delete cascade,
  photo_base64 text not null,
  taken_at timestamptz default now(),
  notes text
);

-- ---------------------------------------------------------------------
-- 3. Liquidaciones cerradas (bloqueo de nómina ya procesada)
-- ---------------------------------------------------------------------
create table if not exists payroll_runs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  currency text,
  total_amount numeric(16,2),
  employee_count int,
  closed_by uuid references app_users(id),
  closed_at timestamptz default now()
);
create index if not exists idx_payroll_runs_company on payroll_runs(company_id, period_start, period_end);

-- ---------------------------------------------------------------------
-- 4. Copias de seguridad
-- ---------------------------------------------------------------------
create table if not exists backups (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  data jsonb not null,
  note text
);

-- ---------------------------------------------------------------------
-- 5. Helper: identifica quién está llamando (rol/empresa/usuario) leyendo
--    el token de sesión, reutilizable dentro de cualquier función seguridad.
-- ---------------------------------------------------------------------
create or replace function current_session()
returns table(actor_type text, company_id uuid, user_id uuid) as $$
declare
  v_headers json;
  v_token text;
begin
  begin
    v_headers := current_setting('request.headers', true)::json;
    v_token := v_headers->>'x-session-token';
  exception when others then
    v_token := null;
  end;
  if v_token is null or v_token = '' then
    return;
  end if;
  return query select s.actor_type, s.company_id, s.user_id from sessions s
    where s.token = v_token and s.expires_at > now();
end;
$$ language plpgsql security definer stable;

-- ---------------------------------------------------------------------
-- 6. CIERRE DE HUECOS DE SEGURIDAD encontrados en las funciones anteriores
--    (antes no verificaban quién las llamaba; ahora sí).
-- ---------------------------------------------------------------------

-- 6a. bootstrap_owner ya NO permite sobrescribir un propietario existente
create or replace function bootstrap_owner(p_username text, p_password text, p_full_name text)
returns void as $$
begin
  if exists (select 1 from app_owner where id = 1) then
    raise exception 'Ya existe un propietario configurado. Usa set_owner_password para cambiar la clave.';
  end if;
  insert into app_owner (id, username, password_hash, full_name)
  values (1, p_username, crypt(p_password, gen_salt('bf')), p_full_name);
end;
$$ language plpgsql security definer;

-- 6b. create_company_user ahora exige que quien llama sea propietario
--     (creando administradores) o administrador de esa misma empresa
--     (creando empleados). Antes cualquiera con la llave anon podía
--     llamar esta función directamente y crear usuarios sin autorización.
create or replace function create_company_user(
  p_company_id uuid, p_role user_role, p_username text, p_password text,
  p_full_name text, p_email text, p_phone text
) returns uuid as $$
declare
  v_id uuid;
  v_actor text; v_company uuid;
begin
  select actor_type, company_id into v_actor, v_company from current_session();
  if v_actor = 'owner' then
    if p_role <> 'admin' then raise exception 'El propietario solo puede crear administradores.'; end if;
  elsif v_actor = 'admin' and v_company = p_company_id then
    if p_role <> 'employee' then raise exception 'Un administrador solo puede crear empleados.'; end if;
  else
    raise exception 'No autorizado.';
  end if;

  insert into app_users (company_id, role, username, password_hash, full_name, email, phone)
  values (p_company_id, p_role, p_username, crypt(p_password, gen_salt('bf')), p_full_name, p_email, p_phone)
  returning id into v_id;
  return v_id;
end;
$$ language plpgsql security definer;

-- 6c. Cambio de clave PROPIA (autoservicio) — separado del restablecimiento
--     administrativo. Solo permite que cada quien cambie SU PROPIA clave.
create or replace function set_company_user_password(p_user_id uuid, p_new_password text)
returns void as $$
declare
  v_user uuid;
begin
  select user_id into v_user from current_session();
  if v_user is distinct from p_user_id then
    raise exception 'Solo puedes cambiar tu propia clave con esta función.';
  end if;
  update app_users set password_hash = crypt(p_new_password, gen_salt('bf')), must_change_password = false
  where id = p_user_id;
end;
$$ language plpgsql security definer;

-- 6d. Restablecimiento ADMINISTRATIVO de clave (propietario→admin, o
--     administrador→empleado de su propia empresa). Marca la clave como
--     temporal (must_change_password = true).
create or replace function admin_reset_user_password(p_user_id uuid, p_new_password text)
returns void as $$
declare
  v_actor text; v_company uuid;
  v_target app_users%rowtype;
begin
  select actor_type, company_id into v_actor, v_company from current_session();
  select * into v_target from app_users where id = p_user_id;
  if v_target.id is null then raise exception 'Usuario no encontrado.'; end if;

  if v_actor = 'owner' and v_target.role = 'admin' then
    null;
  elsif v_actor = 'admin' and v_target.company_id = v_company then
    null;
  else
    raise exception 'No autorizado.';
  end if;

  update app_users set password_hash = crypt(p_new_password, gen_salt('bf')), must_change_password = true
  where id = p_user_id;
end;
$$ language plpgsql security definer;

-- 6e. Cambio de clave del propietario, ahora verificado
create or replace function set_owner_password(p_new_password text)
returns void as $$
declare v_actor text;
begin
  select actor_type into v_actor from current_session();
  if v_actor <> 'owner' then raise exception 'No autorizado.'; end if;
  update app_owner set password_hash = crypt(p_new_password, gen_salt('bf')) where id = 1;
end;
$$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 7. Marcación de entrada / salida por el propio empleado
--    Regla: solo se puede marcar entrada desde 1 minuto antes de la
--    hora programada por el administrador (nunca antes).
-- ---------------------------------------------------------------------
create or replace function clock_in(p_shift_id uuid)
returns timestamptz as $$
declare
  v_actor text; v_user uuid;
  v_shift shifts%rowtype;
  v_emp_id uuid;
  v_allowed_from timestamptz;
  v_now timestamptz := now();
  v_existing time_entries%rowtype;
begin
  select actor_type, user_id into v_actor, v_user from current_session();
  if v_actor <> 'employee' then raise exception 'Solo un empleado puede marcar su propia entrada.'; end if;

  select id into v_emp_id from employees where user_id = v_user;
  if v_emp_id is null then raise exception 'Perfil de empleado no encontrado.'; end if;

  select * into v_shift from shifts where id = p_shift_id;
  if v_shift.id is null or v_shift.employee_id <> v_emp_id then
    raise exception 'Turno no encontrado o no te pertenece.';
  end if;
  if v_shift.status <> 'scheduled' then
    raise exception 'Este turno ya no admite marcación de entrada.';
  end if;

  v_allowed_from := ((v_shift.shift_date + v_shift.start_time))::timestamptz - interval '1 minute';
  if v_now < v_allowed_from then
    raise exception 'Aún no puedes marcar tu entrada. Podrás hacerlo desde 1 minuto antes de tu turno (%).',
      to_char(v_allowed_from, 'HH24:MI');
  end if;

  select * into v_existing from time_entries where shift_id = p_shift_id;
  if v_existing.id is not null and v_existing.clock_in is not null then
    raise exception 'Ya habías marcado tu entrada para este turno.';
  end if;

  if v_existing.id is null then
    insert into time_entries (shift_id, employee_id, company_id, work_date, clock_in)
    values (p_shift_id, v_emp_id, v_shift.company_id, v_shift.shift_date, v_now);
  else
    update time_entries set clock_in = v_now where id = v_existing.id;
  end if;

  update shifts set status = 'in_progress' where id = p_shift_id;
  return v_now;
end;
$$ language plpgsql security definer;

create or replace function clock_out(p_shift_id uuid)
returns timestamptz as $$
declare
  v_actor text; v_user uuid; v_emp_id uuid;
  v_entry time_entries%rowtype;
  v_now timestamptz := now();
begin
  select actor_type, user_id into v_actor, v_user from current_session();
  if v_actor <> 'employee' then raise exception 'Solo un empleado puede marcar su propia salida.'; end if;
  select id into v_emp_id from employees where user_id = v_user;

  select * into v_entry from time_entries where shift_id = p_shift_id and employee_id = v_emp_id;
  if v_entry.id is null or v_entry.clock_in is null then
    raise exception 'Debes marcar primero tu entrada.';
  end if;
  if v_entry.clock_out is not null then
    raise exception 'Ya habías marcado tu salida para este turno.';
  end if;

  update time_entries
    set clock_out = v_now,
        hours_worked = round(extract(epoch from (v_now - clock_in)) / 3600.0, 2)
    where id = v_entry.id;

  update shifts set status = 'completed' where id = p_shift_id;
  return v_now;
end;
$$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 8. Cerrar una liquidación (bloquea volver a liquidar el mismo rango)
-- ---------------------------------------------------------------------
create or replace function close_payroll_run(p_period_start date, p_period_end date, p_currency text, p_total numeric, p_employee_count int)
returns uuid as $$
declare
  v_actor text; v_company uuid; v_user uuid; v_id uuid;
begin
  select actor_type, company_id, user_id into v_actor, v_company, v_user from current_session();
  if v_actor <> 'admin' then raise exception 'Solo un administrador de empresa puede cerrar una liquidación.'; end if;

  if exists (
    select 1 from payroll_runs
    where company_id = v_company
      and not (period_end < p_period_start or period_start > p_period_end)
  ) then
    raise exception 'Ya existe una liquidación cerrada que se cruza con estas fechas. Solo el propietario puede reabrirla.';
  end if;

  insert into payroll_runs (company_id, period_start, period_end, currency, total_amount, employee_count, closed_by)
  values (v_company, p_period_start, p_period_end, p_currency, p_total, p_employee_count, v_user)
  returning id into v_id;
  return v_id;
end;
$$ language plpgsql security definer;

create or replace function reopen_payroll_run(p_run_id uuid)
returns void as $$
declare v_actor text;
begin
  select actor_type into v_actor from current_session();
  if v_actor <> 'owner' then raise exception 'Solo el propietario puede reabrir una liquidación.'; end if;
  delete from payroll_runs where id = p_run_id;
end;
$$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 9. Copias de seguridad: crear, listar (vía tabla+RLS) y restaurar
-- ---------------------------------------------------------------------
create or replace function create_backup(p_note text default 'Copia manual')
returns uuid as $$
declare
  v_id uuid;
  v_data jsonb;
begin
  select jsonb_build_object(
    'companies', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from companies c),
    'app_users', (select coalesce(jsonb_agg(to_jsonb(u) - 'password_hash'), '[]'::jsonb) from app_users u),
    'locations', (select coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) from locations l),
    'employees', (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) from employees e),
    'shifts', (select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from shifts s),
    'time_entries', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from time_entries t),
    'tasks', (select coalesce(jsonb_agg(to_jsonb(k)), '[]'::jsonb) from tasks k),
    'payroll_runs', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from payroll_runs p)
  ) into v_data;
  insert into backups (data, note) values (v_data, p_note) returning id into v_id;
  delete from backups where id not in (select id from backups order by created_at desc limit 30);
  return v_id;
end;
$$ language plpgsql security definer;

-- Programar copia automática diaria a las 3:00 a.m. (hora UTC)
do $do$
begin
  if not exists (select 1 from cron.job where jobname = 'turnex_daily_backup') then
    perform cron.schedule('turnex_daily_backup', '0 3 * * *', $sql$select create_backup('Automático diario');$sql$);
  end if;
end
$do$;

-- Listar copias de seguridad disponibles (solo propietario)
create or replace function list_backups()
returns table(id uuid, created_at timestamptz, note text) as $$
declare v_actor text;
begin
  select actor_type into v_actor from current_session();
  if v_actor <> 'owner' then raise exception 'No autorizado.'; end if;
  return query select b.id, b.created_at, b.note from backups b order by b.created_at desc;
end;
$$ language plpgsql security definer;

-- Obtener el contenido completo de una copia (solo propietario, para descargarla)
create or replace function get_backup_data(p_backup_id uuid)
returns jsonb as $$
declare v_actor text; v_data jsonb;
begin
  select actor_type into v_actor from current_session();
  if v_actor <> 'owner' then raise exception 'No autorizado.'; end if;
  select data into v_data from backups where id = p_backup_id;
  return v_data;
end;
$$ language plpgsql security definer;

-- Restaurar una copia (DESTRUCTIVO: reemplaza todos los datos actuales).
-- Los usuarios recuperan sus cuentas pero con clave temporal aleatoria,
-- porque la contraseña real nunca se guarda en la copia por seguridad.
create or replace function restore_backup(p_backup_id uuid)
returns void as $$
declare
  v_actor text;
  v_data jsonb;
begin
  select actor_type into v_actor from current_session();
  if v_actor <> 'owner' then raise exception 'Solo el propietario puede restaurar una copia de seguridad.'; end if;

  select data into v_data from backups where id = p_backup_id;
  if v_data is null then raise exception 'Copia de seguridad no encontrada.'; end if;

  delete from task_photos;
  delete from time_entries;
  delete from shifts;
  delete from tasks;
  delete from payroll_runs;
  delete from employees;
  delete from locations;
  delete from app_users;
  delete from companies;

  insert into companies select * from jsonb_populate_recordset(null::companies, v_data->'companies');
  insert into locations select * from jsonb_populate_recordset(null::locations, v_data->'locations');

  insert into app_users (id, company_id, role, username, password_hash, full_name, email, phone, active, must_change_password, created_at)
  select (x->>'id')::uuid, (x->>'company_id')::uuid, (x->>'role')::user_role, x->>'username',
         crypt(encode(gen_random_bytes(9), 'hex'), gen_salt('bf')),
         x->>'full_name', x->>'email', x->>'phone', (x->>'active')::boolean, true, (x->>'created_at')::timestamptz
  from jsonb_array_elements(v_data->'app_users') as x;

  insert into employees select * from jsonb_populate_recordset(null::employees, v_data->'employees');
  insert into shifts select * from jsonb_populate_recordset(null::shifts, v_data->'shifts');
  insert into time_entries select * from jsonb_populate_recordset(null::time_entries, v_data->'time_entries');
  insert into tasks select * from jsonb_populate_recordset(null::tasks, v_data->'tasks');
  insert into payroll_runs select * from jsonb_populate_recordset(null::payroll_runs, v_data->'payroll_runs');
end;
$$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 10bis. Los empleados necesitan poder leer sus propias marcaciones
--        (antes solo el administrador tenía permiso sobre time_entries)
-- ---------------------------------------------------------------------
drop policy if exists time_entries_employee_read on time_entries;
create policy time_entries_employee_read on time_entries for select
  using (current_setting('app.actor_type', true) = 'employee'
         and employee_id in (select id from employees where user_id::text = current_setting('app.user_id', true)));

-- ---------------------------------------------------------------------
-- 10. Seguridad de filas para las tablas nuevas
-- ---------------------------------------------------------------------
alter table task_photos enable row level security;
create policy task_photos_admin_all on task_photos for all
  using (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true))
  with check (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true));
create policy task_photos_employee_insert on task_photos for insert
  with check (current_setting('app.actor_type', true) = 'employee'
    and company_id::text = current_setting('app.company_id', true)
    and employee_id in (select id from employees where user_id::text = current_setting('app.user_id', true)));
create policy task_photos_employee_read_own on task_photos for select
  using (current_setting('app.actor_type', true) = 'employee'
    and employee_id in (select id from employees where user_id::text = current_setting('app.user_id', true)));

alter table payroll_runs enable row level security;
create policy payroll_runs_owner_all on payroll_runs for all
  using (current_setting('app.actor_type', true) = 'owner')
  with check (current_setting('app.actor_type', true) = 'owner');
create policy payroll_runs_admin_read on payroll_runs for select
  using (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true));

alter table backups enable row level security;
revoke all on backups from anon, authenticated;
-- (sin políticas para anon: solo se accede vía las funciones de arriba)

notify pgrst, 'reload schema';
notify pgrst, 'reload config';

-- =====================================================================
-- FIN. Recuerda subir el nuevo index.html junto con este script — la
-- app ya está adaptada para llamar estas nuevas funciones.
-- =====================================================================
