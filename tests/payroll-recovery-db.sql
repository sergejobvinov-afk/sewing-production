-- Запускать только в отдельной пустой тестовой базе PostgreSQL.
\set ON_ERROR_STOP on
create role anon;
create role authenticated;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.actor',true),'')::uuid $$;
create type public.app_role as enum ('admin','master','accountant','sewer');
create function public.current_app_role() returns public.app_role language sql stable as $$ select nullif(current_setting('test.role',true),'')::public.app_role $$;
create table public.profiles(id uuid primary key);
insert into public.profiles values('00000000-0000-0000-0000-000000000001');
set test.actor='00000000-0000-0000-0000-000000000001';
set test.role='admin';
create table public.packs(id text primary key,model text,passport_no text,cut_date date);
create table public.pack_operations(id bigint primary key,pack_id text references public.packs(id),operation_name text,sewer_name text,
  issued_at timestamptz,accepted_at timestamptz,issued_qty integer,accepted_qty integer,paid_qty integer,paid_at timestamptz,
  paid_by uuid,sewer_price numeric,client_paid_qty integer default 0,
  constraint paid_check check(paid_qty>=0 and paid_qty<=accepted_qty));
create table public.pack_events(id bigint generated always as identity primary key,pack_id text,event_type text,actor_id uuid,payload jsonb,created_at timestamptz default now());
insert into public.packs select 'KR-'||i,'Модель','П-'||i,'2026-11-01' from generate_series(1,8) i;
insert into public.pack_operations(id,pack_id,operation_name,sewer_name,issued_at,accepted_at,issued_qty,accepted_qty,paid_qty,sewer_price) values
  (1,'KR-1','Оверлок','Анна','2026-11-01Z','2026-11-09T20:59:59.999Z',10,10,3,42.30),
  (2,'KR-2','Распошив','Мутриба','2026-11-01Z','2026-11-11T10:00Z',10,10,1,0.10),
  (3,'KR-3','Оверлок','Анна','2026-11-10Z','2026-11-11Z',20,20,0,10),
  (4,'KR-4','Оверлок','Анна','2026-11-01Z','2026-11-12Z',8,8,0,10),
  (5,'KR-5','Оверлок','Анна','2026-11-01Z','2026-11-08Z',5,5,5,10),
  (6,'KR-6','Оверлок','Анна','2026-11-01Z','2026-11-11Z',3,3,0,10),
  (7,'KR-7','Оверлок','Анна','2026-11-01Z','2026-11-12Z',8,8,0,10),
  (8,'KR-8','Оверлок','Анна','2026-11-01Z','2026-11-08Z',10,10,0,1);
insert into public.pack_events(pack_id,event_type,payload,created_at) values
 ('KR-2','Частично принято','{"operations":[{"operationName":"Распошив","acceptedQty":6}]}','2026-11-09T20:59:59.999Z'),
 ('KR-2','Принято','{"operations":[{"operationName":"Распошив","acceptedQty":4}]}','2026-11-09T21:00Z'),
 ('KR-2','Принято','{"operations":[{"operationName":"Распошив","acceptedQty":0,"defectQty":1}]}','2026-11-11T10:00Z'),
 ('KR-4','Принято','{"operations":[{"operationName":"Оверлок","acceptedQty":3}]}','2026-11-12Z'),
 ('KR-6','Принято','{"operations":[{"operationName":"Оверлок","acceptedQty":3}]}','2026-11-11Z'),
 ('KR-7','Принято','{"operations":[{"operationName":"Оверлок","acceptedQty":"ошибка"}]}','2026-11-12Z');

\ir ../supabase/migrations/202611230023_payroll_recovery.sql

do $$
declare preview jsonb; first_item jsonb; second_item jsonb; eighth_item jsonb; items jsonb; result jsonb; retry jsonb; n integer;
begin
  preview:=public.get_payroll_recovery('2026-11-09');
  select value into first_item from jsonb_array_elements(preview->'operations') where value->>'operationId'='1';
  select value into second_item from jsonb_array_elements(preview->'operations') where value->>'operationId'='2';
  select value into eighth_item from jsonb_array_elements(preview->'operations') where value->>'operationId'='8';
  if (first_item->>'recoveryQty')::int<>7 or (second_item->>'acceptedBefore')::int<>6 or (second_item->>'recoveryQty')::int<>5 or (second_item->>'remainingAfter')::int<>4 then raise exception 'Cutoff/partial receipt reconstruction failed'; end if;
  if exists(select 1 from jsonb_array_elements(preview->'operations') x where x->>'operationId' in ('3','6') and (x->>'acceptedBefore')::int<>0) then raise exception 'Later work included'; end if;
  if exists(select 1 from jsonb_array_elements(preview->'operations') x where x->>'operationId' in ('4','7') and not (x->>'needsReview')::boolean) then raise exception 'Incomplete history not blocked'; end if;
  if (select paid_qty from public.pack_operations where id=1)<>3 or exists(select 1 from public.payroll_recovery_batches) then raise exception 'Preview modified payments'; end if;
  items:=jsonb_build_array(jsonb_build_object('operationId','1','fingerprint',first_item->>'fingerprint'),jsonb_build_object('operationId','2','fingerprint',second_item->>'fingerprint'));
  result:=public.record_payroll_recovery('2026-11-09',items,'00000000-0000-0000-0000-000000000010');
  if (result->>'amount')::numeric<>296.60 or (result->>'count')::int<>2 then raise exception 'Incorrect amount'; end if;
  if (select paid_qty from public.pack_operations where id=1)<>10 or (select paid_qty from public.pack_operations where id=2)<>6 then raise exception 'Wrong paid quantity'; end if;
  if exists(select 1 from public.pack_operations where client_paid_qty<>0) then raise exception 'Client payment changed'; end if;
  if (select accepted_qty-paid_qty from public.pack_operations where id=2)<>4 then raise exception 'Later work incorrectly marked paid'; end if;
  if (select paid_at::date from public.pack_operations where id=1)<>date '2026-11-09' then raise exception 'Effective date lost'; end if;
  retry:=public.record_payroll_recovery('2026-11-09',items,'00000000-0000-0000-0000-000000000010');
  if retry<>result or (select count(*) from public.pack_events where payload->>'source'='payroll_recovery')<>2 then raise exception 'Retry not idempotent'; end if;
  -- Один свежий и один устаревший элемент: изменения первого тоже откатываются.
  begin
    perform public.record_payroll_recovery('2026-11-09',jsonb_build_array(jsonb_build_object('operationId','8','fingerprint',eighth_item->>'fingerprint'),items->0),'00000000-0000-0000-0000-000000000011');
    raise exception 'Stale preview allowed';
  exception when others then if SQLERRM<>'Данные изменились. Сформируйте сверку заново' then raise; end if; end;
  if (select paid_qty from public.pack_operations where id=8)<>0 or exists(select 1 from public.payroll_recovery_batches where id='00000000-0000-0000-0000-000000000011') then raise exception 'Partial transaction committed'; end if;
  begin
    perform public.record_payroll_recovery('2026-11-09',jsonb_build_array(items->0,items->0),'00000000-0000-0000-0000-000000000012');
    raise exception 'Duplicate allowed';
  exception when others then if SQLERRM<>'Операции повторяются' then raise; end if; end;
  if has_function_privilege('anon','public.get_payroll_recovery(date)','execute') or has_table_privilege('authenticated','public.payroll_recovery_batches','select') then raise exception 'Unexpected public access'; end if;
end $$;
set test.role='master';
do $$ begin
  begin perform public.get_payroll_recovery('2026-11-09');raise exception 'Master allowed';exception when others then if SQLERRM<>'Недостаточно прав для сверки выплаты' then raise;end if;end;
end $$;
set test.role='';
do $$ begin
  begin perform public.get_payroll_recovery('2026-11-09');raise exception 'Null role allowed';exception when others then if SQLERRM<>'Недостаточно прав для сверки выплаты' then raise;end if;end;
end $$;
select 'PASS: Moscow cutoff, partial receipts, malformed history, exact amount, retry, rollback, unchanged client payments, role checks' as result;
