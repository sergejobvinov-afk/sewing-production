-- Безопасное администрирование моделей и расценок без удаления истории.
create or replace function public.get_catalog_admin()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_rows jsonb;
begin
  if public.current_app_role()<>'admin' then raise exception 'Только администратор может изменять расценки'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'model',model,'operationName',operation_name,
    'sequenceNo',sequence_no,'sewerPrice',sewer_price,'clientPrice',client_price,'active',active)
    order by model,sequence_no,id),'[]'::jsonb) into v_rows from public.operation_catalog;
  return jsonb_build_object('success',true,'operations',v_rows);
end; $$;

create or replace function public.save_catalog_operation(p_id bigint,p_model text,p_operation_name text,
  p_sequence_no integer,p_sewer_price numeric,p_client_price numeric,p_active boolean default true)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id bigint;
begin
  if public.current_app_role()<>'admin' then raise exception 'Только администратор может изменять расценки'; end if;
  if nullif(trim(p_model),'') is null or nullif(trim(p_operation_name),'') is null then raise exception 'Укажите модель и операцию'; end if;
  if p_sequence_no<0 or p_sewer_price<0 or p_client_price<0 then raise exception 'Порядок и цены не могут быть отрицательными'; end if;
  if p_id is null then
    insert into public.operation_catalog(model,operation_name,sequence_no,sewer_price,client_price,active)
      values(trim(p_model),trim(p_operation_name),p_sequence_no,p_sewer_price,p_client_price,p_active)
      on conflict(model,operation_name) do update set sequence_no=excluded.sequence_no,sewer_price=excluded.sewer_price,
        client_price=excluded.client_price,active=excluded.active returning id into v_id;
  else
    update public.operation_catalog set sequence_no=p_sequence_no,sewer_price=p_sewer_price,
      client_price=p_client_price,active=p_active where id=p_id returning id into v_id;
    if not found then raise exception 'Операция не найдена'; end if;
  end if;
  return jsonb_build_object('success',true,'message','Расценка сохранена','id',v_id);
end; $$;

create or replace function public.copy_catalog_model(p_source_model text,p_new_model text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_count integer;
begin
  if public.current_app_role()<>'admin' then raise exception 'Только администратор может изменять расценки'; end if;
  if nullif(trim(p_new_model),'') is null then raise exception 'Укажите название новой модели'; end if;
  if exists(select 1 from public.operation_catalog where model=trim(p_new_model)) then raise exception 'Такая модель уже существует'; end if;
  insert into public.operation_catalog(model,operation_name,sequence_no,sewer_price,client_price,active)
    select trim(p_new_model),operation_name,sequence_no,sewer_price,client_price,active
    from public.operation_catalog where model=p_source_model;
  get diagnostics v_count=row_count;
  if v_count=0 then raise exception 'Исходная модель не найдена'; end if;
  return jsonb_build_object('success',true,'message','Модель скопирована','count',v_count);
end; $$;

revoke all on function public.get_catalog_admin() from public,anon;
revoke all on function public.save_catalog_operation(bigint,text,text,integer,numeric,numeric,boolean) from public,anon;
revoke all on function public.copy_catalog_model(text,text) from public,anon;
grant execute on function public.get_catalog_admin() to authenticated;
grant execute on function public.save_catalog_operation(bigint,text,text,integer,numeric,numeric,boolean) to authenticated;
grant execute on function public.copy_catalog_model(text,text) to authenticated;
