-- =====================================================================
-- ACTUALIZACIÓN 5 — TURNEX
-- Ejecutar completo, UNA VEZ, en el SQL Editor de Supabase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. LOGIN UNIFICADO: una sola casilla de usuario/clave. La app ya no
--    pide elegir empresa ni indica si eres propietario, administrador
--    o empleado — internamente se detecta con las credenciales.
-- ---------------------------------------------------------------------
create or replace function login_unified(p_username text, p_password text)
returns table(token text, actor_type text, id uuid, company_id uuid, full_name text, must_change_password boolean) as $$
declare
  v_owner app_owner%rowtype;
  v_user app_users%rowtype;
  v_token text;
begin
  select * into v_owner from app_owner o
    where o.username = p_username and o.password_hash = crypt(p_password, o.password_hash);
  if found then
    insert into sessions(actor_type, user_id, company_id) values ('owner', null, null) returning sessions.token into v_token;
    return query select v_token, 'owner'::text, null::uuid, null::uuid, v_owner.full_name, false;
    return;
  end if;

  select * into v_user from app_users u
    where u.username = p_username and u.active = true
      and u.password_hash = crypt(p_password, u.password_hash)
    order by u.created_at asc
    limit 1;
  if found then
    insert into sessions(actor_type, user_id, company_id) values (v_user.role::text, v_user.id, v_user.company_id) returning sessions.token into v_token;
    return query select v_token, v_user.role::text, v_user.id, v_user.company_id, v_user.full_name, v_user.must_change_password;
    return;
  end if;

  return;
end;
$$ language plpgsql security definer;

-- ---------------------------------------------------------------------
-- 2. AUTORIZACIÓN DE HORAS EXTRA (salida después de la hora programada)
-- ---------------------------------------------------------------------
create table if not exists overtime_requests (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references shifts(id) on delete cascade,
  employee_id uuid not null references employees(id) on delete cascade,
  company_id uuid not null references companies(id) on delete cascade,
  requested_clock_out timestamptz not null,
  status text not null default 'pending', -- pending | approved | rejected
  requested_at timestamptz default now(),
  decided_by uuid references app_users(id),
  decided_at timestamptz
);
create index if not exists idx_overtime_company on overtime_requests(company_id, status);

alter table overtime_requests enable row level security;
drop policy if exists overtime_admin_all on overtime_requests;
create policy overtime_admin_all on overtime_requests for all
  using (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true))
  with check (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true));
drop policy if exists overtime_employee_read on overtime_requests;
create policy overtime_employee_read on overtime_requests for select
  using (current_setting('app.actor_type', true) = 'employee'
         and employee_id in (select id from employees where user_id::text = current_setting('app.user_id', true)));

-- ---------------------------------------------------------------------
-- 3. clock_out ahora respeta la hora programada de salida:
--    - Si marca a tiempo o antes: se completa normal, de inmediato.
--    - Si marca después de la hora: NO se completa solo; queda como
--      solicitud de tiempo complementario/hora extra pendiente de
--      autorización del administrador.
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

  if v_now <= v_scheduled_end then
    update time_entries
      set clock_out = v_now, hours_worked = round(extract(epoch from (v_now - clock_in)) / 3600.0, 2)
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

-- Administrador aprueba o rechaza la salida tardía (hora extra)
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
      hours_worked = round(extract(epoch from (v_req.requested_clock_out - clock_in)) / 3600.0, 2)
      where id = v_entry.id;
    update overtime_requests set status = 'approved', decided_by = v_user, decided_at = now() where id = p_request_id;
  else
    v_capped_end := ((v_shift.shift_date + v_shift.end_time))::timestamptz;
    update time_entries set clock_out = v_capped_end,
      hours_worked = round(extract(epoch from (v_capped_end - clock_in)) / 3600.0, 2)
      where id = v_entry.id;
    update overtime_requests set status = 'rejected', decided_by = v_user, decided_at = now() where id = p_request_id;
  end if;
  update shifts set status = 'completed' where id = v_req.shift_id;
end;
$$ language plpgsql security definer;

notify pgrst, 'reload schema';
notify pgrst, 'reload config';

-- =====================================================================
-- FIN. Sube también el nuevo index.html que te entrego junto con esto.
-- =====================================================================
