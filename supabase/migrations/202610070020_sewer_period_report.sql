-- Отчёт по швее за период: выдача, приёмка, брак, остаток и оплата.
-- Период можно применять к дате выдачи, приёмки или оплаты.
create or replace function public.get_sewer_period_report(
  p_sewer_name text,
  p_date_from date,
  p_date_to date,
  p_date_kind text default 'accepted'
)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_role public.app_role;
  v_summary jsonb;
  v_details jsonb;
begin
  select public.current_app_role() into v_role;
  if v_role not in ('admin','master','accountant') then
    raise exception 'Недостаточно прав для просмотра отчёта';
  end if;
  if nullif(trim(p_sewer_name),'') is null then raise exception 'Выберите швею'; end if;
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to then
    raise exception 'Проверьте период отчёта';
  end if;
  if p_date_to-p_date_from>366 then raise exception 'Период не должен превышать 366 дней'; end if;
  if p_date_kind not in ('issued','accepted','paid') then raise exception 'Неизвестный вид периода'; end if;

  with filtered as (
    select p.model,po.*
    from public.pack_operations po
    join public.packs p on p.id=po.pack_id
    where po.sewer_name=p_sewer_name and p.status<>'annulled' and
      case p_date_kind
        when 'issued' then po.issued_at::date between p_date_from and p_date_to
        when 'accepted' then po.accepted_at::date between p_date_from and p_date_to
        when 'paid' then po.paid_at::date between p_date_from and p_date_to
      end
  ), pack_progress as (
    -- Количество изделий не умножаем на число операций модели.
    select model,pack_id,max(issued_qty) issued_qty,min(accepted_qty) accepted_qty,
      sum(defect_qty) defect_qty,min(accepted_qty+defect_qty) processed_qty,
      min(paid_qty) paid_qty,max(paid_at) last_paid_at
    from filtered group by model,pack_id
  ), grouped as (
    select model,count(*) pack_count,sum(issued_qty) issued_qty,
      sum(accepted_qty) accepted_qty,sum(defect_qty) defect_qty,
      sum(greatest(issued_qty-processed_qty,0)) remaining_qty,
      sum(paid_qty) paid_qty,max(last_paid_at) last_paid_at
    from pack_progress group by model
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'model',model,'packCount',pack_count,'issuedQty',issued_qty,
    'acceptedQty',accepted_qty,'defectQty',defect_qty,'remainingQty',remaining_qty,
    'paidQty',paid_qty,'lastPaidAt',last_paid_at,
    'paymentStatus',case when accepted_qty=0 then 'Нет приёмки'
      when paid_qty>=accepted_qty then 'Оплачено'
      when paid_qty>0 then 'Частично оплачено' else 'Не оплачено' end
  ) order by model),'[]'::jsonb) into v_summary from grouped;

  with filtered as (
    select p.model,p.passport_no,po.*
    from public.pack_operations po
    join public.packs p on p.id=po.pack_id
    where po.sewer_name=p_sewer_name and p.status<>'annulled' and
      case p_date_kind
        when 'issued' then po.issued_at::date between p_date_from and p_date_to
        when 'accepted' then po.accepted_at::date between p_date_from and p_date_to
        when 'paid' then po.paid_at::date between p_date_from and p_date_to
      end
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'packId',pack_id,'passport',passport_no,'model',model,'operationName',operation_name,
    'issuedQty',issued_qty,'acceptedQty',accepted_qty,'defectQty',defect_qty,
    'remainingQty',greatest(issued_qty-accepted_qty-defect_qty,0),'paidQty',paid_qty,
    'issuedAt',issued_at,'acceptedAt',accepted_at,'paidAt',paid_at,
    'paymentStatus',case when accepted_qty=0 then 'Нет приёмки'
      when paid_qty>=accepted_qty then 'Оплачено'
      when paid_qty>0 then 'Частично оплачено' else 'Не оплачено' end
  ) order by model,pack_id,operation_name),'[]'::jsonb) into v_details from filtered;

  return jsonb_build_object('success',true,'sewerName',p_sewer_name,
    'dateFrom',p_date_from,'dateTo',p_date_to,'dateKind',p_date_kind,
    'summary',v_summary,'details',v_details);
end; $$;

revoke all on function public.get_sewer_period_report(text,date,date,text) from public,anon;
grant execute on function public.get_sewer_period_report(text,date,date,text) to authenticated;
