-- STOGarage security phase 3
-- Read-only access for Санечка to his own STO client card and service history.
-- Run after security_phase2.sql in production Supabase.

create table if not exists public.service_client_access (
    user_id uuid not null references auth.users(id) on delete cascade,
    client_id uuid not null references public.clients(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (user_id, client_id)
);

alter table public.service_client_access enable row level security;

drop policy if exists "service_client_access_none" on public.service_client_access;
create policy "service_client_access_none"
on public.service_client_access
for all to authenticated
using (false)
with check (false);

revoke all on public.service_client_access from authenticated;

-- Link Санечка to his existing STO client card.
-- The first condition is the normal name; the second is a fallback for the
-- older client-card naming used during development.
insert into public.service_client_access (user_id, client_id)
select u.id, c.id
from auth.users u
cross join lateral (
    select id
    from public.clients
    where lower(trim(name)) in ('александр михнин', 'санечка мебельщик')
    order by created_at asc nulls last
    limit 1
) c
where lower(u.email) = lower('michnin.aleksandr.1@gmail.com')
on conflict do nothing;

-- Return only vehicles belonging to the client explicitly assigned above.
create or replace function public.get_my_service_vehicles()
returns setof public.vehicles
language sql
stable
security definer
set search_path = public
as $$
    select v.*
    from public.vehicles v
    join public.service_client_access a
      on a.client_id = v.client_id
    where a.user_id = auth.uid()
    order by v.created_at desc nulls last;
$$;

revoke all on function public.get_my_service_vehicles() from public;
grant execute on function public.get_my_service_vehicles() to authenticated;

-- Return service history only when the requested vehicle belongs to the
-- authenticated user's explicitly assigned client. No write operation is
-- exposed by this RPC.
create or replace function public.get_my_service_history(p_vehicle_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    allowed boolean;
    result jsonb;
begin
    select exists (
        select 1
        from public.vehicles v
        join public.service_client_access a
          on a.client_id = v.client_id
        where a.user_id = auth.uid()
          and v.id = p_vehicle_id
    )
    into allowed;

    if not allowed then
        raise exception 'Доступ к истории этого автомобиля запрещён';
    end if;

    select jsonb_build_object(
        'services',
        coalesce((
            select jsonb_agg(to_jsonb(s) order by s.service_date desc, s.service_time desc, s.created_at desc)
            from public.services s
            where s.vehicle_id = p_vehicle_id
        ), '[]'::jsonb),
        'items',
        coalesce((
            select jsonb_agg(to_jsonb(i) order by i.created_at asc)
            from public.service_items i
            join public.services s on s.id = i.service_id
            where s.vehicle_id = p_vehicle_id
        ), '[]'::jsonb),
        'parts',
        coalesce((
            select jsonb_agg(to_jsonb(p) order by p.created_at asc)
            from public.service_parts p
            join public.services s on s.id = p.service_id
            where s.vehicle_id = p_vehicle_id
        ), '[]'::jsonb)
    )
    into result;

    return result;
end;
$$;

revoke all on function public.get_my_service_history(uuid) from public;
grant execute on function public.get_my_service_history(uuid) to authenticated;

-- Sanечка still has no direct SELECT/INSERT/UPDATE/DELETE access to:
-- clients, vehicles, services, service_items, service_parts.
-- Both RPCs above are SECURITY DEFINER and perform the access check themselves.
