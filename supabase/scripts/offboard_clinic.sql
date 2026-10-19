-- Offboard (roll back) a FRESHLY onboarded clinic. DESTRUCTIVE. LIVE: paste this whole file into
-- Supabase SQL Editor and Run.
-- IMPORTANT: click inside the editor and select NOTHING before clicking Run. If any text is highlighted,
-- the SQL Editor runs only that selection, and a partial run can skip steps or the post-check.
-- Flow: run onboard_clinic.sql -> copy CLINIC_ID from its post-check -> paste it below as clinic_id
-- (and the same slug) -> Run. clinic_id is REQUIRED and must belong to the slug; otherwise it refuses
-- with SQLSTATE 22023 and deletes nothing. As shipped, clinic_id is a placeholder, so running this file
-- unedited always refuses.
-- Deletes only that clinic's rows, in FK-safe order: staff_time_off, staff_hours, staff, clinics.
-- Refuses, changing nothing, if the clinic has ANY appointment (any status): bookings are never deleted here.
-- Never touches auth.users: remove Auth users by hand in Dashboard > Authentication if wanted.
-- One statement (all or nothing); its result is the post-check: every "ok" must be true.
-- Test: supabase/tests/onboard_clinic_test.sql runs this exact file unedited (must refuse), then calls the
-- function it defines with the onboarded clinic's real CLINIC_ID (the same edit a person makes).

-- ==================== 1. PARAMETERS: edit only this block ====================
-- slug: the clinic to remove.   clinic_id: CLINIC_ID from the onboarding post-check (required).
select set_config('offboard.params', $params$
{
  "slug": "tu-clinica",
  "clinic_id": "PASTE-CLINIC_ID-FROM-ONBOARD-POST-CHECK"
}
$params$, false);

-- ==================== 2. LOGIC: do not edit below ====================
create or replace function pg_temp.offboard_report(p_clinic uuid, p_slug text, p_users text)
returns table (n int, item text, value text, ok boolean)
language sql set search_path = '' as $fn$
  select 1, 'clinic row (by id / by slug)',
         (select count(*) from public.clinics where id = p_clinic) || ' / ' || (select count(*) from public.clinics where slug = p_slug),
         not exists (select 1 from public.clinics where id = p_clinic or slug = p_slug)
  union all select 2, 'staff rows', (select count(*) from public.staff where clinic_id = p_clinic)::text,
         not exists (select 1 from public.staff where clinic_id = p_clinic)
  union all select 3, 'staff_hours rows', (select count(*) from public.staff_hours where clinic_id = p_clinic)::text,
         not exists (select 1 from public.staff_hours where clinic_id = p_clinic)
  union all select 4, 'staff_time_off rows', (select count(*) from public.staff_time_off where clinic_id = p_clinic)::text,
         not exists (select 1 from public.staff_time_off where clinic_id = p_clinic)
  union all select 5, 'appointments', (select count(*) from public.appointments where clinic_id = p_clinic)::text,
         not exists (select 1 from public.appointments where clinic_id = p_clinic)
  union all select 6, 'former staff Auth users kept (not deleted)',
         (select count(*) from auth.users u where u.id::text = any (string_to_array(nullif(p_users, ''), ','))) || ' of ' ||
         coalesce(array_length(string_to_array(nullif(p_users, ''), ','), 1), 0),
         (select count(*) from auth.users u where u.id::text = any (string_to_array(nullif(p_users, ''), ',')))
           = coalesce(array_length(string_to_array(nullif(p_users, ''), ','), 1), 0)
$fn$;

create or replace function pg_temp.offboard_clinic(p jsonb)
returns table (n int, item text, value text, ok boolean)
language plpgsql set search_path = '' as $fn$
declare
  v_slug text := nullif(btrim(p->>'slug'), '');
  v_want text := nullif(btrim(p->>'clinic_id'), '');
  v_clinic uuid; v_name text; v_appts bigint; v_users text; n1 int; n2 int; n3 int;
begin
  if v_want is null then
    raise exception 'offboard: clinic_id is required (CLINIC_ID from the onboarding post-check). Nothing was changed.'
      using errcode = '22023';
  end if;
  if v_want !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'offboard: clinic_id "%" is not a uuid (paste CLINIC_ID from the onboarding post-check). Nothing was changed.', v_want
      using errcode = '22023';
  end if;
  if v_slug is null then
    raise exception 'offboard: slug is required. Nothing was changed.' using errcode = '22023';
  end if;
  select c.id, c.name into v_clinic, v_name from public.clinics c where c.slug = v_slug;
  if v_clinic is null then
    raise exception 'offboard: no clinic with slug "%". Nothing was changed.', v_slug using errcode = 'P0002';
  end if;
  if v_clinic <> v_want::uuid then
    raise exception 'offboard: slug "%" is clinic %, not %. Nothing was changed.', v_slug, v_clinic, v_want using errcode = '22023';
  end if;
  perform 1 from public.clinics c where c.id = v_clinic for update;
  select count(*) into v_appts from public.appointments a where a.clinic_id = v_clinic;
  if v_appts > 0 then
    raise exception 'offboard: "%" has % appointment(s); refusing to delete a clinic in use. Nothing was changed.', v_name, v_appts
      using errcode = '55000';
  end if;
  select string_agg(s.user_id::text, ',') into v_users
  from public.staff s join auth.users u on u.id = s.user_id where s.clinic_id = v_clinic;
  delete from public.staff_time_off o where o.clinic_id = v_clinic; get diagnostics n1 = row_count;
  delete from public.staff_hours    h where h.clinic_id = v_clinic; get diagnostics n2 = row_count;
  delete from public.staff          s where s.clinic_id = v_clinic; get diagnostics n3 = row_count;
  delete from public.clinics        c where c.id = v_clinic;
  perform set_config('offboard.clinic_id', v_clinic::text, false);
  perform set_config('offboard.auth_users', coalesce(v_users, ''), false);
  raise notice 'offboard: removed "%" (%): % time off, % hours, % staff rows; auth.users untouched', v_name, v_clinic, n1, n2, n3;
  return query select r.n, r.item, r.value, r.ok from pg_temp.offboard_report(v_clinic, v_slug, coalesce(v_users, '')) r order by r.n;
end $fn$;

-- ==================== 3. RUN + POST-CHECK (one statement; its result is shown in the SQL Editor) ====================
select item, value, ok from pg_temp.offboard_clinic(current_setting('offboard.params')::jsonb);
