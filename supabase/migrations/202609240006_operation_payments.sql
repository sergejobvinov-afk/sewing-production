-- Оплата отдельно по каждой операции. paid_qty позволяет оплачивать частичную приёмку.
alter table public.pack_operations add column if not exists paid_qty integer not null default 0;
alter table public.pack_operations add column if not exists paid_at timestamptz;
alter table public.pack_operations add column if not exists paid_by uuid references public.profiles(id) on delete restrict;
alter table public.pack_operations drop constraint if exists pack_operations_paid_qty_check;
alter table public.pack_operations add constraint pack_operations_paid_qty_check
  check (paid_qty >= 0 and paid_qty <= accepted_qty);

create or replace function public.require_finance_role()
returns public.app_role language plpgsql stable security definer set search_path=public as $$
declare v_role public.app_role;
begin
  select role into v_role from public.profiles where id=auth.uid() and active;
  if v_role not in ('admin','accountant') then raise exception 'Недостаточно прав для учёта оплаты'; end if;
  return v_role;
end; $$;

create or replace function public.mark_operation_paid(p_pack_id text,p_operation_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_before integer; v_after integer;
begin
  perform public.require_finance_role();
  select paid_qty,accepted_qty into v_before,v_after from public.pack_operations
    where pack_id=p_pack_id and operation_name=p_operation_name for update;
  if not found then raise exception 'Операция не найдена'; end if;
  if v_after<=v_before then raise exception 'По операции нет новой суммы к оплате'; end if;
  update public.pack_operations set paid_qty=accepted_qty,paid_at=now(),paid_by=auth.uid()
    where pack_id=p_pack_id and operation_name=p_operation_name;
  insert into public.pack_events(pack_id,event_type,actor_id,payload)
    values(p_pack_id,'Оплата операции',auth.uid(),jsonb_build_object('operation',p_operation_name,'from_qty',v_before,'to_qty',v_after));
  return jsonb_build_object('success',true,'message','Операция отмечена оплаченной');
end; $$;

create or replace function public.unmark_operation_paid(p_pack_id text,p_operation_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_paid integer;
begin
  perform public.require_finance_role();
  update public.pack_operations set paid_qty=0,paid_at=null,paid_by=null
    where pack_id=p_pack_id and operation_name=p_operation_name and paid_qty>0 returning paid_qty into v_paid;
  if not found then raise exception 'Операция не отмечена оплаченной'; end if;
  insert into public.pack_events(pack_id,event_type,actor_id,payload)
    values(p_pack_id,'Отмена оплаты операции',auth.uid(),jsonb_build_object('operation',p_operation_name));
  return jsonb_build_object('success',true,'message','Отметка оплаты снята');
end; $$;

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
    v_finance:=jsonb_build_object('revenue',0,'zp',0,'paidZp',0,'totalZp',0,'profit',0,'margin',0);
  else
    select jsonb_build_object(
      'revenue',coalesce(sum(po.accepted_qty*oc.client_price),0),
      'zp',coalesce(sum((po.accepted_qty-po.paid_qty)*po.sewer_price),0),
      'paidZp',coalesce(sum(po.paid_qty*po.sewer_price),0),
      'totalZp',coalesce(sum(po.accepted_qty*po.sewer_price),0),
      'profit',coalesce(sum(po.accepted_qty*(oc.client_price-po.sewer_price)),0),
      'margin',case when coalesce(sum(po.accepted_qty*oc.client_price),0)=0 then 0 else
        round(100*sum(po.accepted_qty*(oc.client_price-po.sewer_price))/sum(po.accepted_qty*oc.client_price),1) end
    ) into v_finance from public.pack_operations po
    left join public.packs p on p.id=po.pack_id
    left join public.operation_catalog oc on oc.model=p.model and oc.operation_name=po.operation_name;
  end if;
  select coalesce(jsonb_object_agg(sewer_name,stats),'{}'::jsonb) into v_sewers from (
    select coalesce(sewer_name,'Не назначена') sewer_name,jsonb_build_object(
      'items',sum(accepted_qty),'zp',case when v_role='master' then 0 else sum((accepted_qty-paid_qty)*sewer_price) end,
      'paid',case when v_role='master' then 0 else sum(paid_qty*sewer_price) end) stats
    from public.pack_operations group by coalesce(sewer_name,'Не назначена')
  ) s;
  return jsonb_build_object('success',true,'finance',v_finance,'production',v_production,'sewers',v_sewers);
end; $$;

revoke all on function public.require_finance_role() from public,anon;
revoke all on function public.mark_operation_paid(text,text) from public,anon;
revoke all on function public.unmark_operation_paid(text,text) from public,anon;
grant execute on function public.mark_operation_paid(text,text) to authenticated;
grant execute on function public.unmark_operation_paid(text,text) to authenticated;
