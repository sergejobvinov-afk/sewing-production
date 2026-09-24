-- Независимый учёт оплаты швее и оплаты заказчиком + массовая обработка.
alter table public.pack_operations add column if not exists client_paid_qty integer not null default 0;
alter table public.pack_operations add column if not exists client_paid_at timestamptz;
alter table public.pack_operations add column if not exists client_paid_by uuid references public.profiles(id) on delete restrict;
alter table public.pack_operations drop constraint if exists pack_operations_client_paid_qty_check;
alter table public.pack_operations add constraint pack_operations_client_paid_qty_check
  check (client_paid_qty >= 0 and client_paid_qty <= accepted_qty);

create or replace function public.get_payment_operations()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_role public.app_role; v_rows jsonb;
begin
  select public.current_app_role() into v_role;
  if v_role not in ('admin','accountant') then raise exception 'Недостаточно прав для учёта оплаты'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'packId',po.pack_id,'passport',p.passport_no,'model',p.model,'operationName',po.operation_name,
    'sewerName',coalesce(po.sewer_name,'Не назначена'),'acceptedQty',po.accepted_qty,
    'sewerPaidQty',po.paid_qty,'sewerPaidAt',po.paid_at,'sewerPrice',po.sewer_price,
    'clientPaidQty',po.client_paid_qty,'clientPaidAt',po.client_paid_at,
    'clientPrice',coalesce(oc.client_price,0),'acceptedAt',po.accepted_at
  ) order by po.accepted_at desc nulls last,po.pack_id desc,po.id desc),'[]'::jsonb)
  into v_rows
  from public.pack_operations po
  join public.packs p on p.id=po.pack_id
  left join public.operation_catalog oc on oc.model=p.model and oc.operation_name=po.operation_name
  where po.accepted_qty>0;
  return jsonb_build_object('success',true,'operations',v_rows);
end; $$;

create or replace function public.set_operations_payment(p_items jsonb,p_kind text,p_paid boolean default true)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_item jsonb; v_count integer:=0; v_row public.pack_operations%rowtype;
begin
  perform public.require_finance_role();
  if p_kind not in ('sewer','client') then raise exception 'Неизвестный вид оплаты'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Не выбраны операции'; end if;
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    select * into v_row from public.pack_operations
      where pack_id=v_item->>'packId' and operation_name=v_item->>'operationName' for update;
    if not found then raise exception 'Операция не найдена: % / %',v_item->>'packId',v_item->>'operationName'; end if;
    if p_kind='sewer' then
      update public.pack_operations set paid_qty=case when p_paid then accepted_qty else 0 end,
        paid_at=case when p_paid then now() else null end,paid_by=case when p_paid then auth.uid() else null end
      where id=v_row.id;
    else
      update public.pack_operations set client_paid_qty=case when p_paid then accepted_qty else 0 end,
        client_paid_at=case when p_paid then now() else null end,client_paid_by=case when p_paid then auth.uid() else null end
      where id=v_row.id;
    end if;
    insert into public.pack_events(pack_id,event_type,actor_id,payload) values(
      v_row.pack_id,case when p_kind='sewer' then 'Оплата швее' else 'Оплата заказчиком' end,auth.uid(),
      jsonb_build_object('operation',v_row.operation_name,'paid',p_paid,'qty',case when p_paid then v_row.accepted_qty else 0 end));
    v_count:=v_count+1;
  end loop;
  return jsonb_build_object('success',true,'message',case when p_paid then 'Оплата отмечена' else 'Отметка оплаты снята' end,'count',v_count);
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
    v_finance:=jsonb_build_object('revenue',0,'clientPaid',0,'clientDue',0,'zp',0,'paidZp',0,'totalZp',0,'profit',0,'margin',0);
  else
    select jsonb_build_object(
      'revenue',coalesce(sum(po.accepted_qty*oc.client_price),0),
      'clientPaid',coalesce(sum(po.client_paid_qty*oc.client_price),0),
      'clientDue',coalesce(sum((po.accepted_qty-po.client_paid_qty)*oc.client_price),0),
      'zp',coalesce(sum((po.accepted_qty-po.paid_qty)*po.sewer_price),0),
      'paidZp',coalesce(sum(po.paid_qty*po.sewer_price),0),
      'totalZp',coalesce(sum(po.accepted_qty*po.sewer_price),0),
      'profit',coalesce(sum(po.accepted_qty*(oc.client_price-po.sewer_price)),0),
      'margin',case when coalesce(sum(po.accepted_qty*oc.client_price),0)=0 then 0 else
        round(100*sum(po.accepted_qty*(oc.client_price-po.sewer_price))/sum(po.accepted_qty*oc.client_price),1) end
    ) into v_finance from public.pack_operations po
    join public.packs p on p.id=po.pack_id
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

revoke all on function public.get_payment_operations() from public,anon;
revoke all on function public.set_operations_payment(jsonb,text,boolean) from public,anon;
grant execute on function public.get_payment_operations() to authenticated;
grant execute on function public.set_operations_payment(jsonb,text,boolean) to authenticated;
