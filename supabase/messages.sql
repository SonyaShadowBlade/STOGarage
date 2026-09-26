-- STOGarage: сообщения «клиент ↔ разработчик»
-- Выполнить целиком в Supabase -> SQL Editor.
-- ВАЖНО: этот файл соответствует текущему интерфейсу index.html.
-- Старую таблицу public.client_messages можно оставить — программа её не использует.

create extension if not exists pgcrypto;

create table if not exists public.developer_conversations (
    id uuid primary key default gen_random_uuid(),
    client_user_id uuid not null unique references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.developer_messages (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid not null references public.developer_conversations(id) on delete cascade,
    sender_user_id uuid not null references auth.users(id) on delete cascade,
    sender_side text not null check (sender_side in ('client','staff')),
    body text not null check (length(trim(body)) > 0 and length(body) <= 5000),
    is_read boolean not null default false,
    created_at timestamptz not null default now()
);

create index if not exists developer_messages_conversation_idx
    on public.developer_messages(conversation_id, created_at);

create index if not exists developer_messages_unread_idx
    on public.developer_messages(is_read, created_at);


-- Индивидуальная отметка прочтения.
-- Важно: прочтение Александром НЕ помечает сообщение прочитанным для папы,
-- и наоборот. У каждого сотрудника и клиента своё состояние чтения.
create table if not exists public.developer_conversation_reads (
    conversation_id uuid not null references public.developer_conversations(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    last_read_at timestamptz not null default now(),
    primary key (conversation_id, user_id)
);

create index if not exists developer_conversation_reads_user_idx
    on public.developer_conversation_reads(user_id, conversation_id);

alter table public.developer_conversation_reads enable row level security;

drop policy if exists "developer_conversation_reads_select_own" on public.developer_conversation_reads;
create policy "developer_conversation_reads_select_own"
on public.developer_conversation_reads
for select to authenticated
using (user_id = auth.uid());

drop policy if exists "developer_conversation_reads_insert_own" on public.developer_conversation_reads;
create policy "developer_conversation_reads_insert_own"
on public.developer_conversation_reads
for insert to authenticated
with check (user_id = auth.uid());

drop policy if exists "developer_conversation_reads_update_own" on public.developer_conversation_reads;
create policy "developer_conversation_reads_update_own"
on public.developer_conversation_reads
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

revoke delete on public.developer_conversation_reads from authenticated;

alter table public.developer_conversations enable row level security;
alter table public.developer_messages enable row level security;

drop policy if exists "developer_conversations_select" on public.developer_conversations;
create policy "developer_conversations_select"
on public.developer_conversations
for select to authenticated
using (
    client_user_id = auth.uid()
    or public.is_staff()
);

drop policy if exists "developer_conversations_insert" on public.developer_conversations;
create policy "developer_conversations_insert"
on public.developer_conversations
for insert to authenticated
with check (
    client_user_id = auth.uid()
    and not public.is_staff()
);

drop policy if exists "developer_conversations_update" on public.developer_conversations;
create policy "developer_conversations_update"
on public.developer_conversations
for update to authenticated
using (
    client_user_id = auth.uid()
    or public.is_staff()
)
with check (
    client_user_id = auth.uid()
    or public.is_staff()
);

drop policy if exists "developer_messages_select" on public.developer_messages;
create policy "developer_messages_select"
on public.developer_messages
for select to authenticated
using (
    public.is_staff()
    or exists (
        select 1
        from public.developer_conversations c
        where c.id = conversation_id
          and c.client_user_id = auth.uid()
    )
);

drop policy if exists "developer_messages_insert" on public.developer_messages;
create policy "developer_messages_insert"
on public.developer_messages
for insert to authenticated
with check (
    sender_user_id = auth.uid()
    and (
        public.is_staff()
        or (
            sender_side = 'client'
            and exists (
                select 1
                from public.developer_conversations c
                where c.id = conversation_id
                  and c.client_user_id = auth.uid()
            )
        )
    )
);

revoke delete on public.developer_conversations from authenticated;
revoke delete on public.developer_messages from authenticated;

-- Обновляем дату последнего сообщения.
create or replace function public.developer_touch_conversation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    update public.developer_conversations
    set updated_at = new.created_at
    where id = new.conversation_id;
    return new;
end;
$$;

drop trigger if exists developer_touch_conversation_trigger on public.developer_messages;
create trigger developer_touch_conversation_trigger
after insert on public.developer_messages
for each row execute function public.developer_touch_conversation();

-- Клиент получает свою единственную переписку.
create or replace function public.developer_get_my_conversation()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    c jsonb;
    msgs jsonb;
begin
    select jsonb_build_object(
        'id', dc.id,
        'client_user_id', dc.client_user_id,
        'created_at', dc.created_at,
        'updated_at', dc.updated_at
    )
    into c
    from public.developer_conversations dc
    where dc.client_user_id = auth.uid()
    limit 1;

    if c is null then
        return jsonb_build_object(
            'conversation', null,
            'messages', '[]'::jsonb
        );
    end if;

    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'id', dm.id,
                'sender_side', dm.sender_side,
                'body', dm.body,
                'is_read', dm.is_read,
                'created_at', dm.created_at,
                'edited_at', dm.edited_at,
                'message_status',
                case
                    when dm.sender_side = 'client' then
                        case
                            when exists (
                                select 1
                                from public.developer_conversation_reads rr
                                where rr.conversation_id = dm.conversation_id
                                  and rr.user_id <> auth.uid()
                                  and rr.last_read_at >= dm.created_at
                            ) then 'read'
                            else 'delivered'
                        end
                    else null
                end
            )
            order by dm.created_at
        ),
        '[]'::jsonb
    )
    into msgs
    from public.developer_messages dm
    where dm.conversation_id = (c->>'id')::uuid;

    return jsonb_build_object(
        'conversation',
        c || null,
        'messages', msgs,
        'unread_for_client',
        case
            when c is null then false
            else exists (
                select 1
                from public.developer_messages dm
                left join public.developer_conversation_reads r
                    on r.conversation_id = dm.conversation_id
                   and r.user_id = auth.uid()
                where dm.conversation_id = (c->>'id')::uuid
                  and dm.sender_side = 'staff'
                  and (
                      r.last_read_at is null
                      or dm.created_at > r.last_read_at
                  )
            )
        end,
        'unread_for_client_count',
        case
            when c is null then 0
            else (
                select count(*)::int
                from public.developer_messages dm
                left join public.developer_conversation_reads r
                    on r.conversation_id = dm.conversation_id
                   and r.user_id = auth.uid()
                where dm.conversation_id = (c->>'id')::uuid
                  and dm.sender_side = 'staff'
                  and (
                      r.last_read_at is null
                      or dm.created_at > r.last_read_at
                  )
            )
        end
    );
end;
$$;

-- Клиент отправляет сообщение. Переписка создаётся автоматически.
create or replace function public.developer_send_message(p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    conversation_id uuid;
    message_id uuid;
begin
    if auth.uid() is null then
        raise exception 'Требуется авторизация';
    end if;

    if public.is_staff() then
        raise exception 'Для сотрудника используется ответ в обращении';
    end if;

    if p_body is null or length(trim(p_body)) = 0 then
        raise exception 'Сообщение не может быть пустым';
    end if;

    if length(p_body) > 5000 then
        raise exception 'Сообщение слишком длинное';
    end if;

    insert into public.developer_conversations(client_user_id)
    values (auth.uid())
    on conflict (client_user_id)
    do update set updated_at = now()
    returning id into conversation_id;

    insert into public.developer_messages(
        conversation_id,
        sender_user_id,
        sender_side,
        body,
        is_read
    )
    values (
        conversation_id,
        auth.uid(),
        'client',
        trim(p_body),
        false
    )
    returning id into message_id;

    return jsonb_build_object(
        'conversation_id', conversation_id,
        'message_id', message_id
    );
end;
$$;

-- Сотрудники получают список всех клиентов с последним сообщением.
create or replace function public.developer_get_staff_conversations()
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
    select jsonb_build_object(
        'conversation',
        jsonb_build_object(
            'id', c.id,
            'client_user_id', c.client_user_id,
            'client_name',
                coalesce(
                    (
                        select nullif(trim(cl2.name), '')
                        from public.service_client_access sca
                        join public.clients cl2 on cl2.id = sca.client_id
                        where sca.user_id = c.client_user_id
                        order by sca.created_at asc nulls last
                        limit 1
                    ),
                    (
                        select nullif(trim(cl.name), '')
                        from public.rental_vehicle_access rva
                        join public.vehicles rv on rv.id = rva.vehicle_id
                        join public.clients cl on cl.id = rv.client_id
                        where rva.user_id = c.client_user_id
                        order by rva.created_at asc nulls last
                        limit 1
                    ),
                    nullif(u.raw_user_meta_data->>'name',''),
                    nullif(u.raw_user_meta_data->>'full_name',''),
                    'Клиент'
                ),
            'client_email', u.email,
            'unread_for_staff',
                exists (
                    select 1
                    from public.developer_messages um
                    left join public.developer_conversation_reads r
                        on r.conversation_id = um.conversation_id
                       and r.user_id = auth.uid()
                    where um.conversation_id = c.id
                      and um.sender_side = 'client'
                      and (
                          r.last_read_at is null
                          or um.created_at > r.last_read_at
                      )
                ),
            'unread_for_staff_count',
                (
                    select count(*)::int
                    from public.developer_messages um
                    left join public.developer_conversation_reads r
                        on r.conversation_id = um.conversation_id
                       and r.user_id = auth.uid()
                    where um.conversation_id = c.id
                      and um.sender_side = 'client'
                      and (
                          r.last_read_at is null
                          or um.created_at > r.last_read_at
                      )
                ),
            'updated_at', c.updated_at
        ),
        'last_message',
        (
            select jsonb_build_object(
                'body', lm.body,
                'sender_side', lm.sender_side,
                'created_at', lm.created_at
            )
            from public.developer_messages lm
            where lm.conversation_id = c.id
            order by lm.created_at desc
            limit 1
        )
    )
    from public.developer_conversations c
    join auth.users u on u.id = c.client_user_id
    where public.is_staff()
    order by c.updated_at desc;
$$;

-- Сотрудник открывает конкретную переписку.
create or replace function public.developer_get_conversation_messages(p_conversation_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
    select jsonb_build_object(
        'id', dm.id,
        'sender_side', dm.sender_side,
        'body', dm.body,
        'is_read', dm.is_read,
        'created_at', dm.created_at,
        'edited_at', dm.edited_at,
        'message_status',
        case
            when dm.sender_side = 'staff' then
                case
                    when exists (
                        select 1
                        from public.developer_conversation_reads rr
                        join public.developer_conversations cc
                          on cc.id = rr.conversation_id
                        where rr.conversation_id = dm.conversation_id
                          and rr.user_id = cc.client_user_id
                          and rr.last_read_at >= dm.created_at
                    ) then 'read'
                    else 'delivered'
                end
            else null
        end
    )
    from public.developer_messages dm
    where public.is_staff()
      and dm.conversation_id = p_conversation_id
    order by dm.created_at;
$$;

-- Помечаем входящие сообщения клиента прочитанными.
create or replace function public.developer_mark_read(p_conversation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if auth.uid() is null then
        return;
    end if;

    if not (
        public.is_staff()
        or exists (
            select 1
            from public.developer_conversations c
            where c.id = p_conversation_id
              and c.client_user_id = auth.uid()
        )
    ) then
        return;
    end if;

    insert into public.developer_conversation_reads(
        conversation_id,
        user_id,
        last_read_at
    )
    values (
        p_conversation_id,
        auth.uid(),
        now()
    )
    on conflict (conversation_id, user_id)
    do update set last_read_at = excluded.last_read_at;
end;
$$;

-- Сотрудник отвечает клиенту.
create or replace function public.developer_staff_reply(
    p_conversation_id uuid,
    p_body text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    message_id uuid;
begin
    if not public.is_staff() then
        raise exception 'Доступ разрешён только сотрудникам';
    end if;

    if p_body is null or length(trim(p_body)) = 0 then
        raise exception 'Ответ не может быть пустым';
    end if;

    if length(p_body) > 5000 then
        raise exception 'Ответ слишком длинный';
    end if;

    if not exists (
        select 1
        from public.developer_conversations
        where id = p_conversation_id
    ) then
        raise exception 'Обращение не найдено';
    end if;

    insert into public.developer_messages(
        conversation_id,
        sender_user_id,
        sender_side,
        body,
        is_read
    )
    values (
        p_conversation_id,
        auth.uid(),
        'staff',
        trim(p_body),
        true
    )
    returning id into message_id;

    return jsonb_build_object(
        'message_id', message_id
    );
end;
$$;



-- Редактирование собственных сообщений.
-- Клиент может изменить только своё сообщение, сотрудник — только своё.
alter table public.developer_messages
    add column if not exists edited_at timestamptz;

create or replace function public.developer_edit_message(
    p_message_id uuid,
    p_body text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    message_row public.developer_messages;
begin
    if auth.uid() is null then
        raise exception 'Требуется авторизация';
    end if;

    if p_body is null or length(trim(p_body)) = 0 then
        raise exception 'Сообщение не может быть пустым';
    end if;

    if length(p_body) > 5000 then
        raise exception 'Сообщение слишком длинное';
    end if;

    select *
    into message_row
    from public.developer_messages
    where id = p_message_id
      and sender_user_id = auth.uid();

    if not found then
        raise exception 'Можно изменять только свои сообщения';
    end if;

    update public.developer_messages
    set body = trim(p_body),
        edited_at = now()
    where id = p_message_id
    returning * into message_row;

    return jsonb_build_object(
        'id', message_row.id,
        'conversation_id', message_row.conversation_id,
        'sender_side', message_row.sender_side,
        'body', message_row.body,
        'is_read', message_row.is_read,
        'created_at', message_row.created_at,
        'edited_at', message_row.edited_at
    );
end;
$$;

revoke all on function public.developer_edit_message(uuid,text) from public;
grant execute on function public.developer_edit_message(uuid,text) to authenticated;

revoke all on function public.developer_get_my_conversation() from public;
revoke all on function public.developer_send_message(text) from public;
revoke all on function public.developer_get_staff_conversations() from public;
revoke all on function public.developer_get_conversation_messages(uuid) from public;
revoke all on function public.developer_mark_read(uuid) from public;
revoke all on function public.developer_staff_reply(uuid,text) from public;

grant execute on function public.developer_get_my_conversation() to authenticated;
grant execute on function public.developer_send_message(text) to authenticated;
grant execute on function public.developer_get_staff_conversations() to authenticated;
grant execute on function public.developer_get_conversation_messages(uuid) to authenticated;
grant execute on function public.developer_mark_read(uuid) to authenticated;
grant execute on function public.developer_staff_reply(uuid,text) to authenticated;
