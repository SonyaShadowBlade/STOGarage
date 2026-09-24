-- Автоматические резервные копии СТО.
-- Одна успешная копия в календарный день, хранение 30 дней.
-- Данные копии находятся в отдельной таблице и защищены RLS.

create table if not exists public.automatic_backups (
    id uuid primary key default gen_random_uuid(),
    backup_day date not null unique,
    created_at timestamptz not null default now(),
    app_version text,
    backup_format text not null default '1.0',
    verified boolean not null default false,
    counts jsonb,
    backup_data jsonb not null
);

create index if not exists idx_automatic_backups_created_at
on public.automatic_backups(created_at desc);

alter table public.automatic_backups enable row level security;

drop policy if exists "authenticated_automatic_backups" on public.automatic_backups;

create policy "authenticated_automatic_backups"
on public.automatic_backups
for all
to authenticated
using (true)
with check (true);

revoke all on table public.automatic_backups from anon;

grant select, insert, update, delete
on table public.automatic_backups
to authenticated;