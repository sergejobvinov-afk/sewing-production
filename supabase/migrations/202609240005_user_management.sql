-- Показывает администратору логины пользователей без раскрытия паролей.
create or replace function public.get_managed_users()
returns jsonb language plpgsql stable security definer set search_path=public,auth as $$
declare v_users jsonb;
begin
  if public.current_app_role()<>'admin' then raise exception 'Только администратор может управлять пользователями'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'pin',p.id,'name',p.display_name,'role',p.role,
    'login',case when u.email like '%@users.sewing.local' then split_part(u.email,'@',1) else u.email end,
    'active',case when p.active then 'Да' else 'Нет' end
  ) order by p.display_name),'[]'::jsonb) into v_users
  from public.profiles p left join auth.users u on u.id=p.id;
  return jsonb_build_object('success',true,'users',v_users);
end; $$;

revoke all on function public.get_managed_users() from public,anon;
grant execute on function public.get_managed_users() to authenticated;
