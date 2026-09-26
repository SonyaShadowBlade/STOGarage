-- STOGarage: fix persistent "изменено" marker for developer chat messages
-- Run once in Supabase SQL Editor if the current database was created
-- from an older version of messages.sql.

alter table public.developer_messages
    add column if not exists edited_at timestamptz;

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
                'edited_at', dm.edited_at
            )
            order by dm.created_at
        ),
        '[]'::jsonb
    )
    into msgs
    from public.developer_messages dm
    where dm.conversation_id = (c->>'id')::uuid;

    return jsonb_build_object(
        'conversation', c,
        'messages', msgs,
        'unread_for_client',
        exists (
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
    );
end;
$$;

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
        'edited_at', dm.edited_at
    )
    from public.developer_messages dm
    where public.is_staff()
      and dm.conversation_id = p_conversation_id
    order by dm.created_at;
$$;

grant execute on function public.developer_get_my_conversation() to authenticated;
grant execute on function public.developer_get_conversation_messages(uuid) to authenticated;
