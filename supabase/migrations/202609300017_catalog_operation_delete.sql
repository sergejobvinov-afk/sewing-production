-- Удаление ошибочно созданной операции каталога.
-- Исторические операции защищены внешним ключом и вместо удаления деактивируются в интерфейсе.
create or replace function public.delete_catalog_operation(p_id bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_model text; v_operation text;
begin
  if public.current_app_role()<>'admin' then raise exception 'Только администратор может изменять расценки'; end if;
  select model,operation_name into v_model,v_operation from public.operation_catalog where id=p_id;
  if not found then raise exception 'Операция не найдена'; end if;
  if exists(select 1 from public.pack_operations where catalog_operation_id=p_id) then
    raise exception 'Эта операция уже использовалась. Отключите флажок «Активна», чтобы сохранить историю';
  end if;
  delete from public.operation_catalog where id=p_id;
  return jsonb_build_object('success',true,'message','Операция «'||v_operation||'» удалена из модели «'||v_model||'»');
end; $$;

revoke all on function public.delete_catalog_operation(bigint) from public,anon;
grant execute on function public.delete_catalog_operation(bigint) to authenticated;
