-- STOGarage — заправки привязываются к конкретной поездке
-- Выполнить целиком в Supabase -> SQL Editor один раз.
--
-- ВАЖНО:
-- 1) Все существующие заправки Санечки удаляются, как было запрошено.
-- 2) Новая заправка должна иметь trip_id — то есть принадлежать поездке.
-- 3) Заправку можно менять и удалять только владельцу записи/сотруднику.

alter table public.rental_fuel
    add column if not exists trip_id uuid;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'rental_fuel_trip_id_fkey'
          and conrelid = 'public.rental_fuel'::regclass
    ) then
        alter table public.rental_fuel
            add constraint rental_fuel_trip_id_fkey
            foreign key (trip_id)
            references public.rental_trips(id)
            on delete cascade;
    end if;
end
$$;

create index if not exists rental_fuel_trip_id_idx
    on public.rental_fuel(trip_id);

-- Удаляем все старые заправки Санечки.
delete from public.rental_fuel rf
using auth.users u
where rf.user_id = u.id
  and lower(coalesce(u.email, '')) = lower('michnin.aleksandr.1@gmail.com');

-- Защита изменения и удаления заправок.
drop policy if exists "rental_fuel_update_own" on public.rental_fuel;
create policy "rental_fuel_update_own"
on public.rental_fuel
for update
to authenticated
using (
    (
        user_id = auth.uid()
        and can_access_rental_vehicle(vehicle_id)
    )
    or is_staff()
)
with check (
    (
        user_id = auth.uid()
        and can_access_rental_vehicle(vehicle_id)
    )
    or is_staff()
);

drop policy if exists "rental_fuel_delete_own" on public.rental_fuel;
create policy "rental_fuel_delete_own"
on public.rental_fuel
for delete
to authenticated
using (
    (
        user_id = auth.uid()
        and can_access_rental_vehicle(vehicle_id)
    )
    or is_staff()
);
