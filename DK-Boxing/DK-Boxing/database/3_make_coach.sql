-- =====================================================================
-- STEP 3 — Give the coach's login access to the dashboard.
-- First create his login: Authentication → Users → Add user → Create new user
-- (tick "Auto Confirm User"). Then put his email below and run this.
-- =====================================================================

insert into public.coaches (user_id)
select id from auth.users
where lower(email) = lower('coach@example.com')   -- ← change to the coach's email
on conflict (user_id) do nothing;

-- Should show one row. If it shows nothing, the email doesn't match a user.
select u.email, c.added_at
from public.coaches c join auth.users u on u.id = c.user_id;
