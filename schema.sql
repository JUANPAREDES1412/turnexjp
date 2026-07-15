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
-- SEGURIDAD DE FILAS (RLS)
-- NOTA IMPORTANTE (leer README): esta app usa autenticación propia (no
-- Supabase Auth), por lo que el navegador se conecta con la llave "anon".
-- Se habilita RLS pero con políticas abiertas de lectura/escritura para
-- que la app funcione de forma sencilla como sitio estático en GitHub
-- Pages. Esto es adecuado para un MVP interno/uso controlado, pero NO
-- aísla realmente los datos entre empresas a nivel de base de datos.
-- Para un entorno de producción con datos sensibles, se recomienda migrar
-- a Supabase Auth + políticas RLS por company_id, o añadir una capa de
-- backend (Edge Functions) que valide sesión antes de tocar las tablas.
-- =====================================================================
alter table companies enable row level security;
alter table app_users enable row level security;
alter table locations enable row level security;
alter table employees enable row level security;
alter table shifts enable row level security;
alter table time_entries enable row level security;
alter table tasks enable row level security;
alter table exchange_rates enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['companies','app_users','locations','employees','shifts','time_entries','tasks','exchange_rates']
  loop
    execute format('drop policy if exists allow_all_%1$s on %1$s', t);
    execute format('create policy allow_all_%1$s on %1$s for all using (true) with check (true)', t);
  end loop;
end $$;

-- =====================================================================
-- FIN DEL ESQUEMA
-- Después de correr este script, crea el propietario ejecutando UNA VEZ
-- (cambia el usuario y la clave):
--
--   select bootstrap_owner('admin', 'TuClaveSegura123', 'Propietario Principal');
--
-- =====================================================================
