-- Единый период и фильтр модели для всех блоков дашборда.
create or replace function public.get_dashboard_data_filtered(
  p_date_from date,
  p_date_to date,
  p_date_kind text default 'cut',
  p_model text default null
)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_role public.app_role;
  v_finance jsonb;
  v_production jsonb;
  v_sewers jsonb;
  v_models jsonb;
  v_sizes jsonb;
begin
  select public.current_app_role() into v_role;
  if v_role not in ('admin','master','accountant') then raise exception 'Недостаточно прав'; end if;
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to then raise exception 'Проверьте период'; end if;
  if p_date_to-p_date_from>730 then raise exception 'Период не должен превышать 730 дней'; end if;
  if p_date_kind not in ('cut','issued','accepted','paid') then raise exception 'Неизвестный тип даты'; end if;

  with pack_scope as (
    select p.* from public.packs p
    where p.status<>'annulled' and (nullif(trim(p_model),'') is null or p.model=trim(p_model))
      and case p_date_kind
        when 'cut' then p.cut_date between p_date_from and p_date_to
        when 'issued' then exists(select 1 from public.pack_operations po where po.pack_id=p.id and po.issued_at::date between p_date_from and p_date_to)
        when 'accepted' then exists(select 1 from public.pack_operations po where po.pack_id=p.id and po.accepted_at::date between p_date_from and p_date_to)
        when 'paid' then exists(select 1 from public.pack_operations po where po.pack_id=p.id and po.paid_at::date between p_date_from and p_date_to)
      end
  ), operation_progress as (
    select po.pack_id,min(po.accepted_qty)::integer accepted_good,
      min(po.accepted_qty+po.defect_qty)::integer processed_qty,
      sum(po.defect_qty)::integer operation_defects
    from public.pack_operations po join pack_scope p on p.id=po.pack_id
    where po.issued_qty>0 group by po.pack_id
  ), pack_progress as (
    select p.*,coalesce(op.accepted_good,0) accepted_good,coalesce(op.processed_qty,0) processed_qty,
      coalesce(op.operation_defects,0) operation_defects,
      greatest(p.quantity-coalesce(op.processed_qty,0),0) remaining_qty,
      greatest(coalesce(op.processed_qty,0)-p.quantity,0) over_qty
    from pack_scope p left join operation_progress op on op.pack_id=p.id
  )
  select jsonb_build_object(
    'totalPacks',count(*),'totalQty',coalesce(sum(quantity),0),
    'newPacks',count(*) filter(where status='new'),'newQty',coalesce(sum(quantity) filter(where status='new'),0),
    'issuedPacks',count(*) filter(where status in ('issued','partially_accepted','accepted')),
    'issuedQty',coalesce(sum(quantity) filter(where status in ('issued','partially_accepted','accepted')),0),
    'inProgressPacks',count(*) filter(where status in ('issued','partially_accepted')),
    'inProgressQty',coalesce(sum(remaining_qty) filter(where status in ('issued','partially_accepted')),0),
    'acceptedPacks',count(*) filter(where status='accepted'),
    'totalOtk',coalesce(sum(accepted_good),0),'remainingQty',coalesce(sum(remaining_qty),0),
    'operationDefects',coalesce(sum(operation_defects),0),'overQty',coalesce(sum(over_qty),0)
  ) into v_production from pack_progress;

  with pack_scope as (
    select p.id,p.model from public.packs p where p.status<>'annulled'
      and (nullif(trim(p_model),'') is null or p.model=trim(p_model))
  ), operation_scope as (
    select po.* from public.pack_operations po join pack_scope p on p.id=po.pack_id
    where case p_date_kind
      when 'cut' then exists(select 1 from public.packs px where px.id=po.pack_id and px.cut_date between p_date_from and p_date_to)
      when 'issued' then po.issued_at::date between p_date_from and p_date_to
      when 'accepted' then po.accepted_at::date between p_date_from and p_date_to
      when 'paid' then po.paid_at::date between p_date_from and p_date_to
    end
  )
  select case when v_role='master' then
    jsonb_build_object('revenue',0,'clientPaid',0,'clientDue',0,'zp',0,'paidZp',0,'totalZp',0,'contribution',0,'margin',0)
  else jsonb_build_object(
    'revenue',coalesce(sum(accepted_qty*client_price),0),
    'clientPaid',coalesce(sum(client_paid_qty*client_price),0),
    'clientDue',coalesce(sum((accepted_qty-client_paid_qty)*client_price),0),
    'zp',coalesce(sum((accepted_qty-paid_qty)*sewer_price),0),
    'paidZp',coalesce(sum(paid_qty*sewer_price),0),
    'totalZp',coalesce(sum(accepted_qty*sewer_price),0),
    'contribution',coalesce(sum(accepted_qty*(client_price-sewer_price)),0),
    'margin',case when coalesce(sum(accepted_qty*client_price),0)=0 then 0
      else round(100*sum(accepted_qty*(client_price-sewer_price))/sum(accepted_qty*client_price),1) end)
  end into v_finance from operation_scope;

  with operation_scope as (
    select po.* from public.pack_operations po join public.packs p on p.id=po.pack_id
    where p.status<>'annulled' and (nullif(trim(p_model),'') is null or p.model=trim(p_model))
      and case p_date_kind
        when 'cut' then p.cut_date between p_date_from and p_date_to
        when 'issued' then po.issued_at::date between p_date_from and p_date_to
        when 'accepted' then po.accepted_at::date between p_date_from and p_date_to
        when 'paid' then po.paid_at::date between p_date_from and p_date_to
      end
  )
  select coalesce(jsonb_agg(jsonb_build_object('name',sewer_name,'operationQty',operation_qty,
    'due',case when v_role='master' then 0 else due end,'paid',case when v_role='master' then 0 else paid end)
    order by due desc,sewer_name),'[]'::jsonb) into v_sewers from (
      select coalesce(sewer_name,'Не назначена') sewer_name,coalesce(sum(accepted_qty),0) operation_qty,
        coalesce(sum((accepted_qty-paid_qty)*sewer_price),0) due,coalesce(sum(paid_qty*sewer_price),0) paid
      from operation_scope group by coalesce(sewer_name,'Не назначена')
  ) s;

  with pack_scope as (
    select p.* from public.packs p where p.status<>'annulled' and (nullif(trim(p_model),'') is null or p.model=trim(p_model))
      and case p_date_kind
        when 'cut' then p.cut_date between p_date_from and p_date_to
        when 'issued' then exists(select 1 from public.pack_operations po where po.pack_id=p.id and po.issued_at::date between p_date_from and p_date_to)
        when 'accepted' then exists(select 1 from public.pack_operations po where po.pack_id=p.id and po.accepted_at::date between p_date_from and p_date_to)
        when 'paid' then exists(select 1 from public.pack_operations po where po.pack_id=p.id and po.paid_at::date between p_date_from and p_date_to)
      end
  ), operation_progress as (
    select po.pack_id,min(po.accepted_qty)::integer accepted_good,min(po.accepted_qty+po.defect_qty)::integer processed_qty
    from public.pack_operations po join pack_scope p on p.id=po.pack_id where po.issued_qty>0 group by po.pack_id
  ), pack_progress as (
    select p.*,coalesce(op.accepted_good,0) accepted_good,greatest(p.quantity-coalesce(op.processed_qty,0),0) remaining_qty
    from pack_scope p left join operation_progress op on op.pack_id=p.id
  ), model_rows as (
    select model,count(*) packs,sum(quantity) items,
      sum(quantity) filter(where status in ('issued','partially_accepted','accepted')) issued,
      sum(remaining_qty) filter(where status in ('issued','partially_accepted')) in_work,
      sum(accepted_good) accepted,sum(remaining_qty) remaining from pack_progress group by model
  ), size_rows as (
    select size,count(*) packs,sum(quantity) items,
      sum(quantity) filter(where status in ('issued','partially_accepted','accepted')) issued,
      sum(remaining_qty) filter(where status in ('issued','partially_accepted')) in_work,
      sum(accepted_good) accepted,sum(remaining_qty) remaining from pack_progress group by size
  )
  select
    (select coalesce(jsonb_agg(to_jsonb(m) order by model),'[]'::jsonb) from model_rows m),
    (select coalesce(jsonb_agg(to_jsonb(s) order by size),'[]'::jsonb) from size_rows s)
  into v_models,v_sizes;

  return jsonb_build_object('success',true,'finance',v_finance,'production',v_production,
    'sewers',v_sewers,'models',v_models,'sizes',v_sizes,
    'filters',jsonb_build_object('dateFrom',p_date_from,'dateTo',p_date_to,'dateKind',p_date_kind,'model',p_model));
end; $$;

revoke all on function public.get_dashboard_data_filtered(date,date,text,text) from public,anon;
grant execute on function public.get_dashboard_data_filtered(date,date,text,text) to authenticated;
