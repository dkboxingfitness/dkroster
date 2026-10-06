-- =====================================================================
-- STEP 2 — Create the DK Boxing database.
-- Supabase: SQL Editor → New query → paste all of this → Run.
-- Safe to run again later (it won't delete data).
-- =====================================================================


-- ---------------------------------------------------------------------
-- Today's date in Sri Lanka (the server itself runs on UTC)
-- ---------------------------------------------------------------------
create or replace function public.today_lk()
returns date
language sql stable
as $$ select (now() at time zone 'Asia/Colombo')::date $$;


-- ---------------------------------------------------------------------
-- COACHES — only accounts listed here can see private data or edit.
-- ---------------------------------------------------------------------
create table if not exists public.coaches (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.coaches enable row level security;
-- (no policies on purpose: nobody can read or change this list through the app)

create or replace function public.is_coach()
returns boolean
language sql stable security definer
set search_path = public
as $$ select exists (select 1 from public.coaches where user_id = auth.uid()) $$;

grant execute on function public.is_coach() to anon, authenticated;


-- ---------------------------------------------------------------------
-- SETTINGS — fee amounts the coach can change from the app
-- ---------------------------------------------------------------------
create table if not exists public.settings (
  id            int primary key default 1 check (id = 1),
  admission_fee int not null default 1000 check (admission_fee >= 0),
  monthly_fee   int not null default 3000 check (monthly_fee >= 0),
  updated_at    timestamptz not null default now()
);
insert into public.settings (id) values (1) on conflict (id) do nothing;


-- ---------------------------------------------------------------------
-- MEMBERS — public info shown on the roster
-- ---------------------------------------------------------------------
create table if not exists public.members (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 1 and 80),
  type       text not null default 'boxer'    check (type  in ('boxer','fitness')),
  level      text not null default 'Beginner' check (level in ('Beginner','Intermediate','Advanced')),
  joined_on  date not null default public.today_lk(),
  active     boolean not null default true,   -- false = archived (left the club)
  left_on    date,
  ratings    jsonb not null default '{}'::jsonb,  -- kept up to date automatically from sessions
  created_at timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- MEMBER DETAILS — private (coach only)
-- ---------------------------------------------------------------------
create table if not exists public.member_details (
  member_id          uuid primary key references public.members(id) on delete cascade,
  dob                date,
  gender             text,
  national_id        text,
  mobile             text,
  whatsapp           text,
  email              text,
  address            text,
  emergency_name     text,
  emergency_phone    text,
  emergency_relation text,
  schedule           text[] not null default '{}',
  prior_experience   text,
  medical            text,
  admission_waived   boolean not null default false,  -- true = joined before the app, no admission fee owed
  updated_at         timestamptz not null default now()
);
alter table public.member_details add column if not exists admission_waived boolean not null default false;


-- ---------------------------------------------------------------------
-- ATTENDANCE — one row = this member was present on this day (coach only)
-- ---------------------------------------------------------------------
create table if not exists public.attendance (
  member_id  uuid not null references public.members(id) on delete cascade,
  day        date not null,
  created_at timestamptz not null default now(),
  primary key (member_id, day)
);
create index if not exists attendance_day_idx on public.attendance(day);


-- ---------------------------------------------------------------------
-- PAYMENTS — admission (once) and monthly fees (coach only)
-- ---------------------------------------------------------------------
create table if not exists public.payments (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null references public.members(id) on delete cascade,
  kind         text not null check (kind in ('admission','monthly')),
  period       date check (period is null or extract(day from period) = 1),  -- month paid for (1st of month)
  amount       int  not null check (amount >= 0),
  method       text not null default 'cash' check (method in ('cash','bank','other')),
  note         text check (note is null or length(note) <= 200),
  receipt_path text,
  paid_on      date not null default public.today_lk(),
  created_at   timestamptz not null default now(),
  constraint monthly_has_period check ((kind = 'monthly') = (period is not null))
);
create unique index if not exists payments_one_admission on public.payments(member_id)         where kind = 'admission';
create unique index if not exists payments_one_per_month on public.payments(member_id, period) where kind = 'monthly';
create index        if not exists payments_paid_on_idx   on public.payments(paid_on);


-- ---------------------------------------------------------------------
-- SESSIONS — progress notes + ratings (public can read)
-- ---------------------------------------------------------------------
create table if not exists public.sessions (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references public.members(id) on delete cascade,
  day         date not null default public.today_lk(),
  note        text not null default '' check (length(note) <= 2000),
  skill_notes jsonb not null default '{}'::jsonb,
  ratings     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists sessions_member_idx on public.sessions(member_id, day desc, created_at desc);

-- A member's current ratings = the latest rating given for each skill.
-- Recalculated automatically whenever a session is added, edited or deleted,
-- so deleting a mistaken session puts the old ratings back.
create or replace function public.recompute_ratings(p_member uuid)
returns void
language sql security definer
set search_path = public
as $$
  update public.members m
  set ratings = coalesce((
    select jsonb_object_agg(k, v)
    from (
      select distinct on (e.key) e.key as k, e.value as v
      from public.sessions s
      cross join lateral jsonb_each(s.ratings) e
      where s.member_id = p_member
      order by e.key, s.day desc, s.created_at desc
    ) latest
  ), '{}'::jsonb)
  where m.id = p_member;
$$;
revoke execute on function public.recompute_ratings(uuid) from public, anon, authenticated;

create or replace function public.sessions_after_change()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if tg_op in ('INSERT','UPDATE') then perform public.recompute_ratings(new.member_id); end if;
  if tg_op in ('DELETE','UPDATE') then perform public.recompute_ratings(old.member_id); end if;
  return null;
end;
$$;

drop trigger if exists sessions_ratings on public.sessions;
create trigger sessions_ratings
after insert or update or delete on public.sessions
for each row execute function public.sessions_after_change();


-- =====================================================================
-- SECURITY RULES (Row Level Security)
--   Public (anyone with the link): read active members + their sessions.
--   Coach: everything.
-- =====================================================================
alter table public.settings       enable row level security;
alter table public.members        enable row level security;
alter table public.member_details enable row level security;
alter table public.attendance     enable row level security;
alter table public.payments       enable row level security;
alter table public.sessions       enable row level security;

-- settings
drop policy if exists "coach reads settings"   on public.settings;
drop policy if exists "coach updates settings" on public.settings;
create policy "coach reads settings"   on public.settings for select to authenticated using (public.is_coach());
create policy "coach updates settings" on public.settings for update to authenticated using (public.is_coach()) with check (public.is_coach());

-- members
drop policy if exists "public reads active members" on public.members;
drop policy if exists "coach adds members"          on public.members;
drop policy if exists "coach edits members"         on public.members;
drop policy if exists "coach deletes members"       on public.members;
create policy "public reads active members" on public.members for select to anon, authenticated using (active or public.is_coach());
create policy "coach adds members"          on public.members for insert to authenticated with check (public.is_coach());
create policy "coach edits members"         on public.members for update to authenticated using (public.is_coach()) with check (public.is_coach());
create policy "coach deletes members"       on public.members for delete to authenticated using (public.is_coach());

-- member_details, attendance, payments: coach only
drop policy if exists "coach only" on public.member_details;
drop policy if exists "coach only" on public.attendance;
drop policy if exists "coach only" on public.payments;
create policy "coach only" on public.member_details for all to authenticated using (public.is_coach()) with check (public.is_coach());
create policy "coach only" on public.attendance     for all to authenticated using (public.is_coach()) with check (public.is_coach());
create policy "coach only" on public.payments       for all to authenticated using (public.is_coach()) with check (public.is_coach());

-- sessions
drop policy if exists "public reads sessions" on public.sessions;
drop policy if exists "coach adds sessions"   on public.sessions;
drop policy if exists "coach edits sessions"  on public.sessions;
drop policy if exists "coach deletes sessions" on public.sessions;
create policy "public reads sessions" on public.sessions for select to anon, authenticated
  using (public.is_coach() or exists (select 1 from public.members m where m.id = member_id and m.active));
create policy "coach adds sessions"    on public.sessions for insert to authenticated with check (public.is_coach());
create policy "coach edits sessions"   on public.sessions for update to authenticated using (public.is_coach()) with check (public.is_coach());
create policy "coach deletes sessions" on public.sessions for delete to authenticated using (public.is_coach());


-- =====================================================================
-- RECEIPT PHOTOS (private storage, coach only, images/PDF up to 5 MB)
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 5242880,
        array['image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "coach uploads receipts" on storage.objects;
drop policy if exists "coach views receipts"   on storage.objects;
drop policy if exists "coach deletes receipts" on storage.objects;
create policy "coach uploads receipts" on storage.objects for insert to authenticated with check (bucket_id = 'receipts' and public.is_coach());
create policy "coach views receipts"   on storage.objects for select to authenticated using      (bucket_id = 'receipts' and public.is_coach());
create policy "coach deletes receipts" on storage.objects for delete to authenticated using      (bucket_id = 'receipts' and public.is_coach());
