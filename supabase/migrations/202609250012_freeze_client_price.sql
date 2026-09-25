-- Фиксируем цену заказчика в момент выдачи, как уже фиксируется цена швеи.
alter table public.pack_operations add column if not exists client_price numeric(12,2);
update public.pack_operations po set client_price=coalesce(oc.client_price,0)
from public.packs p left join public.operation_catalog oc on oc.model=p.model
where p.id=po.pack_id and oc.operation_name=po.operation_name and po.client_price is null;
update public.pack_operations set client_price=0 where client_price is null;
alter table public.pack_operations alter column client_price set default 0;
alter table public.pack_operations alter column client_price set not null;
alter table public.pack_operations drop constraint if exists pack_operations_client_price_check;
alter table public.pack_operations add constraint pack_operations_client_price_check check(client_price>=0);

create or replace function public.issue_pack(p_pack_id text,p_operations jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_pack public.packs%rowtype; v_item jsonb; v_name text; v_sewer text; v_price numeric(12,2); v_client_price numeric(12,2);
begin
  perform public.require_management_role();
  select * into v_pack from public.packs where id=p_pack_id for update;
  if not found then raise exception 'Пачка не найдена'; end if;
  if v_pack.status<>'new' then raise exception 'Выдать можно только новую пачку'; end if;
  if jsonb_typeof(p_operations)<>'array' or jsonb_array_length(p_operations)=0 then raise exception 'Не указаны операции'; end if;
  for v_item in select value from jsonb_array_elements(p_operations) loop
    v_name:=nullif(trim(v_item->>'operationName'),''); v_sewer:=nullif(trim(v_item->>'sewerName'),'');
    if v_name is null or v_sewer is null then raise exception 'Для каждой операции укажите швею'; end if;
    select sewer_price,client_price into v_price,v_client_price from public.operation_catalog
      where model=v_pack.model and operation_name=v_name and active;
    if not found then raise exception 'Операция % не найдена для модели %',v_name,v_pack.model; end if;
    insert into public.pack_operations(pack_id,operation_name,sewer_name,issued_qty,accepted_qty,issued_at,sewer_price,client_price)
      values(v_pack.id,v_name,v_sewer,v_pack.quantity,0,now(),v_price,v_client_price)
    on conflict(pack_id,operation_name) do update set sewer_name=excluded.sewer_name,issued_qty=excluded.issued_qty,
      accepted_qty=0,issued_at=excluded.issued_at,accepted_at=null,sewer_price=excluded.sewer_price,client_price=excluded.client_price;
  end loop;
  update public.packs set status='issued',version=version+1,updated_at=now() where id=v_pack.id;
  insert into public.pack_events(pack_id,event_type,actor_id,payload)
    values(v_pack.id,'Выдано',auth.uid(),jsonb_build_object('operations',p_operations,'quantity',v_pack.quantity));
  return jsonb_build_object('success',true,'message','Пачка выдана в пошив');
end; $$;

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
    'clientPaidQty',po.client_paid_qty,'clientPaidAt',po.client_paid_at,'clientPrice',po.client_price,'acceptedAt',po.accepted_at
  ) order by po.accepted_at desc nulls last,po.pack_id desc,po.id desc),'[]'::jsonb) into v_rows
  from public.pack_operations po join public.packs p on p.id=po.pack_id where po.accepted_qty>0;
  return jsonb_build_object('success',true,'operations',v_rows);
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
    'totalOtk',coalesce((select sum(accepted_qty) from public.pack_operations),0),'defect',0) into v_production from public.packs;
  if v_role='master' then v_finance:=jsonb_build_object('revenue',0,'clientPaid',0,'clientDue',0,'zp',0,'paidZp',0,'totalZp',0,'profit',0,'margin',0);
  else
    select jsonb_build_object('revenue',coalesce(sum(accepted_qty*client_price),0),'clientPaid',coalesce(sum(client_paid_qty*client_price),0),
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
