-- Исправление для уже развернутой функции: в profiles нет столбца created_by.
create or replace function public.create_managed_profile(p_profile_id uuid,p_name text,p_role public.app_role)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if public.current_app_role()<>'admin' then raise exception 'Только администратор может управлять пользователями'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Введите имя'; end if;
  insert into public.profiles(id,display_name,role,active)
    values(p_profile_id,trim(p_name),p_role,true);
  return jsonb_build_object('success',true);
end; $$;

revoke all on function public.create_managed_profile(uuid,text,public.app_role) from public,anon;
grant execute on function public.create_managed_profile(uuid,text,public.app_role) to authenticated;
