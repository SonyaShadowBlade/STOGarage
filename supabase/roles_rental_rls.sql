-- STOGarage: roles + rental isolation (phase 1)
-- Run this script once in Supabase SQL Editor.
-- This does NOT yet change the existing clients/vehicles/services policies.
-- It creates the security foundation and dedicated rental tables.

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'renter'
    check (role in ('admin','father','renter')),
  created_at timestamptz not null default now()
);

create table if not exists public.rental_vehicle_access (
  user_id uuid not null references auth.users(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, vehicle_id)
);

create table if not exists public.rental_trips (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  driver text,
  trip_date date not null default current_date,
  start_mileage numeric,
  end_mileage numeric,
  route_note text,
  created_at timestamptz not null default now()
);

create table if not exists public.rental_fuel (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  fuel_date date not null default current_date,
  mileage numeric,
  liters numeric,
  cost numeric,
  note text,
  created_at timestamptz not null default now()
);

create table if not exists public.rental_issues (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  issue_date date not null default current_date,
  mileage numeric,
  description text not null,
  created_at timestamptz not null default now()
);

-- Security-definer helpers avoid depending on the caller being able to read
-- profiles directly and prevent recursive RLS checks.
create or replace function public.current_user_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where user_id = auth.uid()
$$;

create or replace function public.can_access_rental_vehicle(p_vehicle_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.rental_vehicle_access a
    where a.user_id = auth.uid()
      and a.vehicle_id = p_vehicle_id
  )
$$;

alter table public.profiles enable row level security;
alter table public.rental_vehicle_access enable row level security;
alter table public.rental_trips enable row level security;
alter table public.rental_fuel enable row level security;
alter table public.rental_issues enable row level security;

drop policy if exists "profiles_self_read" on public.profiles;
create policy "profiles_self_read"
on public.profiles for select
to authenticated
using (user_id = auth.uid());

drop policy if exists "rental_access_self_read" on public.rental_vehicle_access;
create policy "rental_access_self_read"
on public.rental_vehicle_access for select
to authenticated
using (user_id = auth.uid());

drop policy if exists "rental_trips_owner_access" on public.rental_trips;
create policy "rental_trips_owner_access"
on public.rental_trips for all
to authenticated
using (
  user_id = auth.uid()
  and public.can_access_rental_vehicle(vehicle_id)
)
with check (
  user_id = auth.uid()
  and public.can_access_rental_vehicle(vehicle_id)
);

drop policy if exists "rental_fuel_owner_access" on public.rental_fuel;
create policy "rental_fuel_owner_access"
on public.rental_fuel for all
to authenticated
using (
  user_id = auth.uid()
  and public.can_access_rental_vehicle(vehicle_id)
)
with check (
  user_id = auth.uid()
  and public.can_access_rental_vehicle(vehicle_id)
);

drop policy if exists "rental_issues_owner_access" on public.rental_issues;
create policy "rental_issues_owner_access"
on public.rental_issues for all
to authenticated
using (
  user_id = auth.uid()
  and public.can_access_rental_vehicle(vehicle_id)
)
with check (
  user_id = auth.uid()
  and public.can_access_rental_vehicle(vehicle_id)
);

-- Create Sanечка's profile automatically from the existing Auth account.
insert into public.profiles (user_id, full_name, role)
select id, 'Александр Михнин', 'renter'
from auth.users
where lower(email) = lower('michnin.aleksandr.1@gmail.com')
on conflict (user_id) do update
set full_name = excluded.full_name,
    role = excluded.role;

-- IMPORTANT:
-- After running this script, assign Sanечке his actual rental vehicle:
--
-- insert into public.rental_vehicle_access (user_id, vehicle_id)
-- select u.id, v.id
-- from auth.users u
-- cross join public.vehicles v
-- where lower(u.email) = lower('michnin.aleksandr.1@gmail.com')
--   and lower(coalesce(v.make,'') || ' ' || coalesce(v.model,'') || ' ' || coalesce(v.name,'')) like '%iveco%';
--
-- The vehicle assignment is intentionally NOT automatic here because there
-- may be more than one Iveco in the database.

-- Helpful indexes
create index if not exists idx_rental_vehicle_access_user
  on public.rental_vehicle_access(user_id);

create index if not exists idx_rental_trips_user_vehicle
  on public.rental_trips(user_id, vehicle_id, trip_date desc);

create index if not exists idx_rental_fuel_user_vehicle
  on public.rental_fuel(user_id, vehicle_id, fuel_date desc);

create index if not exists idx_rental_issues_user_vehicle
  on public.rental_issues(user_id, vehicle_id, issue_date desc);
