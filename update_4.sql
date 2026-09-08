-- =====================================================================
-- ACTUALIZACIÓN 7 — TURNEX
-- Ejecutar completo, UNA VEZ, en el SQL Editor de Supabase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. LOGO DE LA EMPRESA
--    El administrador puede actualizar SOLO el logo de su propia
--    empresa; el propietario ya podía (acceso total). Los empleados
--    ahora pueden leer los datos básicos de su propia empresa (para
--    poder mostrarles el logo).
-- ---------------------------------------------------------------------
drop policy if exists companies_admin_update_logo on companies;
create policy companies_admin_update_logo on companies for update
  using (current_setting('app.actor_type', true) = 'admin'
         and id::text = current_setting('app.company_id', true))
  with check (current_setting('app.actor_type', true) = 'admin'
         and id::text = current_setting('app.company_id', true));
grant update (logo_url) on companies to anon, authenticated;

drop policy if exists companies_employee_read on companies;
create policy companies_employee_read on companies for select
  using (current_setting('app.actor_type', true) = 'employee'
         and id::text = current_setting('app.company_id', true));

-- ---------------------------------------------------------------------
-- 2. HORAS EXTRA: margen de 1 minuto completo después de la hora
--    programada de salida, antes de pedir autorización.
-- ---------------------------------------------------------------------
drop function if exists clock_out(text, uuid);
create or replace function clock_out(p_token text, p_shift_id uuid)
returns text as $$
declare
  v_actor text; v_user uuid; v_emp_id uuid;
  v_entry time_entries%rowtype;
  v_shift shifts%rowtype;
  v_now timestamptz := now();
  v_scheduled_end timestamptz;
  v_grace_until timestamptz;
begin
  select actor_type, user_id into v_actor, v_user from session_lookup(p_token);
  if v_actor <> 'employee' then raise exception 'Solo un empleado puede marcar su propia salida.'; end if;
  select id into v_emp_id from employees where user_id = v_user;

  select * into v_shift from shifts where id = p_shift_id;
  if v_shift.id is null or v_shift.employee_id <> v_emp_id then
    raise exception 'Turno no encontrado o no te pertenece.';
  end if;

  select * into v_entry from time_entries where shift_id = p_shift_id and employee_id = v_emp_id;
  if v_entry.id is null or v_entry.clock_in is null then
    raise exception 'Debes marcar primero tu entrada.';
  end if;
  if v_entry.clock_out is not null then
    raise exception 'Ya habías marcado tu salida para este turno.';
  end if;

  if exists (select 1 from overtime_requests where shift_id = p_shift_id and status = 'pending') then
    return 'pending';
  end if;

  v_scheduled_end := ((v_shift.shift_date + v_shift.end_time))::timestamptz;
  v_grace_until := v_scheduled_end + interval '1 minute';

  if v_now <= v_grace_until then
    update time_entries
      set clock_out = v_now, hours_worked = round(extract(epoch from (v_now - clock_in)) / 3600.0, 4)
      where id = v_entry.id;
    update shifts set status = 'completed' where id = p_shift_id;
    return 'ok';
  else
    insert into overtime_requests (shift_id, employee_id, company_id, requested_clock_out, status)
    values (p_shift_id, v_emp_id, v_shift.company_id, v_now, 'pending');
    return 'pending';
  end if;
end;
$$ language plpgsql security definer;

-- decide_overtime: mismo redondeo de precisión (horas y minutos exactos)
create or replace function decide_overtime(p_token text, p_request_id uuid, p_approve boolean)
returns void as $$
declare
  v_actor text; v_company uuid; v_user uuid;
  v_req overtime_requests%rowtype;
  v_shift shifts%rowtype;
  v_entry time_entries%rowtype;
  v_capped_end timestamptz;
begin
  select actor_type, company_id, user_id into v_actor, v_company, v_user from session_lookup(p_token);
  if v_actor <> 'admin' then raise exception 'Solo un administrador puede autorizar horas extra.'; end if;

  select * into v_req from overtime_requests where id = p_request_id;
  if v_req.id is null or v_req.company_id <> v_company then raise exception 'Solicitud no encontrada.'; end if;
  if v_req.status <> 'pending' then raise exception 'Esta solicitud ya fue resuelta.'; end if;

  select * into v_shift from shifts where id = v_req.shift_id;
  select * into v_entry from time_entries where shift_id = v_req.shift_id and employee_id = v_req.employee_id;

  if p_approve then
    update time_entries set clock_out = v_req.requested_clock_out,
      hours_worked = round(extract(epoch from (v_req.requested_clock_out - clock_in)) / 3600.0, 4)
      where id = v_entry.id;
    update overtime_requests set status = 'approved', decided_by = v_user, decided_at = now() where id = p_request_id;
  else
    v_capped_end := ((v_shift.shift_date + v_shift.end_time))::timestamptz;
    update time_entries set clock_out = v_capped_end,
      hours_worked = round(extract(epoch from (v_capped_end - clock_in)) / 3600.0, 4)
      where id = v_entry.id;
    update overtime_requests set status = 'rejected', decided_by = v_user, decided_at = now() where id = p_request_id;
  end if;
  update shifts set status = 'completed' where id = v_req.shift_id;
end;
$$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 3. TAREAS: el empleado también puede actualizar el estado de las
--    tareas asignadas a él, y queda registrada la hora exacta en que
--    se completó (para medir cumplimiento).
-- ---------------------------------------------------------------------
alter table tasks add column if not exists completed_at timestamptz;

drop policy if exists tasks_employee_update on tasks;
create policy tasks_employee_update on tasks for update
  using (current_setting('app.actor_type', true) = 'employee'
         and employee_id in (select id from employees where user_id::text = current_setting('app.user_id', true)))
  with check (current_setting('app.actor_type', true) = 'employee'
         and employee_id in (select id from employees where user_id::text = current_setting('app.user_id', true)));
grant update (status, completed_at) on tasks to anon, authenticated;

notify pgrst, 'reload schema';
notify pgrst, 'reload config';

-- =====================================================================
-- FIN. Sube también el nuevo index.html que te entrego junto con esto.
-- =====================================================================
