-- Rollback for 20261019001100_revoke_clinic_staff_limit.sql: signed-in users can call
-- clinic_staff_limit(uuid) again (exact grant from 0400). One transaction; run in the SQL editor.
begin;
grant execute on function public.clinic_staff_limit(uuid) to authenticated;
commit;
