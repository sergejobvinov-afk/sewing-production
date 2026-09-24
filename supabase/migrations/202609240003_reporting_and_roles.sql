-- Отчёты и управление доступом для Supabase pilot.
-- Все функции выполняют проверку активного профиля на сервере.

create or replace function public.get_dashboard_data()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_role public.app_role; v_finance jsonb; v_production jsonb; v_sewers jsonb;
begin
  select public.current_app_role() into v_role;
  if v_role not in ('admin','master','accountant') then raise exception 'Недостаточно прав'; end if;
  select jsonb_build_object(
    'issuedPacks',count(*) filter(where status in ('issued','partially_accepted')),
    'inProgressPacks',count(*) filter(where status in ('issued','partially_accepted')),
    'acceptedPacks',count(*) filter(where status='accepted'),
    'totalQty',coalesce(sum(quantity) filter(where status<>'annulled'),0),
    'inProgressQty',coalesce(sum(quantity) filter(where status in ('issued','partially_accepted')),0),
    'totalOtk',coalesce((select sum(accepted_qty) from public.pack_operations),0),'defect',0
  ) into v_production from public.packs;
  if v_role='master' then
    v_finance:=jsonb_build_object('revenue',0,'zp',0,'profit',0,'margin',0);
  else
    select jsonb_build_object(
      'revenue',coalesce(sum(po.accepted_qty*oc.client_price),0),
      'zp',coalesce(sum(po.accepted_qty*po.sewer_price),0),
      'profit',coalesce(sum(po.accepted_qty*(oc.client_price-po.sewer_price)),0),
      'margin',case when coalesce(sum(po.accepted_qty*oc.client_price),0)=0 then 0 else
        round(100*sum(po.accepted_qty*(oc.client_price-po.sewer_price))/sum(po.accepted_qty*oc.client_price),1) end
    ) into v_finance from public.pack_operations po
    left join public.packs p on p.id=po.pack_id
    left join public.operation_catalog oc on oc.model=p.model and oc.operation_name=po.operation_name;
  end if;
  select coalesce(jsonb_object_agg(sewer_name,stats),'{}'::jsonb) into v_sewers from (
    select coalesce(sewer_name,'Не назначена') sewer_name,
      jsonb_build_object('items',sum(accepted_qty),'zp',case when v_role='master' then 0 else sum(accepted_qty*sewer_price) end) stats
    from public.pack_operations group by coalesce(sewer_name,'Не назначена')
  ) s;
  return jsonb_build_object('success',true,'finance',v_finance,'production',v_production,'sewers',v_sewers);
end; $$;

create or replace function public.get_my_packs()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_profile public.profiles%rowtype; v_packs jsonb;
begin
  select * into v_profile from public.profiles where id=auth.uid() and active;
  if not found then raise exception 'Профиль пользователя не активирован'; end if;
  select coalesce(jsonb_agg(row_data order by sort_date desc),'[]'::jsonb) into v_packs from (
    select jsonb_build_object('id',p.id,'model',p.model,'size',p.size,'color',p.color,'qty',p.quantity,
      'passport',p.passport_no,'status',case when p.status='accepted' then 'Принято' else 'Выдано' end,
      'issuedDate',min(po.issued_at),'acceptedDate',max(po.accepted_at),'otkQty',max(po.accepted_qty)) row_data,
      max(coalesce(po.accepted_at,po.issued_at)) sort_date
    from public.packs p join public.pack_operations po on po.pack_id=p.id
    where p.status in ('issued','partially_accepted','accepted') and
      (v_profile.role in ('admin','master','accountant') or po.sewer_id=auth.uid() or po.sewer_name=v_profile.display_name)
    group by p.id
  ) q;
  return jsonb_build_object('success',true,'packs',v_packs);
end; $$;

create or replace function public.get_managed_users()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_users jsonb;
begin
  if public.current_app_role()<>'admin' then raise exception 'Только администратор может управлять пользователями'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('pin',id,'name',display_name,'role',role,
    'active',case when active then 'Да' else 'Нет' end) order by display_name),'[]'::jsonb)
    into v_users from public.profiles;
  return jsonb_build_object('success',true,'users',v_users);
end; $$;

create or replace function public.toggle_profile_active(p_profile_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_active boolean;
begin
  if public.current_app_role()<>'admin' then raise exception 'Только администратор может управлять пользователями'; end if;
  if p_profile_id=auth.uid() then raise exception 'Нельзя отключить собственную учётную запись'; end if;
  update public.profiles set active=not active,updated_at=now() where id=p_profile_id returning active into v_active;
  if not found then raise exception 'Пользователь не найден'; end if;
  return jsonb_build_object('success',true,'message',case when v_active then 'Пользователь включён' else 'Пользователь выключен' end);
end; $$;

revoke all on function public.get_dashboard_data() from public,anon;
revoke all on function public.get_my_packs() from public,anon;
revoke all on function public.get_managed_users() from public,anon;
revoke all on function public.toggle_profile_active(uuid) from public,anon;
grant execute on function public.get_dashboard_data() to authenticated;
grant execute on function public.get_my_packs() to authenticated;
grant execute on function public.get_managed_users() to authenticated;
grant execute on function public.toggle_profile_active(uuid) to authenticated;
