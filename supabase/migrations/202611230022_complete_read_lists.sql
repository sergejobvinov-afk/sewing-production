-- Полные списки заказов и пачек для план-факта.
-- Только определения двух read-only функций: данные и права не меняются.
-- pg_get_functiondef сохраняет актуальные формулы, проверки ролей и атрибуты
-- функции на сервере, включая изменения, сделанные после старых миграций.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $migration$
declare
  target record;
  original_definition text;
  updated_definition text;
begin
  for target in select * from (values
    ('public.get_cost_calculator_data()', 20),
    ('public.get_production_order_report(bigint)', 200)
  ) as functions(signature, old_limit)
  loop
    original_definition := pg_get_functiondef(target.signature::regprocedure);
    updated_definition := regexp_replace(original_definition,
      '\mLIMIT[[:space:]]+' || target.old_limit || '\M', '', 'gi');

    -- Не заменяем неизвестную серверную версию с другими ограничениями.
    if updated_definition ~* '\mLIMIT[[:space:]]+[[:digit:]]+' then
      raise exception 'Неожиданное ограничение в %. Обновление отменено: требуется проверка определения функции.', target.signature;
    end if;
    if updated_definition <> original_definition then
      execute updated_definition;
    end if;
  end loop;
end;
$migration$;

notify pgrst, 'reload schema';
commit;

-- Ожидается две строки: security_definer=true, anon_execute=false,
-- authenticated_execute=true, has_row_limit=false.
select p.proname,
  p.prosecdef as security_definer,
  has_function_privilege('anon', p.oid, 'execute') as anon_execute,
  has_function_privilege('authenticated', p.oid, 'execute') as authenticated_execute,
  pg_get_functiondef(p.oid) ~* '\mLIMIT[[:space:]]+[[:digit:]]+' as has_row_limit
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('get_cost_calculator_data', 'get_production_order_report')
order by p.proname;
