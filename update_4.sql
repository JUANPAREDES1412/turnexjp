-- =====================================================================
-- ACTUALIZACIÓN 4 — TURNEX
-- Ejecutar completo, UNA VEZ, en el SQL Editor de Supabase.
--
-- POR QUÉ: el mecanismo anterior (leer el token desde variables que
-- llenaba un "gancho" antes de cada petición) no es confiable en todos
-- los proyectos de Supabase. Ahora cada función protegida recibe el
-- token de sesión como parámetro explícito, enviado directamente por
-- la app — sin depender de configuración adicional del servidor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Helper: valida un token y devuelve quién es (rol, empresa, usuario)
-- ---------------------------------------------------------------------
create or replace function session_lookup(p_token text)
returns table(actor_type text, company_id uuid, user_id uuid) as $$
begin
  return query select s.actor_type, s.company_id, s.user_id from sessions s
    where s.token = p_token and s.expires_at > now();
end;
$$ language plpgsql security definer stable;

-- ---------------------------------------------------------------------
-- 2. Crear administrador / empleado (ahora recibe el token)
-- ---------------------------------------------------------------------
drop function if exists create_company_user(uuid, user_role, text, text, text, text, text);
create or replace function create_company_user(
  p_token text, p_company_id uuid, p_role user_role, p_username text, p_password text,
  p_full_name text, p_email text, p_phone text
) returns uuid as $$
declare
  v_id uuid;
  v_actor text; v_company uuid;
  v_limit int; v_count int;
begin
  select actor_type, company_id into v_actor, v_company from session_lookup(p_token);
  if v_actor = 'owner' then
    if p_role <> 'admin' then raise exception 'El propietario solo puede crear administradores.'; end if;
  elsif v_actor = 'admin' and v_company = p_company_id then
    if p_role <> 'employee' then raise exception 'Un administrador solo puede crear empleados.'; end if;
    select max_employees into v_limit from companies where id = p_company_id;
    select count(*) into v_count from app_users where company_id = p_company_id and role = 'employee';
    if v_count >= coalesce(v_limit, 50) then
      raise exception 'Se alcanzó el límite de % empleados permitido para esta empresa. Solo el propietario puede aumentarlo.', v_limit;
    end if;
  else
    raise exception 'No autorizado. Vuelve a iniciar sesión e inténtalo de nuevo.';
  end if;

  insert into app_users (company_id, role, username, password_hash, full_name, email, phone)
  values (p_company_id, p_role, p_username, crypt(p_password, gen_salt('bf')), p_full_name, p_email, p_phone)
  returning id into v_id;
  return v_id;
end;
$$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 3. Cambio de clave propia (autoservicio)
-- ---------------------------------------------------------------------
drop function if exists set_company_user_password(uuid, text);
create or replace function set_company_user_password(p_token text, p_user_id uuid, p_new_password text)
returns void as $$
declare v_user uuid;
begin
  select user_id into v_user from session_lookup(p_token);
  if v_user is distinct from p_user_id then
    raise exception 'Solo puedes cambiar tu propia clave con esta función.';
  end if;
  update app_users set password_hash = crypt(p_new_password, gen_salt('bf')), must_change_password = false
  where id = p_user_id;
end;
$$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 4. Restablecimiento administrativo de clave
-- ---------------------------------------------------------------------
drop function if exists admin_reset_user_password(uuid, text);
create or replace function admin_reset_user_password(p_token text, p_user_id uuid, p_new_password text)
returns void as $$
declare
  v_actor text; v_company uuid;
  v_target app_users%rowtype;
begin
  select actor_type, company_id into v_actor, v_company from session_lookup(p_token);
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

-- ---------------------------------------------------------------------
-- 5. Cambio de clave del propietario
-- ---------------------------------------------------------------------
drop function if exists set_owner_password(text);
create or replace function set_owner_password(p_token text, p_new_password text)
returns void as $$
declare v_actor text;
begin
  select actor_type into v_actor from session_lookup(p_token);
  if v_actor <> 'owner' then raise exception 'No autorizado.'; end if;
  update app_owner set password_hash = crypt(p_new_password, gen_salt('bf')) where id = 1;
end;
$$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 6. Marcación de entrada / salida
-- ---------------------------------------------------------------------
drop function if exists clock_in(uuid);
create or replace function clock_in(p_token text, p_shift_id uuid)
returns timestamptz as $$
declare
  v_actor text; v_user uuid;
  v_shift shifts%rowtype;
  v_emp_id uuid;
  v_allowed_from timestamptz;
  v_now timestamptz := now();
  v_existing time_entries%rowtype;
begin
  select actor_type, user_id into v_actor, v_user from session_lookup(p_token);
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

drop function if exists clock_out(uuid);
create or replace function clock_out(p_token text, p_shift_id uuid)
returns timestamptz as $$
declare
  v_actor text; v_user uuid; v_emp_id uuid;
  v_entry time_entries%rowtype;
  v_now timestamptz := now();
begin
  select actor_type, user_id into v_actor, v_user from session_lookup(p_token);
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
-- 7. Nómina: cerrar / reabrir
-- ---------------------------------------------------------------------
drop function if exists close_payroll_run(date, date, text, numeric, int);
create or replace function close_payroll_run(p_token text, p_period_start date, p_period_end date, p_currency text, p_total numeric, p_employee_count int)
returns uuid as $$
declare
  v_actor text; v_company uuid; v_user uuid; v_id uuid;
begin
  select actor_type, company_id, user_id into v_actor, v_company, v_user from session_lookup(p_token);
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

drop function if exists reopen_payroll_run(uuid);
create or replace function reopen_payroll_run(p_token text, p_run_id uuid)
returns void as $$
declare v_actor text;
begin
  select actor_type into v_actor from session_lookup(p_token);
  if v_actor <> 'owner' then raise exception 'Solo el propietario puede reabrir una liquidación.'; end if;
  delete from payroll_runs where id = p_run_id;
end;
$$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 8. Copias de seguridad: listar, descargar, restaurar (protegidas)
-- ---------------------------------------------------------------------
drop function if exists list_backups();
create or replace function list_backups(p_token text)
returns table(id uuid, created_at timestamptz, note text) as $$
declare v_actor text;
begin
  select actor_type into v_actor from session_lookup(p_token);
  if v_actor <> 'owner' then raise exception 'No autorizado.'; end if;
  return query select b.id, b.created_at, b.note from backups b order by b.created_at desc;
end;
$$ language plpgsql security definer;

drop function if exists get_backup_data(uuid);
create or replace function get_backup_data(p_token text, p_backup_id uuid)
returns jsonb as $$
declare v_actor text; v_data jsonb;
begin
  select actor_type into v_actor from session_lookup(p_token);
  if v_actor <> 'owner' then raise exception 'No autorizado.'; end if;
  select data into v_data from backups where id = p_backup_id;
  return v_data;
end;
$$ language plpgsql security definer;

drop function if exists restore_backup(uuid);
create or replace function restore_backup(p_token text, p_backup_id uuid)
returns void as $$
declare
  v_actor text;
  v_data jsonb;
begin
  select actor_type into v_actor from session_lookup(p_token);
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
-- 9. Eliminar una empresa por completo (SOLO el propietario)
--    Borra en cascada: administradores, empleados, ubicaciones, turnos,
--    marcaciones, tareas, fotos y liquidaciones de esa empresa.
-- ---------------------------------------------------------------------
create or replace function delete_company(p_token text, p_company_id uuid)
returns void as $$
declare v_actor text;
begin
  select actor_type into v_actor from session_lookup(p_token);
  if v_actor <> 'owner' then raise exception 'Solo el propietario puede eliminar una empresa.'; end if;
  delete from companies where id = p_company_id;
end;
$$ language plpgsql security definer;

notify pgrst, 'reload schema';
notify pgrst, 'reload config';

-- =====================================================================
-- FIN. Sube también el nuevo index.html que te entrego junto con esto.
-- Con este cambio, el token viaja explícito en cada acción protegida,
-- sin depender de configuración adicional del servidor.
-- =====================================================================
