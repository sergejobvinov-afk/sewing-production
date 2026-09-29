-- Фактический прогресс пачки для дашборда и план-факта заказа.
-- Пачка считается обработанной только в объеме, завершенном по каждой выданной операции.
create or replace function public.get_dashboard_data()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_role public.app_role; v_finance jsonb; v_production jsonb; v_sewers jsonb;
begin
  select public.current_app_role() into v_role;
  if v_role not in ('admin','master','accountant') then raise exception 'Недостаточно прав'; end if;

  with operation_progress as (
    select pack_id,min(accepted_qty)::integer accepted_good,
      min(accepted_qty+defect_qty)::integer processed_qty
    from public.pack_operations where issued_qty>0 group by pack_id
  ), pack_progress as (
    select p.*,coalesce(op.accepted_good,0) accepted_good,
      greatest(p.quantity-coalesce(op.processed_qty,0),0) remaining_qty
    from public.packs p left join operation_progress op on op.pack_id=p.id
  )
  select jsonb_build_object(
    'issuedPacks',count(*) filter(where status in ('issued','partially_accepted')),
    'inProgressPacks',count(*) filter(where status in ('issued','partially_accepted')),
    'acceptedPacks',count(*) filter(where status='accepted'),
    'totalQty',coalesce(sum(quantity) filter(where status<>'annulled'),0),
    'inProgressQty',coalesce(sum(remaining_qty) filter(where status in ('issued','partially_accepted')),0),
    'totalOtk',coalesce(sum(accepted_good) filter(where status in ('issued','partially_accepted','accepted')),0),
    'defect',coalesce((select sum(defect_qty) from public.pack_operations),0)
  ) into v_production from pack_progress;

  if v_role='master' then
    v_finance:=jsonb_build_object('revenue',0,'clientPaid',0,'clientDue',0,'zp',0,'paidZp',0,'totalZp',0,'profit',0,'margin',0);
  else
    select jsonb_build_object('revenue',coalesce(sum(accepted_qty*client_price),0),'clientPaid',coalesce(sum(client_paid_qty*client_price),0),
      'clientDue',coalesce(sum((accepted_qty-client_paid_qty)*client_price),0),'zp',coalesce(sum((accepted_qty-paid_qty)*sewer_price),0),
      'paidZp',coalesce(sum(paid_qty*sewer_price),0),'totalZp',coalesce(sum(accepted_qty*sewer_price),0),
      'profit',coalesce(sum(accepted_qty*(client_price-sewer_price)),0),'margin',case when coalesce(sum(accepted_qty*client_price),0)=0 then 0
      else round(100*sum(accepted_qty*(client_price-sewer_price))/sum(accepted_qty*client_price),1) end)
    into v_finance from public.pack_operations;
  end if;

  select coalesce(jsonb_object_agg(sewer_name,stats),'{}'::jsonb) into v_sewers from (
    select coalesce(sewer_name,'Не назначена') sewer_name,jsonb_build_object('items',sum(accepted_qty),
      'zp',case when v_role='master' then 0 else sum((accepted_qty-paid_qty)*sewer_price) end,
      'paid',case when v_role='master' then 0 else sum(paid_qty*sewer_price) end) stats
    from public.pack_operations group by coalesce(sewer_name,'Не назначена')) s;
  return jsonb_build_object('success',true,'finance',v_finance,'production',v_production,'sewers',v_sewers);
end; $$;

create or replace function public.get_production_order_report(p_order_id bigint)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_role public.app_role; v_order public.production_orders; v_stats jsonb; v_linked jsonb; v_candidates jsonb;
begin
  select public.current_app_role() into v_role;
  if v_role not in ('admin','accountant') then raise exception 'Недостаточно прав'; end if;
  select * into v_order from public.production_orders where id=p_order_id;
  if not found then raise exception 'Заказ не найден'; end if;

  with operation_progress as (
    select pack_id,min(accepted_qty)::integer accepted_good,
      min(accepted_qty+defect_qty)::integer processed_qty
    from public.pack_operations where issued_qty>0 group by pack_id
  ), pack_progress as (
    select p.*,coalesce(op.accepted_good,0) accepted_good,
      greatest(p.quantity-coalesce(op.processed_qty,0),0) remaining_work
    from public.packs p left join operation_progress op on op.pack_id=p.id
    where p.production_order_id=p_order_id and p.status<>'annulled'
  )
  select jsonb_build_object(
    'packCount',count(*),'cutQty',coalesce(sum(quantity),0),
    'issuedPacks',count(*) filter(where status in ('issued','partially_accepted','accepted')),
    'issuedQty',coalesce(sum(quantity) filter(where status in ('issued','partially_accepted','accepted')),0),
    'inWorkPacks',count(*) filter(where status in ('issued','partially_accepted')),
    'inWorkQty',coalesce(sum(remaining_work) filter(where status in ('issued','partially_accepted')),0),
    'acceptedPacks',count(*) filter(where status='accepted'),
    'acceptedQty',coalesce(sum(accepted_good) filter(where status in ('issued','partially_accepted','accepted')),0),
    'remainingQty',greatest(v_order.order_qty-coalesce(sum(accepted_good) filter(where status in ('issued','partially_accepted','accepted')),0),0)
  ) into v_stats from pack_progress;

  v_stats:=v_stats||coalesce((select jsonb_build_object(
    'operationRevenue',coalesce(sum(po.accepted_qty*po.client_price),0),
    'sewerAccrued',coalesce(sum(po.accepted_qty*po.sewer_price),0),
    'sewerPaid',coalesce(sum(po.paid_qty*po.sewer_price),0),
    'clientPaid',coalesce(sum(po.client_paid_qty*po.client_price),0),
    'acceptedOperationQty',coalesce(sum(po.accepted_qty),0)
  ) from public.pack_operations po join public.packs p on p.id=po.pack_id where p.production_order_id=p_order_id),'{}'::jsonb);

  select coalesce(jsonb_agg(jsonb_build_object('id',id,'passport',passport_no,'dateCut',cut_date,'size',size,'qty',quantity,
    'status',status) order by cut_date desc,id desc),'[]'::jsonb) into v_linked
    from public.packs where production_order_id=p_order_id and status<>'annulled';
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'passport',passport_no,'dateCut',cut_date,'size',size,'qty',quantity,
    'status',status) order by cut_date desc,id desc),'[]'::jsonb) into v_candidates
    from (select * from public.packs where production_order_id is null and model=v_order.model and status<>'annulled' order by cut_date desc,id desc limit 200) p;

  return jsonb_build_object('success',true,'order',jsonb_build_object('id',v_order.id,'name',v_order.name,'model',v_order.model,
    'qty',v_order.order_qty,'clientPrice',v_order.client_price_gross,'unitCost',v_order.unit_cost,'plannedDays',v_order.planned_days,
    'plannedProfit',v_order.net_profit,'plannedMargin',v_order.margin_percent),'stats',v_stats,'linkedPacks',v_linked,'candidatePacks',v_candidates);
end; $$;

revoke all on function public.get_dashboard_data() from public,anon;
revoke all on function public.get_production_order_report(bigint) from public,anon;
grant execute on function public.get_dashboard_data() to authenticated;
grant execute on function public.get_production_order_report(bigint) to authenticated;
