-- =====================================================================
-- ACTUALIZACIÓN 6 — TURNEX
-- Ejecutar completo, UNA VEZ, en el SQL Editor de Supabase.
-- =====================================================================

-- =====================================================================
-- 1. SOLICITUDES DE ELIMINACIÓN (empleados, turnos, horas, liquidaciones)
--    El administrador solicita con un motivo; solo el propietario puede
--    aprobar (y ahí sí se elimina) o rechazar.
-- =====================================================================
create table if not exists deletion_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  request_type text not null, -- employee | shift | time_entry | payroll_run
  target_id uuid not null,
  target_label text,
  reason text not null,
  requested_by uuid references app_users(id),
  requested_at timestamptz default now(),
  status text not null default 'pending', -- pending | approved | rejected
  decided_at timestamptz
);
create index if not exists idx_deletion_requests_status on deletion_requests(company_id, status);

alter table deletion_requests enable row level security;
drop policy if exists deletion_requests_owner_all on deletion_requests;
create policy deletion_requests_owner_all on deletion_requests for all
  using (current_setting('app.actor_type', true) = 'owner')
  with check (current_setting('app.actor_type', true) = 'owner');
drop policy if exists deletion_requests_admin_read on deletion_requests;
create policy deletion_requests_admin_read on deletion_requests for select
  using (current_setting('app.actor_type', true) = 'admin'
         and company_id::text = current_setting('app.company_id', true));

create or replace function request_deletion(p_token text, p_request_type text, p_target_id uuid, p_reason text)
returns uuid as $$
declare
  v_actor text; v_company uuid; v_user uuid;
  v_label text;
  v_id uuid;
begin
  select actor_type, company_id, user_id into v_actor, v_company, v_user from session_lookup(p_token);
  if v_actor <> 'admin' then raise exception 'Solo un administrador puede solicitar eliminaciones.'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Debes indicar un motivo.';
  end if;
  if p_request_type not in ('employee','shift','time_entry','payroll_run') then
    raise exception 'Tipo de solicitud inválido.';
  end if;

  if p_request_type = 'employee' then
    select u.full_name || ' (' || u.username || ')' into v_label
      from app_users u join employees e on e.user_id = u.id
      where e.id = p_target_id and e.company_id = v_company;
    if v_label is null then raise exception 'Empleado no encontrado.'; end if;
  elsif p_request_type = 'shift' then
    select 'Turno ' || shift_date || ' ' || start_time || '–' || end_time into v_label
      from shifts where id = p_target_id and company_id = v_company;
    if v_label is null then raise exception 'Turno no encontrado.'; end if;
  elsif p_request_type = 'time_entry' then
    select 'Registro de horas ' || work_date || ' (' || coalesce(hours_worked::text,'0') || ' h)' into v_label
      from time_entries where id = p_target_id and company_id = v_company;
    if v_label is null then raise exception 'Registro de horas no encontrado.'; end if;
  elsif p_request_type = 'payroll_run' then
    select 'Liquidación ' || period_start || ' a ' || period_end || ' (' || coalesce(total_amount::text,'0') || ' ' || coalesce(currency,'') || ')' into v_label
      from payroll_runs where id = p_target_id and company_id = v_company;
    if v_label is null then raise exception 'Liquidación no encontrada.'; end if;
  end if;

  insert into deletion_requests (company_id, request_type, target_id, target_label, reason, requested_by)
  values (v_company, p_request_type, p_target_id, v_label, p_reason, v_user)
  returning id into v_id;
  return v_id;
end;
$$ language plpgsql security definer;

create or replace function decide_deletion(p_token text, p_request_id uuid, p_approve boolean)
returns void as $$
declare
  v_actor text;
  v_req deletion_requests%rowtype;
begin
  select actor_type into v_actor from session_lookup(p_token);
  if v_actor <> 'owner' then raise exception 'Solo el propietario puede aprobar o rechazar eliminaciones.'; end if;

  select * into v_req from deletion_requests where id = p_request_id;
  if v_req.id is null then raise exception 'Solicitud no encontrada.'; end if;
  if v_req.status <> 'pending' then raise exception 'Esta solicitud ya fue resuelta.'; end if;

  if p_approve then
    if v_req.request_type = 'employee' then
      delete from app_users where id = (select user_id from employees where id = v_req.target_id);
    elsif v_req.request_type = 'shift' then
      delete from shifts where id = v_req.target_id;
    elsif v_req.request_type = 'time_entry' then
      delete from time_entries where id = v_req.target_id;
    elsif v_req.request_type = 'payroll_run' then
      delete from payroll_runs where id = v_req.target_id;
    end if;
    update deletion_requests set status = 'approved', decided_at = now() where id = p_request_id;
  else
    update deletion_requests set status = 'rejected', decided_at = now() where id = p_request_id;
  end if;
end;
$$ language plpgsql security definer;

-- =====================================================================
-- 2. GEOLOCALIZACIÓN AL MARCAR ENTRADA (margen de 500 metros)
-- =====================================================================
alter table locations add column if not exists latitude double precision;
alter table locations add column if not exists longitude double precision;

alter table time_entries add column if not exists clock_in_lat double precision;
alter table time_entries add column if not exists clock_in_lng double precision;
alter table time_entries add column if not exists clock_in_distance_m double precision;
alter table time_entries add column if not exists clock_in_within_range boolean;

create or replace function haversine_meters(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision as $$
declare
  v_a double precision;
begin
  if lat1 is null or lng1 is null or lat2 is null or lng2 is null then
    return null;
  end if;
  v_a := sin(radians(lat2-lat1)/2)^2 + cos(radians(lat1))*cos(radians(lat2))*sin(radians(lng2-lng1)/2)^2;
  return 6371000 * 2 * asin(sqrt(least(1::double precision, v_a)));
end;
$$ language plpgsql immutable;

drop function if exists clock_in(text, uuid);
create or replace function clock_in(p_token text, p_shift_id uuid, p_lat double precision default null, p_lng double precision default null)
returns timestamptz as $$
declare
  v_actor text; v_user uuid;
  v_shift shifts%rowtype;
  v_emp_id uuid;
  v_allowed_from timestamptz;
  v_now timestamptz := now();
  v_existing time_entries%rowtype;
  v_loc_id uuid;
  v_loc_lat double precision; v_loc_lng double precision;
  v_distance double precision;
  v_within boolean;
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

  v_loc_id := coalesce(v_shift.location_id, (select default_location_id from employees where id = v_emp_id));
  if v_loc_id is not null then
    select latitude, longitude into v_loc_lat, v_loc_lng from locations where id = v_loc_id;
  end if;
  if v_loc_lat is not null and p_lat is not null then
    v_distance := haversine_meters(p_lat, p_lng, v_loc_lat, v_loc_lng);
    v_within := v_distance <= 500;
  else
    v_distance := null;
    v_within := null;
  end if;

  if v_existing.id is null then
    insert into time_entries (shift_id, employee_id, company_id, work_date, clock_in, clock_in_lat, clock_in_lng, clock_in_distance_m, clock_in_within_range)
    values (p_shift_id, v_emp_id, v_shift.company_id, v_shift.shift_date, v_now, p_lat, p_lng, v_distance, v_within);
  else
    update time_entries set clock_in = v_now, clock_in_lat = p_lat, clock_in_lng = p_lng,
      clock_in_distance_m = v_distance, clock_in_within_range = v_within
      where id = v_existing.id;
  end if;

  update shifts set status = 'in_progress' where id = p_shift_id;
  return v_now;
end;
$$ language plpgsql security definer;

notify pgrst, 'reload schema';
notify pgrst, 'reload config';

-- =====================================================================
-- FIN. Sube también el nuevo index.html que te entrego junto con esto.
-- =====================================================================
