-- Accounts made with "Continue with Google" carry the person's name as `full_name` / `name`
-- in their metadata, not `display_name`. Use it for the new profile when there is one.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
    insert into public.profiles (id, display_name)
    values (
        new.id,
        left(coalesce(nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
                      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
                      nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
                      split_part(new.email, '@', 1), 'Player'), 40)
    )
    on conflict (id) do nothing;
    return new;
end;
$$;
