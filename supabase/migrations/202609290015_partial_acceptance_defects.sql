-- Частичная приемка, брак и контролируемая приемка сверх выданного количества.
alter table public.pack_operations
  add column if not exists defect_qty integer not null default 0;

alter table public.pack_operations
  drop constraint if exists pack_operations_accepted_qty_check;
alter table public.pack_operations
  drop constraint if exists pack_operations_defect_qty_check;
alter table public.pack_operations
  add constraint pack_operations_accepted_qty_nonnegative check (accepted_qty >= 0),
  add constraint pack_operations_defect_qty_check check (defect_qty >= 0);

create or replace function public.accept_pack(p_pack_id text, p_operations jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_pack public.packs%rowtype; v_item jsonb; v_name text; v_qty integer; v_defect integer;
  v_status public.pack_status; v_operation public.pack_operations%rowtype;
begin
  perform public.require_management_role();
  select * into v_pack from public.packs where id=p_pack_id for update;
  if not found then raise exception 'Пачка не найдена'; end if;
  if v_pack.status not in ('issued','partially_accepted') then raise exception 'Пачка не находится в пошиве'; end if;
  if jsonb_typeof(p_operations)<>'array' or jsonb_array_length(p_operations)=0 then raise exception 'Не указано количество приёмки'; end if;

  for v_item in select value from jsonb_array_elements(p_operations) loop
    v_name:=nullif(trim(v_item->>'operationName'),'');
    v_qty:=coalesce((v_item->>'acceptedQty')::integer,0);
    v_defect:=coalesce((v_item->>'defectQty')::integer,0);
    if v_name is null then raise exception 'Не указана операция'; end if;
    if v_qty<0 or v_defect<0 or v_qty+v_defect<=0 then
      raise exception 'Количество годных изделий или брака должно быть больше нуля';
    end if;
    select * into v_operation from public.pack_operations
      where pack_id=v_pack.id and operation_name=v_name for update;
    if not found then raise exception 'Операция % не найдена',v_name; end if;
    update public.pack_operations set accepted_qty=accepted_qty+v_qty,defect_qty=defect_qty+v_defect,
      accepted_at=now() where id=v_operation.id;
  end loop;

  if exists(select 1 from public.pack_operations where pack_id=v_pack.id and issued_qty>0
    and accepted_qty+defect_qty<issued_qty) then v_status:='partially_accepted';
  else v_status:='accepted'; end if;
  update public.packs set status=v_status,version=version+1,updated_at=now() where id=v_pack.id;
  insert into public.pack_events(pack_id,event_type,actor_id,payload)
    values(v_pack.id,case when v_status='accepted' then 'Принято' else 'Частично принято' end,
      auth.uid(),jsonb_build_object('operations',p_operations,'status',v_status));
  return jsonb_build_object('success',true,'message',case when v_status='accepted'
    then 'Пачка полностью принята' else 'Частичная приёмка сохранена' end,'status',v_status);
end; $$;

create or replace function public.get_my_packs()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_profile public.profiles%rowtype; v_packs jsonb;
begin
  select * into v_profile from public.profiles where id=auth.uid() and active;
  if not found then raise exception 'Профиль пользователя не активирован'; end if;
  select coalesce(jsonb_agg(row_data order by sort_date desc),'[]'::jsonb) into v_packs from (
    select jsonb_build_object('id',p.id,'model',p.model,'size',p.size,'color',p.color,'qty',p.quantity,
      'passport',p.passport_no,'status',case when p.status='accepted' then 'Принято'
        when p.status='partially_accepted' then 'Частично принято' else 'Выдано' end,
      'issuedDate',min(po.issued_at),'acceptedDate',max(po.accepted_at),
      'otkQty',max(po.accepted_qty),'defectQty',max(po.defect_qty)) row_data,
      max(coalesce(po.accepted_at,po.issued_at)) sort_date
    from public.packs p join public.pack_operations po on po.pack_id=p.id
    where p.status in ('issued','partially_accepted','accepted') and
      (v_profile.role in ('admin','master','accountant') or po.sewer_id=auth.uid() or po.sewer_name=v_profile.display_name)
    group by p.id
  ) q;
  return jsonb_build_object('success',true,'packs',v_packs);
end; $$;

create or replace function public.get_dashboard_data()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_role public.app_role; v_finance jsonb; v_production jsonb; v_sewers jsonb;
begin
  select public.current_app_role() into v_role;
  if v_role not in ('admin','master','accountant') then raise exception 'Недостаточно прав'; end if;
  select jsonb_build_object('issuedPacks',count(*) filter(where status in ('issued','partially_accepted')),
    'inProgressPacks',count(*) filter(where status in ('issued','partially_accepted')),'acceptedPacks',count(*) filter(where status='accepted'),
    'totalQty',coalesce(sum(quantity) filter(where status<>'annulled'),0),'inProgressQty',coalesce(sum(quantity) filter(where status in ('issued','partially_accepted')),0),
    'totalOtk',coalesce((select sum(accepted_qty) from public.pack_operations),0),
    'defect',coalesce((select sum(defect_qty) from public.pack_operations),0)) into v_production from public.packs;
  if v_role='master' then v_finance:=jsonb_build_object('revenue',0,'clientPaid',0,'clientDue',0,'zp',0,'paidZp',0,'totalZp',0,'profit',0,'margin',0);
  else select jsonb_build_object('revenue',coalesce(sum(accepted_qty*client_price),0),'clientPaid',coalesce(sum(client_paid_qty*client_price),0),
      'clientDue',coalesce(sum((accepted_qty-client_paid_qty)*client_price),0),'zp',coalesce(sum((accepted_qty-paid_qty)*sewer_price),0),
      'paidZp',coalesce(sum(paid_qty*sewer_price),0),'totalZp',coalesce(sum(accepted_qty*sewer_price),0),
      'profit',coalesce(sum(accepted_qty*(client_price-sewer_price)),0),'margin',case when coalesce(sum(accepted_qty*client_price),0)=0 then 0
      else round(100*sum(accepted_qty*(client_price-sewer_price))/sum(accepted_qty*client_price),1) end) into v_finance from public.pack_operations;
  end if;
  select coalesce(jsonb_object_agg(sewer_name,stats),'{}'::jsonb) into v_sewers from (
    select coalesce(sewer_name,'Не назначена') sewer_name,jsonb_build_object('items',sum(accepted_qty),
      'zp',case when v_role='master' then 0 else sum((accepted_qty-paid_qty)*sewer_price) end,
      'paid',case when v_role='master' then 0 else sum(paid_qty*sewer_price) end) stats
    from public.pack_operations group by coalesce(sewer_name,'Не назначена')) s;
  return jsonb_build_object('success',true,'finance',v_finance,'production',v_production,'sewers',v_sewers);
end; $$;

revoke all on function public.accept_pack(text,jsonb) from public,anon;
revoke all on function public.get_my_packs() from public,anon;
revoke all on function public.get_dashboard_data() from public,anon;
grant execute on function public.accept_pack(text,jsonb) to authenticated;
grant execute on function public.get_my_packs() to authenticated;
grant execute on function public.get_dashboard_data() to authenticated;
