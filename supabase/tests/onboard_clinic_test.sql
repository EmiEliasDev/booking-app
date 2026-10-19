-- Onboarding / offboarding scripts (supabase/scripts/onboard_clinic.sql, offboard_clinic.sql).
-- Runs the ACTUAL script files with psql \ir (path relative to this file), so their example
-- parameters ("Tu Clínica", basico, admin@tuclinica.example, 2 login-less therapists) are the happy-path
-- fixture; the session helpers they define (pg_temp.onboard_clinic / offboard_clinic and the *_report
-- functions) are then called with edited parameters for the failure cases. Fake data only. pgTAP, rolls back.
-- Locally: psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/onboard_clinic_test.sql
-- Note: needs psql \ir access to ../scripts (the d3harness run.sh does this). `supabase test db` only
-- ships supabase/tests to its runner, so this file is meant for the harness / psql.
begin;
select plan(54);

-- ============ fixtures (service role) ============
-- Auth users exist before onboarding (Dashboard > Authentication > Add user on live).
insert into auth.users (id, email) values
  ('f6000000-0000-4000-8000-000000000001','admin@tuclinica.example'),
  ('f6000000-0000-4000-8000-000000000002','Admin2@TuClinica.example'),
  ('f6000000-0000-4000-8000-000000000003','desk2@tuclinica.example'),
  ('f7000000-0000-4000-8000-000000000001','admin@otra.example');
-- an unrelated existing clinic that must stay untouched
insert into public.clinics (id, slug, name, plan) values ('f7000000-0000-4000-8000-00000000000c','otra','Otra','clinica');
insert into public.staff (user_id, clinic_id, role, display_name) values
  ('f7000000-0000-4000-8000-000000000001','f7000000-0000-4000-8000-00000000000c','admin','Admin Otra'),
  ('f7000000-0000-4000-8000-000000000002','f7000000-0000-4000-8000-00000000000c','therapist','Terapeuta Otra');
insert into public.staff_hours (clinic_id, staff_id, weekday, start_time, end_time) values
  ('f7000000-0000-4000-8000-00000000000c','f7000000-0000-4000-8000-000000000002',1,'09:00','13:00');
insert into public.staff_time_off (clinic_id, staff_id, start_date, end_date, reason) values
  ('f7000000-0000-4000-8000-00000000000c','f7000000-0000-4000-8000-000000000002',current_date+20,current_date+20,'motivo otra');

-- ============ [O] onboard Tu Clínica: the script file as shipped ============
\ir ../scripts/onboard_clinic.sql
select set_config('t.c', (select id::text from public.clinics where slug = 'tu-clinica'), true);

select results_eq($$select name, plan, slot_minutes, timezone from public.clinics where slug = 'tu-clinica'$$,
  $$values ('Tu Clínica'::text, 'basico'::text, 60, 'America/Tijuana'::text)$$, 'O1 clinic row created from the params block');
select results_eq(format($$select user_id, role, display_name, active from public.staff where clinic_id = %L and role <> 'therapist'$$, current_setting('t.c')),
  $$values ('f6000000-0000-4000-8000-000000000001'::uuid, 'admin'::text, 'Administración'::text, true)$$, 'O2 admin linked to the existing Auth user by email');
select results_eq(format($$select display_name, sort_order::int, active from public.staff where clinic_id = %L and role = 'therapist' order by sort_order$$, current_setting('t.c')),
  $$values ('Terapeuta Uno'::text, 1, true), ('Terapeuta Dos', 2, true)$$, 'O3 two active therapists in list order');
select is((select count(*)::int from public.staff s join auth.users u on u.id = s.user_id where s.clinic_id = current_setting('t.c')::uuid and s.role = 'therapist'), 0,
  'O4 therapists are login-less (0760: generated user_id, no auth.users row)');
select is((select count(*)::int from auth.users), 4, 'O5 script never inserts into auth.users');
select results_eq(format($$select s.display_name, count(*)::int, min(h.weekday)::int, max(h.weekday)::int, min(h.start_time), max(h.end_time)
    from public.staff s join public.staff_hours h on h.staff_id = s.user_id and h.clinic_id = s.clinic_id
   where s.clinic_id = %L group by s.display_name, s.sort_order order by s.sort_order$$, current_setting('t.c')),
  $$values ('Terapeuta Uno'::text, 6, 1, 6, '08:00'::time, '20:00'::time), ('Terapeuta Dos', 6, 1, 6, '08:00'::time, '20:00'::time)$$,
  'O6 default hours Mon-Sat 08:00-20:00 per therapist');
select is((select count(*)::int from public.staff_hours h join public.staff s on s.user_id = h.staff_id and s.clinic_id = h.clinic_id
            where h.clinic_id = current_setting('t.c')::uuid and s.role <> 'therapist'), 0, 'O7 no hours for the admin');
select is((select count(*)::int from public.staff where clinic_id = current_setting('t.c')::uuid and active), 3, 'O8 3 active = basico limit, accepted');
select ok((select bool_and(ok) from pg_temp.onboard_report('tu-clinica')), 'O9 post-check: every ok is true');
select is((select value from pg_temp.onboard_report('tu-clinica') where item = 'CLINIC_ID'), current_setting('t.c'), 'O10 post-check shows CLINIC_ID');
select is((select count(*)::int from pg_temp.onboard_report('tu-clinica') where section = 'staff'), 3, 'O11 post-check lists the 3 staff');
select ok(not (select bool_and(ok) from pg_temp.onboard_report('no-existe')), 'O12 post-check for an unknown slug is not ok');
select results_eq(format($$select count(*)::int from public.clinics where id <> %L$$, current_setting('t.c')), array[1], 'O13 only one other clinic exists (untouched)');
select results_eq($$select (select count(*) from public.staff where clinic_id = 'f7000000-0000-4000-8000-00000000000c')::int,
                          (select count(*) from public.staff_hours where clinic_id = 'f7000000-0000-4000-8000-00000000000c')::int,
                          (select count(*) from public.staff_time_off where clinic_id = 'f7000000-0000-4000-8000-00000000000c')::int$$,
  $$values (2, 1, 1)$$, 'O14 other clinic rows unchanged');
set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true);
select results_eq(format($$select display_name from public.list_therapists(%L)$$, current_setting('t.c')), array['Terapeuta Uno','Terapeuta Dos'],
  'O15 booking page lists both therapists in order');
select isnt_empty(format($$select 1 from public.get_available_slots(%1$L, (select id from public.list_therapists(%1$L) limit 1), current_date + 1, current_date + 8)$$, current_setting('t.c')),
  'O16 first therapist has bookable slots');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"f6000000-0000-4000-8000-000000000001"}',true);
select results_eq($$select slug from public.clinics$$, array['tu-clinica'], 'O17 new admin sees only the new clinic');
select is((select count(*)::int from public.staff), 3, 'O18 new admin sees only its 3 staff');
select is_empty($$select 1 from public.staff_hours where clinic_id = 'f7000000-0000-4000-8000-00000000000c'
                  union all select 1 from public.staff_time_off where clinic_id = 'f7000000-0000-4000-8000-00000000000c'$$, 'O19 new admin sees no other clinic hours/time off');
reset role;

-- ============ [E] failures: nothing changes ============
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb)$$, '23505', null, 'E1 same params again: duplicate slug rejected');
select throws_like($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb)$$, '%slug "tu-clinica" already exists%', 'E2 duplicate slug message is clear');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"tu-clinica-2"}')$$, '23505', null, 'E3 admin email already staff (this clinic) rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"tu-clinica-2","admin_email":"admin@otra.example"}')$$, '23505', null, 'E4 email already staff of another clinic rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"tu-clinica-2","admin_email":"nadie@tuclinica.example"}')$$, 'P0002', null, 'E5 admin email not in auth.users rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb - 'admin_email' || '{"slug":"tu-clinica-2"}')$$, '22023', null, 'E6 missing admin_email rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"cap-basico","admin_email":"admin2@tuclinica.example","therapists":[{"display_name":"T1"},{"display_name":"T2"},{"display_name":"T3"}]}')$$,
  '23514', null, 'E7 basico: admin + 3 therapists (4) over the cap rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"cap-basico","admin_email":"admin2@tuclinica.example","front_desk":[{"email":"desk2@tuclinica.example"}]}')$$,
  '23514', null, 'E8 basico: admin + front desk + 2 therapists (4) rejected: front desk counts');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"cap-clinica","plan":"clinica","admin_email":"admin2@tuclinica.example","front_desk":[{"email":"desk2@tuclinica.example"}],"therapists":[{"display_name":"T1"},{"display_name":"T2"},{"display_name":"T3"},{"display_name":"T4"},{"display_name":"T5"}]}')$$,
  '23514', null, 'E9 clinica: 7 active rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"x-1","admin_email":"admin2@tuclinica.example","plan":"premium"}')$$, '22023', null, 'E10 unknown plan rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"x-1","admin_email":"admin2@tuclinica.example","slot_minutes":5}')$$, '22023', null, 'E11 slot_minutes below 10 rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"x-1","admin_email":"admin2@tuclinica.example","slot_minutes":"45m"}')$$, '22023', null, 'E12 non-numeric slot_minutes rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"Tu Clinica","admin_email":"admin2@tuclinica.example"}')$$, '22023', null, 'E13 bad slug format rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"x-1","admin_email":"admin2@tuclinica.example","therapists":[{"display_name":"Ana"},{"display_name":"ana "}]}')$$, '22023', null, 'E14 duplicate therapist name rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"x-1","admin_email":"admin2@tuclinica.example","therapists":[{"display_name":"  "}]}')$$, '22023', null, 'E15 blank therapist name rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"x-1","admin_email":"admin2@tuclinica.example","slot_minutes":90,"default_hours":{"weekdays":[1],"start":"08:00","end":"09:00"}}')$$, '22023', null, 'E16 hours shorter than one session rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"x-1","admin_email":"admin2@tuclinica.example","therapists":[{"display_name":"Ana","hours":[{"weekday":7,"start":"08:00","end":"12:00"}]}]}')$$, '22023', null, 'E17 weekday 7 rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"x-1","admin_email":"admin2@tuclinica.example","therapists":[]}')$$, '22023', null, 'E18 no therapists rejected');
select throws_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"x-1","admin_email":"admin2@tuclinica.example","timezone":"Mars/Base"}')$$, '22023', null, 'E19 unknown timezone rejected');
select is((select count(*)::int from public.clinics), 2, 'E20 failed runs left no clinic behind');
select is((select count(*)::int from public.staff where user_id in ('f6000000-0000-4000-8000-000000000002','f6000000-0000-4000-8000-000000000003')), 0, 'E21 failed runs left no staff behind');

-- ============ [K] clinica at exactly 6, with front desk and per-therapist hours ============
select lives_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb || '{"slug":"clinica-seis","name":"Clínica Seis","plan":"clinica","slot_minutes":45,
  "admin_email":"ADMIN2@tuclinica.example","front_desk":[{"email":"desk2@tuclinica.example","display_name":"Recepción Seis"}],
  "therapists":[{"display_name":"T1","hours":[{"weekday":1,"start":"09:00","end":"14:00"},{"weekday":3,"start":"15:00","end":"19:00"}]},{"display_name":"T2"},{"display_name":"T3"},{"display_name":"T4"}]}')$$,
  'K1 clinica: admin + front desk + 4 therapists (6) accepted; email match is case-insensitive');
select results_eq($$select s.role, count(*)::int from public.staff s join public.clinics c on c.id = s.clinic_id where c.slug = 'clinica-seis' and s.active group by s.role order by 1$$,
  $$values ('admin'::text, 1), ('front_desk', 1), ('therapist', 4)$$, 'K2 roles as given');
select results_eq($$select h.weekday::int, h.start_time, h.end_time from public.staff_hours h join public.staff s on s.user_id = h.staff_id and s.clinic_id = h.clinic_id
   join public.clinics c on c.id = s.clinic_id where c.slug = 'clinica-seis' and s.display_name = 'T1' order by 1$$,
  $$values (1, '09:00'::time, '14:00'::time), (3, '15:00'::time, '19:00'::time)$$, 'K3 per-therapist hours override the default');
select ok((select bool_and(ok) from pg_temp.onboard_report('clinica-seis')), 'K4 post-check all ok for clinica-seis');

-- ============ [X] offboard Tu Clínica: the script file as shipped ============
\ir ../scripts/offboard_clinic.sql
select results_eq(format($$select (select count(*) from public.clinics where id = %1$L)::int, (select count(*) from public.staff where clinic_id = %1$L)::int,
                                  (select count(*) from public.staff_hours where clinic_id = %1$L)::int, (select count(*) from public.staff_time_off where clinic_id = %1$L)::int$$, current_setting('t.c')),
  $$values (0, 0, 0, 0)$$, 'X1 Tu Clínica fully removed (clinic, staff, hours, time off)');
select ok((select bool_and(ok) from pg_temp.offboard_report(current_setting('t.c')::uuid, 'tu-clinica', current_setting('offboard.auth_users'))), 'X2 offboard post-check: every ok is true');
select is((select count(*)::int from auth.users where id = 'f6000000-0000-4000-8000-000000000001'), 1, 'X3 admin Auth user kept');
select results_eq($$select (select count(*) from public.staff where clinic_id = 'f7000000-0000-4000-8000-00000000000c')::int,
                          (select count(*) from public.staff_hours where clinic_id = 'f7000000-0000-4000-8000-00000000000c')::int,
                          (select count(*) from public.staff_time_off where clinic_id = 'f7000000-0000-4000-8000-00000000000c')::int,
                          (select count(*) from public.staff where clinic_id = (select id from public.clinics where slug = 'clinica-seis'))::int$$,
  $$values (2, 1, 1, 6)$$, 'X4 other clinics untouched');
-- clinica-seis gets a booking -> offboard must refuse
select lives_ok($$select public.request_appointment(c.id, (select id from public.list_therapists(c.id) where display_name = 'T2'),
    (select min(slot_date) from public.get_available_slots(c.id, (select id from public.list_therapists(c.id) where display_name = 'T2'), current_date + 1, current_date + 8)),
    (select min(slot_time) from public.get_available_slots(c.id, (select id from public.list_therapists(c.id) where display_name = 'T2'), current_date + 1, current_date + 8)
       where slot_date = (select min(slot_date) from public.get_available_slots(c.id, (select id from public.list_therapists(c.id) where display_name = 'T2'), current_date + 1, current_date + 8))),
    'Paciente Prueba', 'paciente@ejemplo.com', '', 'initial') from public.clinics c where c.slug = 'clinica-seis'$$, 'X5 guest books at clinica-seis');
select throws_ok($$select pg_temp.offboard_clinic('{"slug":"clinica-seis"}')$$, '55000', null, 'X6 offboard refuses a clinic with appointments');
select is((select count(*)::int from public.staff s join public.clinics c on c.id = s.clinic_id where c.slug = 'clinica-seis'), 6, 'X7 refused offboard changed nothing');
select throws_ok($$select pg_temp.offboard_clinic('{"slug":"no-existe"}')$$, 'P0002', null, 'X8 offboard of an unknown slug rejected');
select throws_ok($$select pg_temp.offboard_clinic('{"slug":"otra","clinic_id":"00000000-0000-4000-8000-000000000000"}')$$, '22023', null, 'X9 offboard refuses when clinic_id does not match the slug');
select lives_ok($$select pg_temp.onboard_clinic(current_setting('onboard.params')::jsonb)$$, 'X10 after offboarding, onboarding Tu Clínica again works (slug and admin free)');

select * from finish();
rollback;
