-- Schema for the KeepWatch server. Run once in the Supabase dashboard
-- (SQL Editor → New query → paste → Run). Safe to re-run.
--
-- Everything a user can see is scoped by household: a user reaches cameras
-- and motion events only through a membership in the household that owns them.
-- Timestamps are Unix epoch seconds (double precision), which is what the
-- server and mobile app exchange.

create table if not exists public.users (
  -- The Supabase Auth user id (the JWT `sub`). Deleting the auth user
  -- cascades to everything they own.
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  created_at double precision not null
);

create table if not exists public.households (
  id uuid primary key,
  name text not null,
  owner_user_id uuid not null references public.users (id) on delete cascade,
  created_at double precision not null
);
create index if not exists households_owner_user_id_idx on public.households (owner_user_id);

create table if not exists public.memberships (
  user_id uuid not null references public.users (id) on delete cascade,
  household_id uuid not null references public.households (id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'viewer')),
  created_at double precision not null,
  primary key (user_id, household_id)
);
-- The primary key covers lookups by user; this covers lookups (and cascades)
-- by household.
create index if not exists memberships_household_id_idx on public.memberships (household_id);

create table if not exists public.devices (
  id uuid primary key,
  household_id uuid not null references public.households (id) on delete cascade,
  name text not null,
  -- sha256 of the device token handed out at pairing; the token itself is
  -- never stored, so a DB leak doesn't let anyone impersonate a camera.
  token_hash text not null unique,
  created_at double precision not null,
  last_seen_at double precision,
  revoked_at double precision
);
create index if not exists devices_household_id_idx on public.devices (household_id);

create table if not exists public.pairing_codes (
  code text primary key,
  household_id uuid not null references public.households (id) on delete cascade,
  created_by uuid not null references public.users (id) on delete cascade,
  expires_at double precision not null,
  used_at double precision
);
create index if not exists pairing_codes_household_id_idx on public.pairing_codes (household_id);
create index if not exists pairing_codes_created_by_idx on public.pairing_codes (created_by);

-- One row per stretch of motion a camera saw: opened when its motion
-- detector fires, closed (ended_at set) once it has been still for a few
-- seconds, or when the camera disconnects. The camera records a clip of
-- each event and uploads it to the `clips` Storage bucket once the event
-- ends. clip_key is set when the camera asks for an upload URL, and
-- clip_size_bytes once the upload is confirmed, which is what makes the
-- event playable; both stay null if no upload ever arrives.
create table if not exists public.motion_events (
  id uuid primary key,
  device_id uuid not null references public.devices (id) on delete cascade,
  household_id uuid not null references public.households (id) on delete cascade,
  started_at double precision not null,
  ended_at double precision,
  clip_key text,
  clip_size_bytes bigint
);
create index if not exists motion_events_device_id_started_at_idx on public.motion_events (device_id, started_at desc);
create index if not exists motion_events_household_id_idx on public.motion_events (household_id);

-- Storage keys of clips whose motion event is gone, waiting for the
-- server's retention job to delete them from the bucket. A trigger fills
-- it, so cascades the server never sees (a deleted household, or a user
-- deleted in Supabase Auth) still get their clips cleaned up.
create table if not exists public.clip_deletions (
  clip_key text primary key,
  queued_at double precision not null
);

-- security definer: a cascade from deleting a Supabase Auth user runs as
-- the auth service's role, which RLS (and its grants) would otherwise stop
-- from writing here, failing the whole user deletion.
create or replace function public.queue_clip_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.clip_deletions (clip_key, queued_at)
  values (old.clip_key, extract(epoch from now()))
  on conflict (clip_key) do nothing;
  return old;
end;
$$;

drop trigger if exists motion_events_queue_clip_deletion on public.motion_events;
create trigger motion_events_queue_clip_deletion
after delete on public.motion_events
for each row
when (old.clip_key is not null)
execute function public.queue_clip_deletion();

-- Trigger functions can't be called directly, but keep it off the
-- client-facing roles like every other function here.
revoke execute on function public.queue_clip_deletion () from public, anon, authenticated;

-- The private bucket clips live in. Only the server (secret key) can reach
-- it; cameras and viewers get short-lived signed URLs for one object each.
insert into storage.buckets (id, name, public, allowed_mime_types)
values ('clips', 'clips', false, array['video/mp4'])
on conflict (id) do nothing;

-- The `public` schema is reachable through Supabase's Data API by anyone
-- holding the publishable key, which ships inside the mobile app. RLS with
-- no policies blocks that path entirely; the server uses the secret key,
-- which bypasses RLS.
alter table public.users enable row level security;
alter table public.households enable row level security;
alter table public.memberships enable row level security;
alter table public.devices enable row level security;
alter table public.pairing_codes enable row level security;
alter table public.motion_events enable row level security;
alter table public.clip_deletions enable row level security;

-- First sign-in: creates the user row plus a default "Home" household they
-- own, in one transaction, so a user can never end up without a household.
-- A no-op for users who already exist, which makes concurrent first
-- requests (e.g. the HTTP call and socket handshake right after sign-in)
-- safe.
create or replace function public.provision_user(p_user_id uuid, p_email text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_household_id uuid := gen_random_uuid();
  v_now double precision := extract(epoch from now());
begin
  insert into public.users (id, email, created_at)
  values (p_user_id, p_email, v_now)
  on conflict (id) do nothing;
  if not found then
    return;
  end if;

  insert into public.households (id, name, owner_user_id, created_at)
  values (v_household_id, 'Home', p_user_id, v_now);
  insert into public.memberships (user_id, household_id, role, created_at)
  values (p_user_id, v_household_id, 'owner', v_now);
end;
$$;

-- Supabase grants execute on new public functions to the client-facing
-- roles by default; only the server may call this.
revoke execute on function public.provision_user (uuid, text) from public, anon, authenticated;
grant execute on function public.provision_user (uuid, text) to service_role;
