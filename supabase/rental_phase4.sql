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
