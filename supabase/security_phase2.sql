-- STOGarage security phase 2
-- Run after roles_rental_rls.sql in production Supabase.

-- Make sure the existing Sanечка account has a renter profile.
insert into public.profiles (user_id, full_name, role)
select id, 'Александр Михнин', 'renter'
from auth.users
where lower(email) = lower('michnin.aleksandr.1@gmail.com')
on conflict (user_id) do update
set full_name = excluded.full_name,
    role = excluded.role;

-- Admin/father helpers.
create or replace function public.is_staff()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() in ('admin','father') or public.current_user_role() is null, false)
$$;

-- Remove existing policies from the core STO tables so the new role rules
-- cannot be bypassed by an old permissive policy.
do $$
declare
  p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in (
        'clients','vehicles','services','service_items','service_parts'
      )
  loop
    execute format(
      'drop policy if exists %I on %I.%I',
      p.policyname, p.schemaname, p.tablename
    );
  end loop;
end $$;

alter table public.clients enable row level security;
alter table public.vehicles enable row level security;
alter table public.services enable row level security;
alter table public.service_items enable row level security;
alter table public.service_parts enable row level security;

-- Full STO access for admin/father.
create policy "staff_clients_all"
on public.clients for all to authenticated
using (public.is_staff())
with check (public.is_staff());

create policy "staff_vehicles_all"
on public.vehicles for all to authenticated
using (public.is_staff())
with check (public.is_staff());

create policy "staff_services_all"
on public.services for all to authenticated
using (public.is_staff())
with check (public.is_staff());

create policy "staff_service_items_all"
on public.service_items for all to authenticated
using (public.is_staff())
with check (public.is_staff());

create policy "staff_service_parts_all"
on public.service_parts for all to authenticated
using (public.is_staff())
with check (public.is_staff());

-- Rental users get vehicle data only through a controlled RPC, not direct
-- SELECT on public.vehicles.
revoke all on public.clients from authenticated;
revoke all on public.vehicles from authenticated;
revoke all on public.services from authenticated;
revoke all on public.service_items from authenticated;
revoke all on public.service_parts from authenticated;

grant select, insert, update, delete on public.clients to authenticated;
grant select, insert, update, delete on public.vehicles to authenticated;
grant select, insert, update, delete on public.services to authenticated;
grant select, insert, update, delete on public.service_items to authenticated;
grant select, insert, update, delete on public.service_parts to authenticated;

-- The grants above are needed by RLS for staff; policies are what restrict
-- renter access. Renter has no matching core-table policy.

create or replace function public.get_my_rental_vehicles()
returns setof public.vehicles
language sql
stable
security definer
set search_path = public
as $$
  select v.*
  from public.vehicles v
  join public.rental_vehicle_access a
    on a.vehicle_id = v.id
  where a.user_id = auth.uid()
$$;

revoke all on function public.get_my_rental_vehicles() from public;
grant execute on function public.get_my_rental_vehicles() to authenticated;

create or replace function public.get_my_rental_profile()
returns table (
  full_name text,
  role text
)
language sql
stable
security definer
set search_path = public
as $$
  select p.full_name, p.role
  from public.profiles p
  where p.user_id = auth.uid()
$$;

revoke all on function public.get_my_rental_profile() from public;
grant execute on function public.get_my_rental_profile() to authenticated;

-- Give Sanечке the first Iveco found, but only if he has no assignment yet.
-- vehicles has no "name" column in the current STOGarage schema,
-- so identify the vehicle by make/model only.
-- This avoids creating multiple assignments on repeated runs.
insert into public.rental_vehicle_access (user_id, vehicle_id)
select u.id, v.id
from auth.users u
cross join lateral (
  select id
  from public.vehicles
  where lower(
    coalesce(make,'') || ' ' ||
    coalesce(model,'')
  ) like '%iveco%'
  order by created_at asc nulls last
  limit 1
) v
where lower(u.email) = lower('michnin.aleksandr.1@gmail.com')
  and not exists (
    select 1
    from public.rental_vehicle_access a
    where a.user_id = u.id
  )
on conflict do nothing;
