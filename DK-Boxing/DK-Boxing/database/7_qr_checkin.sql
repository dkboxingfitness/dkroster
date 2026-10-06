-- =====================================================================
-- DK Boxing — QR self check-in
-- Supabase: SQL Editor → New query → paste all of this → Run.
-- Safe to run more than once.
--
-- Members scan the QR at the door and check themselves in. To stop fake
-- check-ins, the server (not the phone) checks that:
--   • the phone belongs to that member (one approved phone per member),
--   • the phone is at the gym (location check),
--   • it's during check-in hours on a class day,
--   • in "door screen" mode, the QR code was shown in the last ~90 seconds,
--   • they haven't already checked in today.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. Check-in settings (changed from the app: Attendance → Check-in settings)
-- ---------------------------------------------------------------------
alter table public.settings
  add column if not exists checkin_mode     text not null default 'printed',
  add column if not exists gym_lat          double precision,
  add column if not exists gym_lng          double precision,
  add column if not exists checkin_radius_m int  not null default 150,
  add column if not exists checkin_days     text[] not null default '{Mon,Tue,Wed,Thu,Fri,Sat,Sun}',
  add column if not exists checkin_open     time not null default '05:00',
  add column if not exists checkin_close    time not null default '22:00';

alter table public.settings drop constraint if exists settings_checkin_mode_check;
alter table public.settings add constraint settings_checkin_mode_check check (checkin_mode in ('printed','screen','off'));
alter table public.settings drop constraint if exists settings_checkin_radius_check;
alter table public.settings add constraint settings_checkin_radius_check check (checkin_radius_m between 30 and 2000);

-- Secret used to make the changing door-screen codes. Nobody can read it through the app.
create table if not exists public.checkin_secret (
  id     int primary key default 1 check (id = 1),
  secret text not null default encode(extensions.gen_random_bytes(32), 'hex')
);
insert into public.checkin_secret (id) values (1) on conflict (id) do nothing;
alter table public.checkin_secret enable row level security;   -- no policies on purpose


-- ---------------------------------------------------------------------
-- 2. Attendance: remember how each check-in happened
-- ---------------------------------------------------------------------
alter table public.attendance
  add column if not exists source        text not null default 'coach',
  add column if not exists checked_in_at timestamptz,
  add column if not exists distance_m    int;
alter table public.attendance drop constraint if exists attendance_source_check;
alter table public.attendance add constraint attendance_source_check check (source in ('coach','self'));


-- ---------------------------------------------------------------------
-- 3. Phones linked to members
-- ---------------------------------------------------------------------
create table if not exists public.member_devices (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references public.members(id) on delete cascade,
  device_hash text not null,   -- fingerprint of the phone's private id (the id itself is never stored)
  status      text not null default 'pending' check (status in ('approved','pending','rejected')),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz,
  unique (member_id, device_hash)
);
create index if not exists member_devices_hash_idx on public.member_devices(device_hash);
alter table public.member_devices enable row level security;
drop policy if exists "coach only" on public.member_devices;
create policy "coach only" on public.member_devices for all to authenticated using (public.is_coach()) with check (public.is_coach());

-- Wrong PIN attempts, so nobody can guess a PIN by trying them all.
create table if not exists public.checkin_attempts (
  member_id uuid not null references public.members(id) on delete cascade,
  at        timestamptz not null default now()
);
create index if not exists checkin_attempts_idx on public.checkin_attempts(member_id, at);
alter table public.checkin_attempts enable row level security;   -- no policies on purpose


-- ---------------------------------------------------------------------
-- 4. Door screen accounts (optional, for the changing QR on a screen)
--    A separate login that can ONLY show the door QR, so a tablet left at
--    the door can't open the coach dashboard.
-- ---------------------------------------------------------------------
create table if not exists public.door_accounts (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.door_accounts enable row level security;   -- no policies on purpose

create or replace function public.is_door()
returns boolean
language sql stable security definer
set search_path = public
as $$ select exists (select 1 from public.door_accounts where user_id = auth.uid()) $$;
grant execute on function public.is_door() to anon, authenticated;


-- ---------------------------------------------------------------------
-- 5. Helpers
-- ---------------------------------------------------------------------
create or replace function public.checkin_device_hash(p_device text)
returns text
language sql immutable
set search_path = public, extensions
as $$ select encode(extensions.digest(p_device, 'sha256'), 'hex') $$;

create or replace function public.checkin_code_for(p_slot bigint)
returns text
language sql stable security definer
set search_path = public, extensions
as $$
  select substr(encode(extensions.hmac(p_slot::text, s.secret, 'sha256'), 'hex'), 1, 12)
  from public.checkin_secret s where s.id = 1
$$;
revoke execute on function public.checkin_code_for(bigint) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 6. What the check-in page calls
-- ---------------------------------------------------------------------

-- Is this phone linked to someone?
create or replace function public.checkin_status(p_device text)
returns json
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare r record;
begin
  if p_device is null or length(p_device) < 20 then return json_build_object('state','none'); end if;
  select d.status, m.id as member_id, m.name, m.active into r
  from public.member_devices d join public.members m on m.id = d.member_id
  where d.device_hash = public.checkin_device_hash(p_device)
  order by d.created_at desc limit 1;
  if not found or not r.active then return json_build_object('state','none'); end if;
  return json_build_object('state', r.status, 'member_id', r.member_id, 'name', r.name);
end $$;

-- Link this phone to a member, using the last 4 digits of their phone number as the PIN.
create or replace function public.checkin_link(p_member uuid, p_pin text, p_device text)
returns json
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  v_mobile text; v_whatsapp text; v_hash text; v_existing text; v_fails int;
  v_name text;
begin
  if p_device is null or length(p_device) < 20 then return json_build_object('result','bad_device'); end if;
  select m.name into v_name from public.members m where m.id = p_member and m.active;
  if not found then return json_build_object('result','not_found'); end if;

  select count(*) into v_fails from public.checkin_attempts
  where member_id = p_member and at > now() - interval '12 hours';
  if v_fails >= 5 then return json_build_object('result','locked'); end if;

  select regexp_replace(coalesce(d.mobile,''), '\D', '', 'g'),
         regexp_replace(coalesce(d.whatsapp,''), '\D', '', 'g')
    into v_mobile, v_whatsapp
  from public.member_details d where d.member_id = p_member;
  if coalesce(length(v_mobile),0) < 4 and coalesce(length(v_whatsapp),0) < 4 then
    return json_build_object('result','no_phone');
  end if;

  if p_pin is null or p_pin !~ '^\d{4}$'
     or not (right(coalesce(v_mobile,''),4) = p_pin or right(coalesce(v_whatsapp,''),4) = p_pin) then
    insert into public.checkin_attempts (member_id) values (p_member);
    return json_build_object('result','wrong_pin', 'tries_left', greatest(0, 4 - v_fails));
  end if;

  delete from public.checkin_attempts where member_id = p_member;
  v_hash := public.checkin_device_hash(p_device);

  select status into v_existing from public.member_devices where member_id = p_member and device_hash = v_hash;
  if found then
    if v_existing = 'rejected' then
      update public.member_devices set status = 'pending', created_at = now(), decided_at = null
      where member_id = p_member and device_hash = v_hash;
      v_existing := 'pending';
    end if;
    return json_build_object('result', v_existing, 'name', v_name);
  end if;

  if exists (select 1 from public.member_devices where member_id = p_member and status = 'approved') then
    insert into public.member_devices (member_id, device_hash, status) values (p_member, v_hash, 'pending');
    return json_build_object('result','pending', 'name', v_name);
  end if;

  insert into public.member_devices (member_id, device_hash, status, decided_at) values (p_member, v_hash, 'approved', now());
  return json_build_object('result','approved', 'name', v_name);
end $$;

-- Check in. Every rule is checked here on the server, so it can't be skipped from the phone.
create or replace function public.checkin(p_device text, p_lat double precision, p_lng double precision,
                                          p_accuracy double precision, p_code text)
returns json
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  r record; s record;
  v_now timestamp := now() at time zone 'Asia/Colombo';
  v_day date := (now() at time zone 'Asia/Colombo')::date;
  v_dow text := to_char(now() at time zone 'Asia/Colombo', 'Dy');
  v_slot bigint := floor(extract(epoch from now()) / 30)::bigint;
  v_dist double precision; v_allowed double precision; v_rows int;
begin
  if p_device is null or length(p_device) < 20 then return json_build_object('result','not_linked'); end if;
  select d.status, m.id as member_id, m.name, m.active into r
  from public.member_devices d join public.members m on m.id = d.member_id
  where d.device_hash = public.checkin_device_hash(p_device)
  order by d.created_at desc limit 1;
  if not found or not r.active then return json_build_object('result','not_linked'); end if;
  if r.status <> 'approved' then return json_build_object('result', r.status, 'name', r.name); end if;

  select * into s from public.settings where id = 1;
  if s.checkin_mode = 'off' then return json_build_object('result','off'); end if;

  if not (v_dow = any(s.checkin_days)) or v_now::time < s.checkin_open or v_now::time > s.checkin_close then
    return json_build_object('result','closed', 'days', s.checkin_days,
      'open', to_char(s.checkin_open,'HH24:MI'), 'close', to_char(s.checkin_close,'HH24:MI'));
  end if;

  if s.checkin_mode = 'screen' then
    if p_code is null or p_code not in (public.checkin_code_for(v_slot), public.checkin_code_for(v_slot - 1),
                                         public.checkin_code_for(v_slot - 2)) then
      return json_build_object('result','bad_code');
    end if;
  end if;

  if s.gym_lat is null or s.gym_lng is null then return json_build_object('result','no_gym_location'); end if;
  if p_lat is null or p_lng is null then return json_build_object('result','no_location'); end if;
  v_dist := 2 * 6371000 * asin(sqrt(
              power(sin(radians(p_lat - s.gym_lat) / 2), 2) +
              cos(radians(s.gym_lat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - s.gym_lng) / 2), 2)));
  -- Phone locations wobble indoors, so allow for the phone's own accuracy (up to 100 m extra).
  v_allowed := s.checkin_radius_m + least(greatest(coalesce(p_accuracy, 0), 0), 100);
  if v_dist > v_allowed then
    return json_build_object('result','too_far', 'distance', round(v_dist));
  end if;

  insert into public.attendance (member_id, day, source, checked_in_at, distance_m)
  values (r.member_id, v_day, 'self', now(), round(v_dist))
  on conflict (member_id, day) do nothing;
  get diagnostics v_rows = row_count;
  return json_build_object('result', case when v_rows = 1 then 'ok' else 'already' end,
                           'name', r.name, 'member_id', r.member_id);
end $$;

-- The current door-screen code (coach or door account only).
create or replace function public.door_code()
returns json
language plpgsql stable security definer
set search_path = public, extensions
as $$
declare v_epoch bigint := floor(extract(epoch from now()))::bigint;
begin
  if not (public.is_coach() or public.is_door()) then raise exception 'not allowed'; end if;
  return json_build_object('code', public.checkin_code_for(v_epoch / 30),
                           'seconds_left', 30 - (v_epoch % 30),
                           'mode', (select checkin_mode from public.settings where id = 1));
end $$;

-- Coach approves a phone. The member's previous phone stops working.
create or replace function public.approve_device(p_id uuid)
returns void
language plpgsql volatile security definer
set search_path = public
as $$
declare v_member uuid;
begin
  if not public.is_coach() then raise exception 'not allowed'; end if;
  select member_id into v_member from public.member_devices where id = p_id;
  if not found then return; end if;
  update public.member_devices set status = 'rejected', decided_at = now()
  where member_id = v_member and id <> p_id and status = 'approved';
  update public.member_devices set status = 'approved', decided_at = now() where id = p_id;
end $$;

revoke execute on function public.checkin_status(text)                                  from public;
revoke execute on function public.checkin_link(uuid, text, text)                        from public;
revoke execute on function public.checkin(text, double precision, double precision, double precision, text) from public;
revoke execute on function public.door_code()                                           from public, anon;
revoke execute on function public.approve_device(uuid)                                  from public, anon;
grant execute on function public.checkin_status(text)                                   to anon, authenticated;
grant execute on function public.checkin_link(uuid, text, text)                         to anon, authenticated;
grant execute on function public.checkin(text, double precision, double precision, double precision, text) to anon, authenticated;
grant execute on function public.door_code()                                            to authenticated;
grant execute on function public.approve_device(uuid)                                   to authenticated;


-- ---------------------------------------------------------------------
-- LATER, for the door screen: make a separate login for the tablet.
--   1. Supabase → Authentication → Users → Add user (e.g. door@dkboxing.lk + a password).
--   2. Change the email below, remove the two dashes at the start of each line, and run just those lines.
-- ---------------------------------------------------------------------
-- insert into public.door_accounts (user_id)
-- select id from auth.users where lower(email) = lower('door@dkboxing.lk') on conflict do nothing;
