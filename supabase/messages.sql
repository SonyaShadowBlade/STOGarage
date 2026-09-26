-- STOGarage: система сообщений клиентов
-- Выполнить целиком в Supabase -> SQL Editor.
-- Безопасность: клиент видит/создает только свои сообщения;
-- сотрудники (admin/father) видят все и могут отвечать.

create table if not exists public.client_messages (
    id uuid primary key default gen_random_uuid(),
    client_user_id uuid not null references auth.users(id) on delete cascade,
    sender_user_id uuid not null references auth.users(id) on delete cascade,
    sender_role text not null default 'client',
    parent_id uuid null references public.client_messages(id) on delete cascade,
    message text not null check (length(trim(message)) > 0),
    is_read boolean not null default false,
    created_at timestamptz not null default now()
);

create index if not exists client_messages_client_user_id_idx
    on public.client_messages(client_user_id);

create index if not exists client_messages_parent_id_idx
    on public.client_messages(parent_id);

create index if not exists client_messages_created_at_idx
    on public.client_messages(created_at desc);

alter table public.client_messages enable row level security;

drop policy if exists "client_messages_select_own_or_staff" on public.client_messages;
create policy "client_messages_select_own_or_staff"
on public.client_messages
for select
to authenticated
using (
    client_user_id = auth.uid()
    or public.is_staff()
);

drop policy if exists "client_messages_insert_client_or_staff" on public.client_messages;
create policy "client_messages_insert_client_or_staff"
on public.client_messages
for insert
to authenticated
with check (
    sender_user_id = auth.uid()
    and (
        (
            client_user_id = auth.uid()
            and not public.is_staff()
        )
        or public.is_staff()
    )
);

drop policy if exists "client_messages_update_staff_or_own_read" on public.client_messages;
create policy "client_messages_update_staff_or_own_read"
on public.client_messages
for update
to authenticated
using (
    public.is_staff()
    or client_user_id = auth.uid()
)
with check (
    public.is_staff()
    or client_user_id = auth.uid()
);

-- Клиентам не разрешаем удалять историю сообщений.
revoke delete on public.client_messages from authenticated;

-- Для удобной проверки непрочитанных сообщений сотрудниками.
create or replace function public.get_unread_client_messages_count()
returns bigint
language sql
stable
security definer
set search_path = public
as $$
    select count(*)
    from public.client_messages
    where public.is_staff()
      and is_read = false
      and sender_user_id <> auth.uid();
$$;

revoke all on function public.get_unread_client_messages_count() from public;
grant execute on function public.get_unread_client_messages_count() to authenticated;

-- Пометка сообщений конкретного клиента прочитанными сотрудником.
create or replace function public.mark_client_messages_read(p_client_user_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
    update public.client_messages
    set is_read = true
    where public.is_staff()
      and client_user_id = p_client_user_id
      and sender_user_id <> auth.uid()
      and is_read = false;
$$;

revoke all on function public.mark_client_messages_read(uuid) from public;
grant execute on function public.mark_client_messages_read(uuid) to authenticated;

-- Санечка уже известен системе.
-- Для будущих клиентов достаточно передать их auth.users.id
-- как client_user_id при первом сообщении.
