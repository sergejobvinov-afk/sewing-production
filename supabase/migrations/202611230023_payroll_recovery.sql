-- Сверка пропущенной выплаты: восстановление приёмок на дату и отдельная
-- подтверждаемая запись. При применении миграции оплаты не меняются.
begin;

create table if not exists public.payroll_recovery_batches (
  id uuid primary key,
  payment_date date not null,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  selection jsonb not null,
  result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.payroll_recovery_batches enable row level security;
revoke all on public.payroll_recovery_batches from public, anon, authenticated;

create or replace function public.get_payroll_recovery(p_payment_date date)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_role public.app_role; v_cutoff timestamptz; v_rows jsonb;
begin
  v_role := public.current_app_role();
  if v_role is null or v_role not in ('admin','accountant') then raise exception 'Недостаточно прав для сверки выплаты'; end if;
  if p_payment_date is null or p_payment_date > (now() at time zone 'Europe/Moscow')::date then raise exception 'Укажите дату состоявшейся выплаты'; end if;
  v_cutoff := (p_payment_date + 1)::timestamp at time zone 'Europe/Moscow';

  with history as (
    select po.*, p.model, p.passport_no, p.cut_date,
      coalesce(h.logged,0) logged, h.last_event, coalesce(h.before_cutoff,0) before_cutoff,
      coalesce(h.bad_events,0) bad_events, coalesce(h.last_id,0) last_event_id
    from public.pack_operations po join public.packs p on p.id=po.pack_id
    left join lateral (
      select sum(case when x->>'acceptedQty' ~ '^[0-9]{1,9}$' then (x->>'acceptedQty')::integer else 0 end) logged,
        max(e.created_at) last_event,
        sum(case when e.created_at<v_cutoff and x->>'acceptedQty' ~ '^[0-9]{1,9}$' then (x->>'acceptedQty')::integer else 0 end) before_cutoff,
        count(*) filter(where coalesce(x->>'acceptedQty','') !~ '^[0-9]{1,9}$') bad_events, max(e.id) last_id
      from public.pack_events e cross join lateral jsonb_array_elements(
        case when jsonb_typeof(e.payload->'operations')='array' then e.payload->'operations' else '[]'::jsonb end) x
      where e.pack_id=po.pack_id and e.event_type in ('Принято','Частично принято')
        and x->>'operationName'=po.operation_name and e.created_at>=po.issued_at
    ) h on true where po.accepted_qty>0
  ), classified as (
    select *, case
      when issued_at is not null and issued_at>=v_cutoff then 0
      when accepted_at is not null and accepted_at<v_cutoff then accepted_qty
      when issued_at is not null and bad_events=0 and logged=accepted_qty and last_event=accepted_at then before_cutoff
      else null end as accepted_before
    from history
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'operationId',id,'packId',pack_id,'passport',passport_no,'model',model,'cutDate',cut_date,
    'operationName',operation_name,'sewerName',coalesce(sewer_name,'Не назначена'),
    'issuedQty',issued_qty,'acceptedNow',accepted_qty,'acceptedBefore',accepted_before,
    'paidQty',paid_qty,'price',sewer_price,
    'recoveryQty',case when accepted_before is null then null else greatest(accepted_before-paid_qty,0) end,
    'remainingAfter',case when accepted_before is null then null else accepted_qty-greatest(paid_qty,accepted_before) end,
    'needsReview',accepted_before is null,
    'fingerprint',md5(jsonb_build_array(id,issued_at,accepted_at,accepted_qty,paid_qty,paid_at,sewer_price,sewer_name,accepted_before,last_event_id)::text)
  ) order by coalesce(sewer_name,'Не назначена'),model,cut_date,operation_name,pack_id),'[]'::jsonb) into v_rows from classified;
  return jsonb_build_object('success',true,'paymentDate',p_payment_date,'timezone','Europe/Moscow','operations',v_rows,'generatedAt',now());
end; $$;

create or replace function public.record_payroll_recovery(p_payment_date date,p_items jsonb,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_role public.app_role; v_snapshot jsonb; v_item jsonb; v_preview jsonb;
  v_row public.pack_operations%rowtype; v_batch public.payroll_recovery_batches%rowtype;
  v_qty integer; v_count integer:=0; v_total numeric:=0; v_result jsonb;
begin
  v_role := public.current_app_role();
  if v_role is null or v_role not in ('admin','accountant') then raise exception 'Недостаточно прав для записи выплаты'; end if;
  if p_request_id is null or p_payment_date is null or p_payment_date>(now() at time zone 'Europe/Moscow')::date then raise exception 'Проверьте дату выплаты'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Выберите операции для сверенной выплаты'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) x where coalesce(x->>'operationId','') !~ '^[0-9]{1,18}$' or coalesce(x->>'fingerprint','') !~ '^[a-f0-9]{32}$') then raise exception 'Некорректные данные сверки'; end if;
  if (select count(distinct x->>'operationId') from jsonb_array_elements(p_items) x)<>jsonb_array_length(p_items) then raise exception 'Операции повторяются'; end if;

  -- Одинаковый запрос после потери связи возвращает сохранённый результат.
  insert into public.payroll_recovery_batches(id,payment_date,actor_id,selection)
    values(p_request_id,p_payment_date,auth.uid(),p_items) on conflict(id) do nothing;
  select * into v_batch from public.payroll_recovery_batches where id=p_request_id for update;
  if v_batch.actor_id<>auth.uid() or v_batch.payment_date<>p_payment_date or v_batch.selection<>p_items then raise exception 'Идентификатор выплаты уже использован'; end if;
  if v_batch.result<>'{}'::jsonb then return v_batch.result; end if;

  perform 1 from public.pack_operations where id in
    (select (x->>'operationId')::bigint from jsonb_array_elements(p_items) x) order by id for update;
  v_snapshot := public.get_payroll_recovery(p_payment_date);
  for v_item in select value from jsonb_array_elements(p_items) loop
    select value into v_preview from jsonb_array_elements(v_snapshot->'operations')
      where value->>'operationId'=v_item->>'operationId';
    if v_preview is null or v_preview->>'fingerprint'<>v_item->>'fingerprint' then raise exception 'Данные изменились. Сформируйте сверку заново'; end if;
    if (v_preview->>'needsReview')::boolean or coalesce((v_preview->>'recoveryQty')::integer,0)<=0 then raise exception 'Операция не подтверждена для восстановления'; end if;
    select * into v_row from public.pack_operations where id=(v_item->>'operationId')::bigint;
    v_qty := (v_preview->>'recoveryQty')::integer;
    update public.pack_operations set paid_qty=paid_qty+v_qty,
      -- Legacy-поле хранит календарную дату; фактическое время внесения есть в журнале.
      paid_at=greatest(coalesce(paid_at,p_payment_date::timestamp at time zone 'UTC'),p_payment_date::timestamp at time zone 'UTC'),
      paid_by=auth.uid() where id=v_row.id;
    insert into public.pack_events(pack_id,event_type,actor_id,payload) values(v_row.pack_id,'Оплата швее',auth.uid(),
      jsonb_build_object('operation',v_row.operation_name,'paid',true,'qty',v_row.paid_qty+v_qty,
        'from_qty',v_row.paid_qty,'to_qty',v_row.paid_qty+v_qty,'addedQty',v_qty,
        'paymentDate',p_payment_date,'recordedAt',now(),'source','payroll_recovery','batchId',p_request_id,
        'sewerName',v_row.sewer_name,'price',v_row.sewer_price,'amount',v_qty*v_row.sewer_price));
    v_count:=v_count+1; v_total:=v_total+v_qty*v_row.sewer_price;
  end loop;
  v_result:=jsonb_build_object('success',true,'message','Прошлая выплата внесена в учёт','count',v_count,'amount',v_total,'paymentDate',p_payment_date,'batchId',p_request_id);
  update public.payroll_recovery_batches set result=v_result where id=p_request_id;
  return v_result;
end; $$;

revoke all on function public.get_payroll_recovery(date) from public,anon;
revoke all on function public.record_payroll_recovery(date,jsonb,uuid) from public,anon;
grant execute on function public.get_payroll_recovery(date) to authenticated;
grant execute on function public.record_payroll_recovery(date,jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
