-- D3 isolation (QA, d3_clinic_isolation_test A19/F13/T13): clinic_staff_limit(uuid) is SECURITY DEFINER
-- with no membership check, and 0400 granted it to authenticated, so any signed-in staff member of any
-- clinic could read another clinic's staff limit (and so its plan or custom override). Anon never could.
-- Only the staff_limit trigger (enforce_staff_limit, SECURITY DEFINER, owner postgres) calls it, and it
-- runs with the owner's rights, so the cap keeps working. The app never calls it. Service role / SQL
-- editor (postgres) keep access. Revoke is idempotent; no data changes.
-- Rollback: supabase/rollback/rollback_1100.sql
revoke execute on function public.clinic_staff_limit(uuid) from public, anon, authenticated;
