-- Показывать сохранённый состав прошлой выплаты даже после погашения долга.
-- Изменяется только read-only функция; сами выплаты не меняются.
begin;
do $migration$
declare definition text; original text;
begin
  original:=pg_get_functiondef('public.get_payroll_recovery(date)'::regprocedure);
  if position('v_payments jsonb' in original)=0 then
    definition:=replace(original,'v_rows jsonb;','v_rows jsonb; v_payments jsonb;');
    if definition=original then raise exception 'Неизвестная версия функции сверки'; end if;
    definition:=replace(definition,
      'return jsonb_build_object(''success'',true,''paymentDate'',p_payment_date,''timezone'',''Europe/Moscow'',''operations'',v_rows,''generatedAt'',now());',
      $body$
  select coalesce(jsonb_agg(jsonb_build_object(
    'batchId',b.id,'paymentDate',b.payment_date,'recordedAt',b.created_at,
    'count',b.result->'count','amount',b.result->'amount',
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'eventId',e.id::text,'packId',e.pack_id,'passport',p.passport_no,'model',p.model,'cutDate',p.cut_date,
      'sewerName',e.payload->>'sewerName','operationName',e.payload->>'operation',
      'qty',(e.payload->>'addedQty')::integer,'price',(e.payload->>'price')::numeric,'amount',(e.payload->>'amount')::numeric
    ) order by e.id) from public.pack_events e join public.packs p on p.id=e.pack_id
      where e.payload->>'source'='payroll_recovery' and e.payload->>'batchId'=b.id::text),'[]'::jsonb)
  ) order by b.created_at,b.id),'[]'::jsonb) into v_payments
  from public.payroll_recovery_batches b where b.payment_date=p_payment_date and b.result->>'success'='true';
  return jsonb_build_object('success',true,'paymentDate',p_payment_date,'timezone','Europe/Moscow','operations',v_rows,'payments',v_payments,'generatedAt',now());
      $body$);
    if position('''payments'',v_payments' in definition)=0 then raise exception 'Неизвестная версия ответа сверки'; end if;
    execute definition;
  end if;
end;
$migration$;
notify pgrst,'reload schema';
commit;
