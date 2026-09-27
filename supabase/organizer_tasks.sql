-- Мамина среда: задачи органайзера.
-- Таблица и RLS уже применены в рабочем Supabase-проекте.

create table if not exists public.organizer_tasks (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
    task text not null,
    student_name text not null default '',
    class_name text not null default '',
    notes text not null default '',
    completed boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

alter table public.organizer_tasks enable row level security;

grant select, insert, update, delete on public.organizer_tasks to authenticated;

drop policy if exists "Organizer tasks owner select" on public.organizer_tasks;
create policy "Organizer tasks owner select"
on public.organizer_tasks for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "Organizer tasks owner insert" on public.organizer_tasks;
create policy "Organizer tasks owner insert"
on public.organizer_tasks for insert to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists "Organizer tasks owner update" on public.organizer_tasks;
create policy "Organizer tasks owner update"
on public.organizer_tasks for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists "Organizer tasks owner delete" on public.organizer_tasks;
create policy "Organizer tasks owner delete"
on public.organizer_tasks for delete to authenticated
using ((select auth.uid()) = user_id);

create index if not exists organizer_tasks_user_created_idx
on public.organizer_tasks (user_id, created_at desc);

create index if not exists organizer_tasks_user_student_idx
on public.organizer_tasks (user_id, student_name);

create index if not exists organizer_tasks_user_class_idx
on public.organizer_tasks (user_id, class_name);
