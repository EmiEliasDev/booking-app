-- Onboard a new clinic. LIVE: paste this whole file into Supabase SQL Editor and Run.
-- IMPORTANT: click inside the editor and select NOTHING before clicking Run. If any text is highlighted,
-- the SQL Editor runs only that selection, and a partial run can skip steps or the post-check.
-- Before running: Dashboard > Authentication > Add user (auto-confirm) for the admin email
-- (and for any front desk email). This script only READS auth.users; it never creates users.
-- What it does, in ONE statement (all or nothing): validates the parameters, creates the clinic,
-- links the admin (and front desk) by email, adds login-less therapists (0760) and their weekly hours.
-- It fails loudly, changing nothing, on: bad parameters, duplicate slug, an email that is not an
-- Auth user yet, an email that is already staff of any clinic, or more staff than the plan allows
-- (basico 3, clinica 6: admin + front desk + therapists, all active).
-- One clinic per person is intentional (confirmed by Emiliano, Oct 19): an Auth user/email can be staff
-- at only one clinic, so the script refuses an email that is already staff anywhere, in any clinic.
-- The last result is the post-check: copy CLINIC_ID into the clinic deploy repo (Actions variable).
-- Every row in the "ok" column must be true. Rollback for a fresh clinic: supabase/scripts/offboard_clinic.sql
-- Test: supabase/tests/onboard_clinic_test.sql runs this exact file (the example values below are its fixture).

-- ==================== 1. PARAMETERS: edit only this block ====================
-- slug: lowercase letters/digits/hyphens (unique)    plan: basico | clinica    slot_minutes: 10..240
-- timezone: IANA name (default America/Tijuana)      front_desk: [] or [{"email": ..., "display_name": ...}]
-- therapists: login-less, bookable; order = order on the booking page. Optional per therapist:
--   "hours": [{"weekday": 1, "start": "09:00", "end": "14:00"}, ...]   (weekday 0 = Sunday ... 6 = Saturday)
-- default_hours: used for therapists without "hours" (default Mon-Sat 08:00-20:00)
select set_config('onboard.params', $params$
{
  "slug": "tu-clinica",
  "name": "Tu Clínica",
  "plan": "basico",
  "slot_minutes": 60,
  "timezone": "America/Tijuana",
  "admin_email": "admin@tuclinica.example",
  "admin_display_name": "Administración",
  "front_desk": [],
  "therapists": [
    {"display_name": "Terapeuta Uno"},
    {"display_name": "Terapeuta Dos"}
  ],
  "default_hours": {"weekdays": [1, 2, 3, 4, 5, 6], "start": "08:00", "end": "20:00"}
}
$params$, false);

-- ==================== 2. LOGIC: do not edit below ====================
-- Session-only helper functions (pg_temp): gone when the SQL Editor session ends.
create or replace function pg_temp.onboard_clinic(p jsonb) returns uuid
language plpgsql set search_path = '' as $fn$
declare
  v_slug  text := btrim(p->>'slug');
  v_name  text := btrim(p->>'name');
  v_plan  text := coalesce(btrim(p->>'plan'), 'basico');
  v_slot  text := btrim(p->>'slot_minutes');
  v_tz    text := coalesce(nullif(btrim(p->>'timezone'), ''), 'America/Tijuana');
  v_email text := lower(btrim(p->>'admin_email'));
  v_aname text := coalesce(nullif(btrim(p->>'admin_display_name'), ''), 'Administración');
  v_desk  jsonb := coalesce(p->'front_desk', '[]'::jsonb);
  v_ther  jsonb := coalesce(p->'therapists', '[]'::jsonb);
  v_def   jsonb := coalesce(p->'default_hours', '{"weekdays":[1,2,3,4,5,6],"start":"08:00","end":"20:00"}'::jsonb);
  v_len int; v_admin uuid; v_clinic uuid; v_limit int; v_total int; v_uid uuid; v_staff uuid;
  r jsonb; h jsonb; v_hours jsonb; v_dn text; v_de text; i int := 0;
  v_users uuid[] := '{}'; v_names text[] := '{}';
begin
  -- ---- parameters ----
  if v_slug is null or v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'onboard: slug "%" must be lowercase letters/digits/hyphens', v_slug using errcode = '22023';
  end if;
  if v_name is null or length(v_name) not between 1 and 120 then
    raise exception 'onboard: name is required (1-120 chars)' using errcode = '22023';
  end if;
  if v_plan not in ('basico', 'clinica') then
    raise exception 'onboard: plan "%" must be basico or clinica', v_plan using errcode = '22023';
  end if;
  if (case when v_slot is null or v_slot !~ '^[0-9]{1,3}$' then true else v_slot::int not between 10 and 240 end) then
    raise exception 'onboard: slot_minutes "%" must be 10..240', v_slot using errcode = '22023';
  end if;
  v_len := v_slot::int;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = v_tz) then
    raise exception 'onboard: unknown timezone "%"', v_tz using errcode = '22023';
  end if;
  if v_email is null or v_email = '' then
    raise exception 'onboard: admin_email is required' using errcode = '22023';
  end if;
  if jsonb_typeof(v_desk) <> 'array' or jsonb_typeof(v_ther) <> 'array' then
    raise exception 'onboard: front_desk and therapists must be JSON arrays' using errcode = '22023';
  end if;
  if jsonb_array_length(v_ther) = 0 then
    raise exception 'onboard: add at least one therapist (the booking page needs one)' using errcode = '22023';
  end if;
  -- validate every hours list (default + overrides): weekday 0..6, HH:MM, end - start >= one session
  if jsonb_typeof(v_def->'weekdays') <> 'array' or jsonb_array_length(v_def->'weekdays') = 0 then
    raise exception 'onboard: default_hours.weekdays must be a non-empty array (0 = Sunday ... 6 = Saturday)' using errcode = '22023';
  end if;
  for r in select x from jsonb_array_elements(v_ther) x loop
    if jsonb_typeof(r->'hours') is not null and (jsonb_typeof(r->'hours') <> 'array' or jsonb_array_length(r->'hours') = 0) then
      raise exception 'onboard: "hours" of % must be a non-empty array (or left out for default_hours)', r->>'display_name' using errcode = '22023';
    end if;
  end loop;
  for h in select jsonb_build_object('weekday', w, 'start', v_def->>'start', 'end', v_def->>'end')
             from jsonb_array_elements_text(v_def->'weekdays') w
           union all
           select e from jsonb_array_elements(v_ther) t,
                  jsonb_array_elements(case when jsonb_typeof(t->'hours') = 'array' then t->'hours' else '[]'::jsonb end) e loop
    if (case when coalesce(h->>'weekday', '') !~ '^[0-6]$' then true
            when coalesce(h->>'start', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then true
            when coalesce(h->>'end', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then true
            else (h->>'end')::time - (h->>'start')::time < make_interval(mins => v_len) end) then
      raise exception 'onboard: bad hours % (weekday 0-6, start/end HH:MM, end - start >= slot_minutes %)', h, v_len using errcode = '22023';
    end if;
  end loop;
  for r in select x from jsonb_array_elements(v_ther) x loop
    v_dn := btrim(r->>'display_name');
    if v_dn is null or length(v_dn) not between 1 and 80 then
      raise exception 'onboard: every therapist needs a display_name (1-80 chars): %', r using errcode = '22023';
    end if;
    if lower(v_dn) = any (v_names) then
      raise exception 'onboard: therapist "%" is listed twice', v_dn using errcode = '22023';
    end if;
    v_names := v_names || lower(v_dn);
  end loop;

  -- ---- conflicts ----
  if exists (select 1 from public.clinics where slug = v_slug) then
    raise exception 'onboard: a clinic with slug "%" already exists. Nothing was changed.', v_slug using errcode = '23505';
  end if;
  select u.id into v_admin from auth.users u where lower(u.email) = v_email;
  if v_admin is null then
    raise exception 'onboard: no Auth user with email %. Nothing was changed.', v_email using errcode = 'P0002',
      hint = 'Create it first: Dashboard > Authentication > Add user (auto-confirm), then run this again.';
  end if;
  if exists (select 1 from public.staff where user_id = v_admin) then
    raise exception 'onboard: % is already staff of a clinic. Nothing was changed.', v_email using errcode = '23505';
  end if;
  v_users := array[v_admin];
  for r in select x from jsonb_array_elements(v_desk) x loop
    v_de := lower(btrim(r->>'email'));
    select u.id into v_uid from auth.users u where lower(u.email) = v_de;
    if v_uid is null then
      raise exception 'onboard: no Auth user with front desk email %. Nothing was changed.', v_de using errcode = 'P0002',
        hint = 'Create it first: Dashboard > Authentication > Add user (auto-confirm).';
    end if;
    if v_uid = any (v_users) then
      raise exception 'onboard: email % is listed twice. Nothing was changed.', v_de using errcode = '22023';
    end if;
    if exists (select 1 from public.staff where user_id = v_uid) then
      raise exception 'onboard: % is already staff of a clinic. Nothing was changed.', v_de using errcode = '23505';
    end if;
    v_users := v_users || v_uid;
  end loop;

  -- ---- clinic + cap (same limit function the staff_limit trigger uses) ----
  insert into public.clinics (slug, name, plan, slot_minutes, timezone)
  values (v_slug, v_name, v_plan, v_len, v_tz) returning id into v_clinic;
  v_limit := public.clinic_staff_limit(v_clinic);
  v_total := 1 + jsonb_array_length(v_desk) + jsonb_array_length(v_ther);
  if v_total > v_limit then
    raise exception 'onboard: % active staff (1 admin + % front desk + % therapists) exceeds the % plan limit of %. Nothing was changed.',
      v_total, jsonb_array_length(v_desk), jsonb_array_length(v_ther), v_plan, v_limit using errcode = '23514';
  end if;

  -- ---- staff ----
  insert into public.staff (user_id, clinic_id, role, display_name, active, sort_order)
  values (v_admin, v_clinic, 'admin', v_aname, true, 0);
  for r in select x from jsonb_array_elements(v_desk) x loop
    select u.id into v_uid from auth.users u where lower(u.email) = lower(btrim(r->>'email'));
    insert into public.staff (user_id, clinic_id, role, display_name, active, sort_order)
    values (v_uid, v_clinic, 'front_desk', coalesce(nullif(btrim(r->>'display_name'), ''), 'Recepción'), true, 0);
  end loop;
  for r in select x from jsonb_array_elements(v_ther) x loop
    i := i + 1;
    insert into public.staff (clinic_id, role, display_name, active, sort_order)   -- user_id = generated id, no login
    values (v_clinic, 'therapist', btrim(r->>'display_name'), true, i)
    returning user_id into v_staff;
    v_hours := case when jsonb_typeof(r->'hours') = 'array' then r->'hours'
                    else (select jsonb_agg(jsonb_build_object('weekday', w, 'start', v_def->>'start', 'end', v_def->>'end'))
                            from jsonb_array_elements_text(v_def->'weekdays') w) end;
    insert into public.staff_hours (clinic_id, staff_id, weekday, start_time, end_time)
    select v_clinic, v_staff, (e->>'weekday')::smallint, (e->>'start')::time, (e->>'end')::time
    from jsonb_array_elements(coalesce(v_hours, '[]'::jsonb)) e;
  end loop;

  raise notice 'onboard: created "%" (%), CLINIC_ID = %', v_name, v_slug, v_clinic;
  return v_clinic;
end $fn$;

create or replace function pg_temp.onboard_report(p_slug text)
returns table (n int, section text, item text, value text, ok boolean)
language sql set search_path = '' as $fn$
  with c as (select * from public.clinics where slug = p_slug),
  s as (
    select st.user_id, st.role, st.active, st.display_name, st.sort_order, u.email,
           (select count(*) from public.staff_hours h where h.clinic_id = st.clinic_id and h.staff_id = st.user_id) as hours
    from public.staff st join c on st.clinic_id = c.id left join auth.users u on u.id = st.user_id)
  select 0, 'clinic', 'NOT FOUND', p_slug, false where not exists (select 1 from c)
  union all select 1, 'clinic', 'CLINIC_ID', c.id::text, true from c
  union all select 2, 'clinic', 'slug / name / plan / slot_minutes / timezone',
                   concat_ws(' / ', c.slug, c.name, c.plan, c.slot_minutes, c.timezone), true from c
  union all select 10 + row_number() over (order by s.sort_order, s.role, s.display_name)::int, 'staff', s.display_name,
                   concat_ws(', ', s.role, case when s.active then 'active' else 'inactive' end,
                             coalesce(s.email, 'no login'), s.hours || ' hour rows'),
                   s.active and (s.role <> 'therapist' or s.hours > 0) and (s.role = 'therapist' or s.email is not null)
            from s
  union all select 100, 'check', 'active staff / plan limit',
                   (select count(*) from s where s.active) || ' / ' || public.clinic_staff_limit(c.id),
                   (select count(*) from s where s.active) <= public.clinic_staff_limit(c.id)
                     and exists (select 1 from s where s.role = 'admin' and s.active) from c
  union all select 101, 'check', 'therapists on the booking page (list_therapists)',
                   (select count(*) from public.list_therapists(c.id))::text,
                   (select count(*) from public.list_therapists(c.id)) = (select count(*) from s where s.role = 'therapist' and s.active)
                     and (select count(*) from s where s.role = 'therapist' and s.active) > 0 from c
  union all select 102, 'check', 'appointments / time off rows (new clinic: 0)',
                   (select count(*) from public.appointments a where a.clinic_id = c.id) || ' / ' ||
                   (select count(*) from public.staff_time_off o where o.clinic_id = c.id),
                   not exists (select 1 from public.appointments a where a.clinic_id = c.id)
                     and not exists (select 1 from public.staff_time_off o where o.clinic_id = c.id) from c
  union all select 103, 'check', 'hours rows in this clinic not belonging to its staff',
                   (select count(*) from public.staff_hours h where h.clinic_id = c.id
                      and h.staff_id not in (select s.user_id from s))::text,
                   not exists (select 1 from public.staff_hours h where h.clinic_id = c.id
                      and h.staff_id not in (select s.user_id from s)) from c
  union all select 104, 'check', 'this clinic''s staff ids used in other clinics (staff, hours, time off)',
                   ((select count(*) from public.staff x where x.user_id in (select s.user_id from s) and x.clinic_id <> c.id)
                  + (select count(*) from public.staff_hours x where x.staff_id in (select s.user_id from s) and x.clinic_id <> c.id)
                  + (select count(*) from public.staff_time_off x where x.staff_id in (select s.user_id from s) and x.clinic_id <> c.id))::text,
                   not exists (select 1 from public.staff x where x.user_id in (select s.user_id from s) and x.clinic_id <> c.id)
                     and not exists (select 1 from public.staff_hours x where x.staff_id in (select s.user_id from s) and x.clinic_id <> c.id)
                     and not exists (select 1 from public.staff_time_off x where x.staff_id in (select s.user_id from s) and x.clinic_id <> c.id) from c
$fn$;

-- ==================== 3. RUN + POST-CHECK (last result shown in the SQL Editor) ====================
select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb) as clinic_id;
select section, item, value, ok
from pg_temp.onboard_report(current_setting('onboard.params')::jsonb->>'slug')
order by n;
