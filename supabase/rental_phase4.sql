-- Аренда: дополнительные поля времени и валюты
-- Выполнить один раз в Supabase SQL Editor.

alter table public.rental_trips
    add column if not exists trip_time time;

alter table public.rental_fuel
    add column if not exists fuel_time time;

alter table public.rental_fuel
    add column if not exists currency text not null default 'BYN';

alter table public.rental_fuel
    add column if not exists price_per_liter numeric;

update public.rental_fuel
set price_per_liter = case
    when liters is not null and liters > 0 then cost / liters
    else null
end
where price_per_liter is null;


-- Поездки: конечный пробег может быть пустым у активной поездки.
alter table public.rental_trips
    alter column end_mileage drop not null;

-- Поездки: активная или завершённая.
alter table public.rental_trips
    add column if not exists status text not null default 'active';

update public.rental_trips
set status = case
    when end_mileage is null then 'active'
    else 'completed'
end
where status is null
   or status not in ('active', 'completed');

-- Время поездки. Если колонка уже есть, команда ничего не меняет.
alter table public.rental_trips
    add column if not exists trip_time time;
