-- STOGarage: история редактирования сообщений
-- Выполнить целиком в Supabase -> SQL Editor.

alter table public.client_messages
    add column if not exists edited_at timestamptz null;

create index if not exists client_messages_edited_at_idx
    on public.client_messages(edited_at);

create or replace function public.mark_client_message_edited()
returns trigger
language plpgsql
as $$
begin
    if new.message is distinct from old.message then
        new.edited_at = now();
    end if;
    return new;
end;
$$;

drop trigger if exists client_messages_mark_edited
on public.client_messages;

create trigger client_messages_mark_edited
before update of message on public.client_messages
for each row
execute function public.mark_client_message_edited();

-- После выполнения:
-- если текст сообщения изменяли хотя бы один раз,
-- edited_at будет заполнен, и программа сможет показать подпись «изменено».
