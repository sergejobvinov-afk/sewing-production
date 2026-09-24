-- Смена собственного PIN доступна активному пользователю; чужого — только администратору.
create or replace function public.reset_user_pin(p_profile_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_actor uuid := auth.uid();
  v_role public.app_role;
begin
  if p_pin !~ '^\d{6}$' then
    raise exception 'PIN должен содержать 6 цифр';
  end if;

  select role into v_role
  from public.profiles
  where id = v_actor and active = true;

  if v_actor is null or v_role is null then
    raise exception 'Требуется вход в систему';
  end if;
  if p_profile_id <> v_actor and v_role <> 'admin' then
    raise exception 'Только администратор может менять PIN другого пользователя';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile_id) then
    raise exception 'Пользователь не найден';
  end if;

  update auth.users
  set encrypted_password = extensions.crypt(p_pin, extensions.gen_salt('bf')),
      updated_at = now()
  where id = p_profile_id;

  if not found then raise exception 'Учётная запись не найдена'; end if;
  return jsonb_build_object('success', true, 'message', 'PIN изменён');
end;
$$;

revoke all on function public.reset_user_pin(uuid,text) from public,anon;
grant execute on function public.reset_user_pin(uuid,text) to authenticated;
