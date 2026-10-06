-- =====================================================================
-- STEP 1 — Remove the old version's tables (run ONCE, before step 2).
-- Only run this because the old app was never used with real data.
-- It permanently deletes the old "members" and "member_private" tables.
-- =====================================================================

drop function if exists public.mark_fee_pending(text, text, text);
drop function if exists public.mark_fee_pending(text, text);

drop table if exists public.member_private cascade;
drop table if exists public.members cascade;

drop policy if exists "Anyone can upload payment slips" on storage.objects;
drop policy if exists "Coach can view payment slips"    on storage.objects;
drop policy if exists "Coach can delete payment slips"  on storage.objects;

-- The old "payment-slips" storage bucket can be deleted from the dashboard:
-- Storage → payment-slips → ⋯ → Delete bucket.
