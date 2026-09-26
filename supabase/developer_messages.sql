-- STOGarage: обращения клиентов разработчику
-- Выполнить один раз в Supabase SQL Editor.

create table if not exists public.developer_conversations (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    client_name text,
    client_email text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unread_for_staff boolean not null default false,
    unread_for_client boolean not null default false
);

create unique index if not exists developer_conversations_user_uidx
    on public.developer_conversations(user_id);

create index if not exists developer_conversations_updated_idx
    on public.developer_conversations(updated_at desc);

create table if not exists public.developer_messages (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid not null references public.developer_conversations(id) on delete cascade,
    sender_user_id uuid not null references auth.users(id) on delete cascade,
    sender_side text not null check (sender_side in ('client','staff')),
    body text not null,
    created_at timestamptz not null default now()
);

create index if not exists developer_messages_conversation_idx
    on public.developer_messages(conversation_id, created_at);

alter table public.developer_conversations enable row level security;
alter table public.developer_messages enable row level security;

drop policy if exists "developer_conversations_none" on public.developer_conversations;
create policy "developer_conversations_none"
on public.developer_conversations
for all to authenticated
using (false)
with check (false);

drop policy if exists "developer_messages_none" on public.developer_messages;
create policy "developer_messages_none"
on public.developer_messages
for all to authenticated
using (false)
with check (false);

revoke all on public.developer_conversations from authenticated;
revoke all on public.developer_messages from authenticated;

create or replace function public.developer_is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(public.current_user_role(), '') in ('admin', 'father');
$$;

create or replace function public.developer_send_message(p_body text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    conversation_id uuid;
    message_text text;
    current_name text;
    current_email text;
begin
    message_text := btrim(coalesce(p_body, ''));

    if message_text = '' then
        raise exception 'Сообщение не может быть пустым';
    end if;

    if length(message_text) > 5000 then
        raise exception 'Сообщение слишком длинное';
    end if;

    if public.developer_is_staff() then
        raise exception 'Сотрудник не может создавать обращение как клиент';
    end if;

    select coalesce(
        nullif(btrim(coalesce(raw_user_meta_data->>'full_name','')), ''),
        nullif(btrim(coalesce(raw_user_meta_data->>'name','')), ''),
        split_part(coalesce(email,''), '@', 1)
    ),
    email
    into current_name, current_email
    from auth.users
    where id = auth.uid();

    insert into public.developer_conversations (
        user_id, client_name, client_email, updated_at,
        unread_for_staff, unread_for_client
    )
    values (
        auth.uid(), current_name, current_email, now(),
        true, false
    )
    on conflict (user_id)
    do update set
        client_name = excluded.client_name,
        client_email = excluded.client_email,
        updated_at = now(),
        unread_for_staff = true
    returning id into conversation_id;

    insert into public.developer_messages (
        conversation_id, sender_user_id, sender_side, body
    )
    values (
        conversation_id, auth.uid(), 'client', message_text
    );

    return conversation_id;
end;
$$;

create or replace function public.developer_get_my_conversation()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(
        (
            select jsonb_build_object(
                'conversation', to_jsonb(c),
                'messages', coalesce(
                    (
                        select jsonb_agg(to_jsonb(m) order by m.created_at asc)
                        from public.developer_messages m
                        where m.conversation_id = c.id
                    ),
                    '[]'::jsonb
                )
            )
            from public.developer_conversations c
            where c.user_id = auth.uid()
        ),
        jsonb_build_object(
            'conversation', null,
            'messages', '[]'::jsonb
        )
    );
$$;

create or replace function public.developer_get_staff_conversations()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    result jsonb;
begin
    if not public.developer_is_staff() then
        raise exception 'Доступ разрешён только сотрудникам';
    end if;

    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'conversation', to_jsonb(c),
                'last_message', (
                    select to_jsonb(m)
                    from public.developer_messages m
                    where m.conversation_id = c.id
                    order by m.created_at desc
                    limit 1
                )
            )
            order by c.updated_at desc
        ),
        '[]'::jsonb
    )
    into result
    from public.developer_conversations c;

    return result;
end;
$$;

create or replace function public.developer_get_conversation_messages(p_conversation_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if not public.developer_is_staff()
       and not exists (
           select 1
           from public.developer_conversations c
           where c.id = p_conversation_id
             and c.user_id = auth.uid()
       ) then
        raise exception 'Доступ к этой переписке запрещён';
    end if;

    return coalesce(
        (
            select jsonb_agg(to_jsonb(m) order by m.created_at asc)
            from public.developer_messages m
            where m.conversation_id = p_conversation_id
        ),
        '[]'::jsonb
    );
end;
$$;

create or replace function public.developer_staff_reply(
    p_conversation_id uuid,
    p_body text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    message_text text;
begin
    message_text := btrim(coalesce(p_body, ''));

    if not public.developer_is_staff() then
        raise exception 'Доступ разрешён только сотрудникам';
    end if;

    if message_text = '' then
        raise exception 'Ответ не может быть пустым';
    end if;

    if length(message_text) > 5000 then
        raise exception 'Ответ слишком длинный';
    end if;

    if not exists (
        select 1
        from public.developer_conversations
        where id = p_conversation_id
    ) then
        raise exception 'Переписка не найдена';
    end if;

    insert into public.developer_messages (
        conversation_id, sender_user_id, sender_side, body
    )
    values (
        p_conversation_id, auth.uid(), 'staff', message_text
    );

    update public.developer_conversations
    set updated_at = now(),
        unread_for_staff = false,
        unread_for_client = true
    where id = p_conversation_id;

    return true;
end;
$$;

create or replace function public.developer_mark_read(p_conversation_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if public.developer_is_staff() then
        update public.developer_conversations
        set unread_for_staff = false
        where id = p_conversation_id;
    else
        update public.developer_conversations
        set unread_for_client = false
        where id = p_conversation_id
          and user_id = auth.uid();
    end if;

    return true;
end;
$$;

revoke all on function public.developer_is_staff() from public;
revoke all on function public.developer_send_message(text) from public;
revoke all on function public.developer_get_my_conversation() from public;
revoke all on function public.developer_get_staff_conversations() from public;
revoke all on function public.developer_get_conversation_messages(uuid) from public;
revoke all on function public.developer_staff_reply(uuid,text) from public;
revoke all on function public.developer_mark_read(uuid) from public;

grant execute on function public.developer_is_staff() to authenticated;
grant execute on function public.developer_send_message(text) to authenticated;
grant execute on function public.developer_get_my_conversation() to authenticated;
grant execute on function public.developer_get_staff_conversations() to authenticated;
grant execute on function public.developer_get_conversation_messages(uuid) to authenticated;
grant execute on function public.developer_staff_reply(uuid,text) to authenticated;
grant execute on function public.developer_mark_read(uuid) to authenticated;
