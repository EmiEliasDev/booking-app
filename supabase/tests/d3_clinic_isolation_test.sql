-- D3 clinic isolation: clinic A (basico) staff and anon against clinic B (clinica) on the D3 tables
-- (staff_hours, staff_time_off, staff with/without login, clinics.slot_minutes, per-therapist
-- appointments and the public booking RPCs), plus the active-staff cap with login-less staff (0760).
-- isolation_tiers_test.sql covers pre-D3 isolation and the 3/6 caps; this file fills the D3 gaps.
-- Fake data only. pgTAP, rolls back. Locally: psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/d3_clinic_isolation_test.sql
-- Sections: [A] A-admin  [F] A-front_desk  [T] A-therapist  [N] anon  [C] cap  [V] verification (service role)
-- Clinic A = a5000000-...-00c (basico, slot 30)   Clinic B = b5000000-...-00c (clinica, slot 45)
-- Login-less staff get user_id from the column default; their ids live in iso.a_nl / iso.b_nl.
begin;
select plan(134);


-- ============ fixtures (service role) ============
insert into auth.users (id, email) values
  ('a5000000-0000-4000-8000-000000000001','admin-isoa@test.local'),
  ('a5000000-0000-4000-8000-000000000002','desk-isoa@test.local'),
  ('a5000000-0000-4000-8000-000000000003','t-isoa@test.local'),
  ('a5000000-0000-4000-8000-000000000005','new-isoa@test.local'),
  ('b5000000-0000-4000-8000-000000000001','admin-isob@test.local'),
  ('b5000000-0000-4000-8000-000000000002','desk-isob@test.local'),
  ('b5000000-0000-4000-8000-000000000003','t-isob@test.local'),
  ('b5000000-0000-4000-8000-000000000004','off-isob@test.local'),
  ('b5000000-0000-4000-8000-000000000005','new1-isob@test.local'),
  ('b5000000-0000-4000-8000-000000000006','new2-isob@test.local');
insert into public.clinics (id, slug, name, plan, slot_minutes) values
  ('a5000000-0000-4000-8000-00000000000c','iso-a','Iso A','basico',30),
  ('b5000000-0000-4000-8000-00000000000c','iso-b','Iso B','clinica',45);
insert into public.staff (user_id, clinic_id, role, display_name, active) values
  ('a5000000-0000-4000-8000-000000000001','a5000000-0000-4000-8000-00000000000c','admin','Admin A',true),
  ('a5000000-0000-4000-8000-000000000002','a5000000-0000-4000-8000-00000000000c','front_desk','Recepción A',true),
  ('a5000000-0000-4000-8000-000000000003','a5000000-0000-4000-8000-00000000000c','therapist','Terapeuta A',true),
  ('b5000000-0000-4000-8000-000000000001','b5000000-0000-4000-8000-00000000000c','admin','Admin B',true),
  ('b5000000-0000-4000-8000-000000000002','b5000000-0000-4000-8000-00000000000c','front_desk','Recepción B',true),
  ('b5000000-0000-4000-8000-000000000003','b5000000-0000-4000-8000-00000000000c','therapist','Terapeuta B',true),
  ('b5000000-0000-4000-8000-000000000004','b5000000-0000-4000-8000-00000000000c','therapist','Inactiva B',false);
-- login-less therapists (0760): no user_id given, no auth.users row. A is basico and already has 3 active,
-- so A's login-less therapist starts inactive (used in [C]); B's is active.
insert into public.staff (clinic_id, role, display_name, active) values
  ('a5000000-0000-4000-8000-00000000000c','therapist','Sin cuenta A',false),
  ('b5000000-0000-4000-8000-00000000000c','therapist','Sin cuenta B',true);
select set_config('iso.a_nl', (select user_id::text from public.staff where display_name = 'Sin cuenta A'), true);
select set_config('iso.b_nl', (select user_id::text from public.staff where display_name = 'Sin cuenta B'), true);
insert into public.staff_hours (clinic_id, staff_id, weekday, start_time, end_time)
select c, s::uuid, d, '08:00', '12:00'
from (values ('a5000000-0000-4000-8000-00000000000c'::uuid,'a5000000-0000-4000-8000-000000000003'),
             ('b5000000-0000-4000-8000-00000000000c'::uuid,'b5000000-0000-4000-8000-000000000003'),
             ('b5000000-0000-4000-8000-00000000000c'::uuid,'b5000000-0000-4000-8000-000000000004'),
             ('b5000000-0000-4000-8000-00000000000c'::uuid,current_setting('iso.b_nl'))) v(c, s),
     generate_series(0, 6) d;
insert into public.staff_time_off (clinic_id, staff_id, start_date, end_date, reason) values
  ('a5000000-0000-4000-8000-00000000000c','a5000000-0000-4000-8000-000000000003',current_date+40,current_date+41,'motivo A privado'),
  ('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003',current_date+40,current_date+41,'motivo B privado'),
  ('b5000000-0000-4000-8000-00000000000c',current_setting('iso.b_nl')::uuid,current_date+50,current_date+50,'motivo B sin cuenta');
insert into public.appointments (id, clinic_id, staff_id, client_name, email, phone, service, notes, slot_date, slot_time, status, staff_note) values
  ('a5000000-0000-4000-8000-0000000000a1','a5000000-0000-4000-8000-00000000000c','a5000000-0000-4000-8000-000000000003','Paciente A1','pa1@x.com','6640000001','initial','Rodilla A',current_date+3,'09:00','pending',''),
  ('a5000000-0000-4000-8000-0000000000a2','a5000000-0000-4000-8000-00000000000c','a5000000-0000-4000-8000-000000000003','Paciente A2','pa2@x.com','6640000002','initial','Hombro A',current_date+4,'10:00','approved','nota A'),
  ('b5000000-0000-4000-8000-0000000000b1','b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003','Paciente B1','pb1@x.com','6860000001','initial','Dolor B',current_date+3,'09:00','pending',''),
  ('b5000000-0000-4000-8000-0000000000b2','b5000000-0000-4000-8000-00000000000c',current_setting('iso.b_nl')::uuid,'Paciente B2','pb2@x.com','6860000002','initial','Espalda B',current_date+5,'11:00','approved','nota B');

set local role authenticated;

-- ============ [A] admin of clinic A against clinic B ============
select set_config('request.jwt.claims','{"role":"authenticated","sub":"a5000000-0000-4000-8000-000000000001"}',true);
-- staff_hours / staff_time_off
select is_empty($$select 1 from public.staff_hours where clinic_id = 'b5000000-0000-4000-8000-00000000000c'$$, 'A1 A-admin reads no clinic B hours');
select is_empty($$select 1 from public.staff_time_off where clinic_id = 'b5000000-0000-4000-8000-00000000000c'$$, 'A2 A-admin reads no clinic B time off');
select is_empty($$select 1 from public.staff_time_off where reason like 'motivo B%'$$, 'A3 A-admin never sees a clinic B time-off reason');
select throws_ok($$insert into public.staff_hours (clinic_id, staff_id, weekday, start_time, end_time) values ('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003',1,'13:00','14:00')$$, '42501', null, 'A4 A-admin cannot insert hours with clinic B''s clinic_id');
select throws_ok($$insert into public.staff_time_off (clinic_id, staff_id, start_date, end_date, reason) values ('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003',current_date+60,current_date+60,'x')$$, '42501', null, 'A5 A-admin cannot insert time off with clinic B''s clinic_id');
select is_empty($$update public.staff_hours set end_time = '13:00' where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'A6 A-admin update of clinic B hours affects 0 rows');
select is_empty($$update public.staff_time_off set reason = 'x' where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'A7 A-admin update of clinic B time off affects 0 rows');
select is_empty($$delete from public.staff_hours where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'A8 A-admin delete of clinic B hours affects 0 rows');
select is_empty($$delete from public.staff_time_off where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'A9 A-admin delete of clinic B time off affects 0 rows');
select throws_ok($$update public.staff_hours set clinic_id = 'b5000000-0000-4000-8000-00000000000c' where clinic_id = 'a5000000-0000-4000-8000-00000000000c'$$, '42501', null, 'A10 A-admin cannot move own hours A -> B');
select throws_ok($$update public.staff_time_off set clinic_id = 'b5000000-0000-4000-8000-00000000000c' where clinic_id = 'a5000000-0000-4000-8000-00000000000c'$$, '42501', null, 'A11 A-admin cannot move own time off A -> B');
select throws_ok($$insert into public.staff_hours (clinic_id, staff_id, weekday, start_time, end_time) values ('a5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003',1,'13:00','14:00')$$, '23503', null, 'A12 A-admin cannot attach hours in clinic A to a clinic B therapist');
select throws_ok(format($$insert into public.staff_time_off (clinic_id, staff_id, start_date, end_date) values ('a5000000-0000-4000-8000-00000000000c',%L,current_date+60,current_date+60)$$, current_setting('iso.b_nl')), '23503', null, 'A13 A-admin cannot attach time off in clinic A to B''s login-less therapist');
-- clinics
select throws_ok($$update public.clinics set slot_minutes = 15 where id = 'b5000000-0000-4000-8000-00000000000c'$$, '42501', null, 'A14 A-admin cannot change clinic B slot_minutes');
select throws_ok($$update public.clinics set name = 'Hackeada' where id = 'b5000000-0000-4000-8000-00000000000c'$$, '42501', null, 'A15 A-admin cannot rename clinic B');
select is_empty($$select slot_minutes, plan, staff_limit, timezone from public.clinics where id = 'b5000000-0000-4000-8000-00000000000c'$$, 'A16 A-admin cannot read clinic B settings row');
select results_eq($$select id from public.clinics$$, array['a5000000-0000-4000-8000-00000000000c'::uuid], 'A17 A-admin reads only clinic A');
select ok(not public.is_staff_of('b5000000-0000-4000-8000-00000000000c') and not public.has_role('b5000000-0000-4000-8000-00000000000c', array['admin','front_desk','therapist']), 'A18 A-admin has no membership or role in clinic B');
select throws_ok($$select public.clinic_staff_limit('b5000000-0000-4000-8000-00000000000c')$$, '42501', null, 'A19 A-admin cannot read clinic B staff limit (migration 1100)');
-- staff
select is_empty($$select 1 from public.staff where clinic_id = 'b5000000-0000-4000-8000-00000000000c'$$, 'A20 A-admin sees no clinic B staff');
select is_empty(format($$select 1 from public.staff where user_id = %L$$, current_setting('iso.b_nl')), 'A21 A-admin does not see B''s login-less therapist');
select throws_ok($$insert into public.staff (clinic_id, role, display_name) values ('b5000000-0000-4000-8000-00000000000c','therapist','Intrusa')$$, '42501', null, 'A22 A-admin cannot add a login-less therapist to clinic B');
select throws_ok($$insert into public.staff (user_id, clinic_id, role, display_name, active) values ('a5000000-0000-4000-8000-000000000005','b5000000-0000-4000-8000-00000000000c','therapist','Intrusa',false)$$, '42501', null, 'A23 A-admin cannot add even an inactive member to clinic B');
select is_empty($$update public.staff set display_name = 'x' where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'A24 A-admin update of clinic B staff affects 0 rows');
select is_empty(format($$update public.staff set active = false where user_id = %L returning 1$$, current_setting('iso.b_nl')), 'A25 A-admin cannot deactivate B''s login-less therapist');
select is_empty($$update public.staff set active = false where user_id = 'b5000000-0000-4000-8000-000000000003' returning 1$$, 'A26 A-admin cannot deactivate B''s login therapist');
select is_empty($$delete from public.staff where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'A27 A-admin delete of clinic B staff affects 0 rows');
select throws_ok($$update public.staff set clinic_id = 'b5000000-0000-4000-8000-00000000000c' where user_id = 'a5000000-0000-4000-8000-000000000003'$$, '42501', null, 'A28 A-admin cannot move own therapist into clinic B');
select throws_ok(format($$update public.staff set clinic_id = 'b5000000-0000-4000-8000-00000000000c' where user_id = %L$$, current_setting('iso.a_nl')), '42501', null, 'A29 A-admin cannot move own login-less therapist into clinic B');
-- appointments
select is_empty($$select 1 from public.appointments where clinic_id = 'b5000000-0000-4000-8000-00000000000c'$$, 'A30 A-admin sees no clinic B appointments');
select throws_ok($$insert into public.appointments (clinic_id, staff_id, client_name, email, service, slot_date, slot_time) values ('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003','X','x@x.com','initial',current_date+7,'09:00')$$, '42501', null, 'A31 A-admin cannot insert an appointment with clinic B''s clinic_id');
select throws_ok($$insert into public.appointments (clinic_id, staff_id, client_name, email, service, slot_date, slot_time) values ('a5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003','X','x@x.com','initial',current_date+7,'09:00')$$, '42501', null, 'A32 A-admin cannot insert a clinic A appointment for a B therapist');
select throws_ok($$update public.appointments set staff_id = 'b5000000-0000-4000-8000-000000000003' where id = 'a5000000-0000-4000-8000-0000000000a1'$$, '42501', null, 'A33 A-admin cannot assign an A appointment to a B therapist');
select throws_ok($$update public.appointments set clinic_id = 'b5000000-0000-4000-8000-00000000000c' where id = 'a5000000-0000-4000-8000-0000000000a1'$$, '42501', null, 'A34 A-admin cannot move an A appointment to clinic B');
select is_empty($$update public.appointments set status = 'declined', staff_note = 'x' where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'A35 A-admin decision on clinic B appointments affects 0 rows');
select throws_ok($$select public.request_appointment('a5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003',current_date+7,'09:00','X','x@x.com')$$, 'P0001', 'inactive_staff', 'A36 booking RPC rejects clinic A + B therapist');
select throws_ok($$select public.request_appointment('b5000000-0000-4000-8000-00000000000c','a5000000-0000-4000-8000-000000000003',current_date+7,'09:00','X','x@x.com')$$, 'P0001', 'inactive_staff', 'A37 booking RPC rejects clinic B + A therapist');
select results_eq($$select display_name from public.list_therapists('b5000000-0000-4000-8000-00000000000c') order by 1$$, array['Sin cuenta B','Terapeuta B'], 'A38 A-admin gets the same public B therapist list as anon (no extra rows)');

-- ============ [F] front desk of clinic A against clinic B ============
select set_config('request.jwt.claims','{"role":"authenticated","sub":"a5000000-0000-4000-8000-000000000002"}',true);
select is_empty($$select 1 from public.staff_hours where clinic_id = 'b5000000-0000-4000-8000-00000000000c'$$, 'F1 A-front_desk reads no clinic B hours');
select is_empty($$select 1 from public.staff_time_off where clinic_id = 'b5000000-0000-4000-8000-00000000000c' or reason like 'motivo B%'$$, 'F2 A-front_desk reads no clinic B time off or reason');
select throws_ok($$insert into public.staff_hours (clinic_id, staff_id, weekday, start_time, end_time) values ('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003',1,'13:00','14:00')$$, '42501', null, 'F3 A-front_desk cannot insert clinic B hours');
select throws_ok(format($$insert into public.staff_time_off (clinic_id, staff_id, start_date, end_date) values ('b5000000-0000-4000-8000-00000000000c',%L,current_date+60,current_date+60)$$, current_setting('iso.b_nl')), '42501', null, 'F4 A-front_desk cannot insert clinic B time off');
select is_empty($$update public.staff_hours set end_time = '13:00' where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'F5 A-front_desk update of B hours affects 0 rows');
select is_empty($$update public.staff_time_off set reason = 'x' where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'F6 A-front_desk update of B time off affects 0 rows');
select is_empty($$delete from public.staff_hours where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'F7 A-front_desk delete of B hours affects 0 rows');
select is_empty($$delete from public.staff_time_off where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'F8 A-front_desk delete of B time off affects 0 rows');
select is_empty($$update public.staff_hours set clinic_id = 'b5000000-0000-4000-8000-00000000000c' where clinic_id = 'a5000000-0000-4000-8000-00000000000c' returning 1$$, 'F9 A-front_desk moving A hours to B affects 0 rows');
select is_empty($$update public.staff_time_off set clinic_id = 'b5000000-0000-4000-8000-00000000000c' where clinic_id = 'a5000000-0000-4000-8000-00000000000c' returning 1$$, 'F10 A-front_desk moving A time off to B affects 0 rows');
select throws_ok($$update public.clinics set slot_minutes = 15, name = 'x' where id = 'b5000000-0000-4000-8000-00000000000c'$$, '42501', null, 'F11 A-front_desk cannot change clinic B');
select is_empty($$select 1 from public.clinics where id = 'b5000000-0000-4000-8000-00000000000c'$$, 'F12 A-front_desk cannot read clinic B settings');
select throws_ok($$select public.clinic_staff_limit('b5000000-0000-4000-8000-00000000000c')$$, '42501', null, 'F13 A-front_desk cannot read clinic B staff limit (migration 1100)');
select is_empty($$select 1 from public.staff where clinic_id = 'b5000000-0000-4000-8000-00000000000c'$$, 'F14 A-front_desk sees no clinic B staff');
select throws_ok($$insert into public.staff (clinic_id, role, display_name) values ('b5000000-0000-4000-8000-00000000000c','therapist','Intrusa')$$, '42501', null, 'F15 A-front_desk cannot add staff to clinic B');
select is_empty(format($$update public.staff set active = false, display_name = 'x' where user_id = %L returning 1$$, current_setting('iso.b_nl')), 'F16 A-front_desk cannot edit/deactivate B''s login-less therapist');
select is_empty($$delete from public.staff where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'F17 A-front_desk delete of B staff affects 0 rows');
select throws_ok($$update public.staff set clinic_id = 'b5000000-0000-4000-8000-00000000000c' where user_id = 'a5000000-0000-4000-8000-000000000002'$$, '42501', null, 'F18 A-front_desk cannot move self into clinic B');
select is_empty($$select 1 from public.appointments where clinic_id = 'b5000000-0000-4000-8000-00000000000c'$$, 'F19 A-front_desk sees no clinic B appointments');
select throws_ok($$insert into public.appointments (clinic_id, staff_id, client_name, email, service, slot_date, slot_time) values ('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003','X','x@x.com','initial',current_date+7,'09:00')$$, '42501', null, 'F20 A-front_desk cannot insert a clinic B appointment');
select throws_ok($$update public.appointments set staff_id = 'b5000000-0000-4000-8000-000000000003' where id = 'a5000000-0000-4000-8000-0000000000a1'$$, '42501', null, 'F21 A-front_desk cannot assign an A appointment to a B therapist');
select is_empty($$update public.appointments set status = 'declined' where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'F22 A-front_desk decision on B appointments affects 0 rows');

-- ============ [T] therapist of clinic A against clinic B ============
select set_config('request.jwt.claims','{"role":"authenticated","sub":"a5000000-0000-4000-8000-000000000003"}',true);
select is_empty($$select 1 from public.staff_hours where clinic_id = 'b5000000-0000-4000-8000-00000000000c'$$, 'T1 A-therapist reads no clinic B hours');
select is_empty($$select 1 from public.staff_time_off where clinic_id = 'b5000000-0000-4000-8000-00000000000c' or reason like 'motivo B%'$$, 'T2 A-therapist reads no clinic B time off or reason');
select throws_ok($$insert into public.staff_hours (clinic_id, staff_id, weekday, start_time, end_time) values ('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003',1,'13:00','14:00')$$, '42501', null, 'T3 A-therapist cannot insert clinic B hours');
select throws_ok($$insert into public.staff_time_off (clinic_id, staff_id, start_date, end_date) values ('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003',current_date+60,current_date+60)$$, '42501', null, 'T4 A-therapist cannot insert clinic B time off');
select is_empty($$update public.staff_hours set end_time = '13:00' where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'T5 A-therapist update of B hours affects 0 rows');
select is_empty($$update public.staff_time_off set reason = 'x' where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'T6 A-therapist update of B time off affects 0 rows');
select is_empty($$delete from public.staff_hours where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'T7 A-therapist delete of B hours affects 0 rows');
select is_empty($$delete from public.staff_time_off where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'T8 A-therapist delete of B time off affects 0 rows');
select is_empty($$update public.staff_hours set clinic_id = 'b5000000-0000-4000-8000-00000000000c' where staff_id = 'a5000000-0000-4000-8000-000000000003' returning 1$$, 'T9 A-therapist moving own hours to B affects 0 rows');
select is_empty($$update public.staff_time_off set clinic_id = 'b5000000-0000-4000-8000-00000000000c' where staff_id = 'a5000000-0000-4000-8000-000000000003' returning 1$$, 'T10 A-therapist moving own time off to B affects 0 rows');
select throws_ok($$update public.clinics set slot_minutes = 15, name = 'x' where id = 'b5000000-0000-4000-8000-00000000000c'$$, '42501', null, 'T11 A-therapist cannot change clinic B');
select is_empty($$select 1 from public.clinics where id = 'b5000000-0000-4000-8000-00000000000c'$$, 'T12 A-therapist cannot read clinic B settings');
select throws_ok($$select public.clinic_staff_limit('b5000000-0000-4000-8000-00000000000c')$$, '42501', null, 'T13 A-therapist cannot read clinic B staff limit (migration 1100)');
select is_empty($$select 1 from public.staff where clinic_id = 'b5000000-0000-4000-8000-00000000000c'$$, 'T14 A-therapist sees no clinic B staff');
select throws_ok($$insert into public.staff (clinic_id, role, display_name) values ('b5000000-0000-4000-8000-00000000000c','therapist','Intrusa')$$, '42501', null, 'T15 A-therapist cannot add staff to clinic B');
select is_empty(format($$update public.staff set active = false, display_name = 'x' where user_id = %L returning 1$$, current_setting('iso.b_nl')), 'T16 A-therapist cannot edit/deactivate B''s login-less therapist');
select is_empty($$delete from public.staff where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'T17 A-therapist delete of B staff affects 0 rows');
select throws_ok($$update public.staff set clinic_id = 'b5000000-0000-4000-8000-00000000000c' where user_id = 'a5000000-0000-4000-8000-000000000003'$$, '42501', null, 'T18 A-therapist cannot move self into clinic B');
select is_empty($$select 1 from public.appointments where clinic_id = 'b5000000-0000-4000-8000-00000000000c'$$, 'T19 A-therapist sees no clinic B appointments');
select throws_ok($$insert into public.appointments (clinic_id, staff_id, client_name, email, service, slot_date, slot_time) values ('a5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003','X','x@x.com','initial',current_date+7,'09:00')$$, '42501', null, 'T20 A-therapist cannot insert an appointment for a B therapist');
select throws_ok($$update public.appointments set staff_id = 'b5000000-0000-4000-8000-000000000003' where id = 'a5000000-0000-4000-8000-0000000000a1'$$, '42501', null, 'T21 A-therapist cannot hand own appointment to a B therapist');
select is_empty($$update public.appointments set status = 'declined' where clinic_id = 'b5000000-0000-4000-8000-00000000000c' returning 1$$, 'T22 A-therapist decision on B appointments affects 0 rows');

-- ============ [N] anon (guest booking page) ============
reset role;
set local role anon;
select set_config('request.jwt.claims','{"role":"anon"}',true);
select throws_ok($$select 1 from public.staff_hours$$, '42501', null, 'N1 anon cannot read staff_hours');
select throws_ok($$select reason from public.staff_time_off$$, '42501', null, 'N2 anon cannot read staff_time_off.reason (any clinic)');
select throws_ok($$select client_name, email, phone, notes, staff_note from public.appointments$$, '42501', null, 'N3 anon cannot read patient fields (any clinic)');
select throws_ok($$select 1 from public.staff$$, '42501', null, 'N4 anon cannot read staff');
select throws_ok($$select slot_minutes from public.clinics$$, '42501', null, 'N5 anon cannot read clinics');
select throws_ok($$insert into public.staff_hours (clinic_id, staff_id, weekday, start_time, end_time) values ('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003',1,'13:00','14:00')$$, '42501', null, 'N6 anon cannot insert hours');
select throws_ok($$insert into public.staff_time_off (clinic_id, staff_id, start_date, end_date) values ('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003',current_date+60,current_date+60)$$, '42501', null, 'N7 anon cannot insert time off');
select throws_ok($$update public.staff_time_off set reason = 'x'$$, '42501', null, 'N8 anon cannot update time off');
select throws_ok($$delete from public.staff_hours$$, '42501', null, 'N9 anon cannot delete hours');
select throws_ok($$update public.clinics set slot_minutes = 15$$, '42501', null, 'N10 anon cannot change clinics');
select throws_ok($$insert into public.staff (clinic_id, role, display_name) values ('b5000000-0000-4000-8000-00000000000c','therapist','Intrusa')$$, '42501', null, 'N11 anon cannot add staff');
select throws_ok($$update public.staff set active = false$$, '42501', null, 'N12 anon cannot deactivate staff');
select throws_ok($$insert into public.appointments (clinic_id, staff_id, client_name, email, service, slot_date, slot_time) values ('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003','X','x@x.com','initial',current_date+7,'09:00')$$, '42501', null, 'N13 anon cannot insert appointments directly');
select throws_ok($$select public.request_appointment('a5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000003',current_date+7,'09:00','X','x@x.com')$$, 'P0001', 'inactive_staff', 'N14 anon booking RPC rejects clinic A + B therapist');
select throws_ok(format($$select public.request_appointment('a5000000-0000-4000-8000-00000000000c',%L,current_date+7,'09:00','X','x@x.com')$$, current_setting('iso.b_nl')), 'P0001', 'inactive_staff', 'N15 anon booking RPC rejects clinic A + B login-less therapist');
select results_eq($$select display_name from public.list_therapists('b5000000-0000-4000-8000-00000000000c') order by 1$$, array['Sin cuenta B','Terapeuta B'], 'N16 B therapist list: only B''s active therapists (incl. login-less), no admin/front desk/inactive');
select results_eq($$select display_name from public.list_therapists('a5000000-0000-4000-8000-00000000000c')$$, array['Terapeuta A'], 'N17 A therapist list has nothing from B and skips A''s inactive login-less');
select is_empty($$select 1 from public.list_therapists('b5000000-0000-4000-8000-00000000000c') t join (values ('a5000000-0000-4000-8000-000000000003'::uuid), ('b5000000-0000-4000-8000-000000000004'::uuid), ('b5000000-0000-4000-8000-000000000001'::uuid)) v(id) using (id)$$, 'N18 B therapist list ids exclude A staff, B inactive and B admin');
select throws_ok($$select public.clinic_staff_limit('b5000000-0000-4000-8000-00000000000c')$$, '42501', null, 'N19 anon cannot read a clinic staff limit');
select isnt_empty(format($$select 1 from public.get_available_slots('b5000000-0000-4000-8000-00000000000c',%L,current_date+1,current_date+14)$$, current_setting('iso.b_nl')), 'N20 B''s login-less therapist is bookable on B''s page');
select is_empty($$select 1 from public.get_available_slots('b5000000-0000-4000-8000-00000000000c','a5000000-0000-4000-8000-000000000003',current_date+1,current_date+14)$$, 'N21 B''s page offers no slots for an A therapist');
select is_empty(format($$select 1 from public.get_available_slots('a5000000-0000-4000-8000-00000000000c',%L,current_date+1,current_date+14)$$, current_setting('iso.b_nl')), 'N22 A''s page offers no slots for B''s login-less therapist');
select is_empty($$select 1 from public.get_available_slots('b5000000-0000-4000-8000-00000000000c','b5000000-0000-4000-8000-000000000004',current_date+1,current_date+14)$$, 'N23 B''s page offers no slots for B''s inactive therapist');
select is_empty($$select 1 from public.get_taken_slots('a5000000-0000-4000-8000-00000000000c',current_date,current_date+30,'b5000000-0000-4000-8000-000000000003')$$, 'N24 taken slots for A + B therapist are empty');
select results_eq($$select slot_date, slot_time from public.get_taken_slots('b5000000-0000-4000-8000-00000000000c',current_date,current_date+30,'b5000000-0000-4000-8000-000000000003')$$,
  $$values (current_date+3, '09:00'::text)$$, 'N25 taken slots for a B therapist: date and time only, B''s booking only');
reset role;
select is(pg_get_function_result('public.list_therapists(uuid)'::regprocedure), 'TABLE(id uuid, display_name text)', 'N26 list_therapists exposes only id + display_name');
select ok(pg_get_function_result('public.get_available_slots(uuid,uuid,date,date)'::regprocedure) = 'TABLE(slot_date date, slot_time text)'
  and pg_get_function_result('public.get_taken_slots(uuid,date,date,uuid)'::regprocedure) = 'TABLE(slot_date date, slot_time text)'
  and pg_get_function_result('public.request_appointment(uuid,uuid,date,text,text,text,text,text,text)'::regprocedure) = 'uuid',
  'N27 slot/booking RPCs return no reason or patient fields');

-- ============ [C] active-staff cap with login-less staff ============
set local role authenticated;
select set_config('request.jwt.claims','{"role":"authenticated","sub":"a5000000-0000-4000-8000-000000000001"}',true);
select is((select count(*)::int from public.staff where active), 3, 'C1 clinic A (basico) has 3 active: full');
select throws_ok($$insert into public.staff (clinic_id, role, display_name) values ('a5000000-0000-4000-8000-00000000000c','therapist','Cuarta sin cuenta')$$, '23514', null, 'C2 A: 4th active login-less insert rejected');
select throws_ok($$insert into public.staff (user_id, clinic_id, role, display_name) values ('a5000000-0000-4000-8000-000000000005','a5000000-0000-4000-8000-00000000000c','therapist','Cuarta con cuenta')$$, '23514', null, 'C3 A: 4th active login insert rejected the same way');
select lives_ok($$insert into public.staff (clinic_id, role, display_name, active) values ('a5000000-0000-4000-8000-00000000000c','therapist','Cuarta inactiva',false)$$, 'C4 A: 4th inactive insert is allowed');
select throws_ok($$update public.staff set active = true where display_name = 'Cuarta inactiva'$$, '23514', null, 'C5 A: reactivating the inactive 4th is rejected');
select throws_ok(format($$update public.staff set active = true where user_id = %L$$, current_setting('iso.a_nl')), '23514', null, 'C6 A: reactivating the login-less therapist is rejected while full');
select results_eq($$update public.staff set active = false where user_id = 'a5000000-0000-4000-8000-000000000003' returning active$$, array[false], 'C7 A: deactivate the login therapist');
select results_eq(format($$update public.staff set active = true where user_id = %L returning active$$, current_setting('iso.a_nl')), array[true], 'C8 A: then reactivating the login-less therapist works');
select throws_ok($$update public.staff set active = true where user_id = 'a5000000-0000-4000-8000-000000000003'$$, '23514', null, 'C9 A: login therapist cannot come back now: login-less counts the same');
select is((select count(*)::int from public.staff where active), 3, 'C10 clinic A still has exactly 3 active');
select set_config('request.jwt.claims','{"role":"authenticated","sub":"b5000000-0000-4000-8000-000000000001"}',true);
select is((select count(*)::int from public.staff where active), 4, 'C11 clinic B (clinica) starts with 4 active (incl. login-less)');
select lives_ok($$insert into public.staff (clinic_id, role, display_name) values ('b5000000-0000-4000-8000-00000000000c','therapist','Quinta sin cuenta');
  insert into public.staff (user_id, clinic_id, role, display_name) values ('b5000000-0000-4000-8000-000000000005','b5000000-0000-4000-8000-00000000000c','therapist','Sexta con cuenta')$$, 'C12 B: 5th and 6th active allowed');
select throws_ok($$insert into public.staff (clinic_id, role, display_name) values ('b5000000-0000-4000-8000-00000000000c','therapist','Séptima sin cuenta')$$, '23514', null, 'C13 B: 7th active login-less rejected');
select throws_ok($$insert into public.staff (user_id, clinic_id, role, display_name) values ('b5000000-0000-4000-8000-000000000006','b5000000-0000-4000-8000-00000000000c','therapist','Séptima con cuenta')$$, '23514', null, 'C14 B: 7th active login rejected');
select throws_ok($$update public.staff set active = true where user_id = 'b5000000-0000-4000-8000-000000000004'$$, '23514', null, 'C15 B: reactivating as 7th rejected');

-- ============ [V] verification (service role): nothing of B changed, schema guards ============
reset role;
select is((select count(*)::int from public.staff_hours where clinic_id = 'b5000000-0000-4000-8000-00000000000c' and end_time = '12:00'), 21, 'V1 clinic B hours untouched');
select results_eq($$select reason from public.staff_time_off where clinic_id = 'b5000000-0000-4000-8000-00000000000c' order by 1$$, array['motivo B privado','motivo B sin cuenta'], 'V2 clinic B time off untouched');
select results_eq($$select name, slot_minutes from public.clinics where id = 'b5000000-0000-4000-8000-00000000000c'$$, $$values ('Iso B'::text, 45)$$, 'V3 clinic B name and slot_minutes untouched');
select results_eq($$select display_name, active from public.staff where clinic_id = 'b5000000-0000-4000-8000-00000000000c' and display_name not in ('Quinta sin cuenta','Sexta con cuenta') order by 1$$,
  $$values ('Admin B'::text, true), ('Inactiva B', false), ('Recepción B', true), ('Sin cuenta B', true), ('Terapeuta B', true)$$, 'V4 clinic B staff untouched');
select results_eq($$select id, staff_id, status, staff_note from public.appointments where clinic_id = 'b5000000-0000-4000-8000-00000000000c' order by 1$$,
  format($$values ('b5000000-0000-4000-8000-0000000000b1'::uuid, 'b5000000-0000-4000-8000-000000000003'::uuid, 'pending'::text, ''::text), ('b5000000-0000-4000-8000-0000000000b2', %L::uuid, 'approved', 'nota B')$$, current_setting('iso.b_nl')),
  'V5 clinic B appointments untouched');
select results_eq($$select clinic_id, staff_id from public.appointments where id = 'a5000000-0000-4000-8000-0000000000a1'$$,
  $$values ('a5000000-0000-4000-8000-00000000000c'::uuid, 'a5000000-0000-4000-8000-000000000003'::uuid)$$, 'V6 A appointment still in A with its A therapist');
select throws_ok($$update public.appointments set staff_id = 'b5000000-0000-4000-8000-000000000003' where id = 'a5000000-0000-4000-8000-0000000000a1'$$, '23503', null, 'V7 even service role cannot give an A appointment a B therapist (composite FK)');
select ok(not exists (select 1 from auth.users where id in (current_setting('iso.a_nl')::uuid, current_setting('iso.b_nl')::uuid))
  and current_setting('iso.b_nl')::uuid is not null, 'V8 login-less therapists got a generated id with no auth account');

select is(public.clinic_staff_limit('b5000000-0000-4000-8000-00000000000c'), 6, 'V9 postgres (SQL editor / migration owner) still reads the staff limit after 1100');
select ok(not has_function_privilege('anon','public.clinic_staff_limit(uuid)','execute')
  and not has_function_privilege('authenticated','public.clinic_staff_limit(uuid)','execute'), 'V10 neither anon nor authenticated can execute clinic_staff_limit');
select * from finish();
rollback;
