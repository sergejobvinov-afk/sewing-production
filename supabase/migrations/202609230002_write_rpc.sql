create or replace function public.require_management_role()
returns public.app_role
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role public.app_role;
begin
  select role into v_role from public.profiles where id = auth.uid() and active = true;
  if v_role not in ('admin', 'master') then
    raise exception 'Недостаточно прав';
  end if;
  return v_role;
end;
$$;

create or replace function public.create_pack(
  p_model text, p_size text, p_quantity integer, p_passport_no text default '', p_color text default ''
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_number integer;
  v_id text;
  v_passport text;
begin
  perform public.require_management_role();
  if nullif(trim(p_model), '') is null or nullif(trim(p_size), '') is null or p_quantity <= 0 then
    raise exception 'Проверьте модель, размер и количество';
  end if;
  if not exists (select 1 from public.operation_catalog where model = trim(p_model) and active) then
    raise exception 'Модель не найдена в справочнике операций';
  end if;
  perform pg_advisory_xact_lock(hashtext('public.packs.sequence'));
  select coalesce(max((regexp_match(id, '(\d+)$'))[1]::integer), 0) + 1 into v_number from public.packs;
  v_id := 'KR-' || extract(year from current_date)::integer || '-' || lpad(v_number::text, 6, '0');
  v_passport := coalesce(nullif(trim(p_passport_no), ''), 'П-' || lpad(v_number::text, 3, '0'));
  insert into public.packs(id, cut_date, model, size, quantity, passport_no, color, created_by)
  values (v_id, current_date, trim(p_model), trim(p_size), p_quantity, v_passport, coalesce(trim(p_color), ''), auth.uid());
  insert into public.pack_events(pack_id, event_type, actor_id, payload)
  values (v_id, 'Новая', auth.uid(), jsonb_build_object('source', 'supabase', 'quantity', p_quantity));
  return jsonb_build_object('success', true, 'message', 'Пачка создана', 'id', v_id,
    'dateCut', current_date, 'model', trim(p_model), 'size', trim(p_size), 'qty', p_quantity,
    'passport', v_passport, 'color', coalesce(trim(p_color), ''), 'status', 'Новая',
    'operations', (select coalesce(jsonb_agg(operation_name order by sequence_no, id), '[]'::jsonb)
                   from public.operation_catalog where model = trim(p_model) and active));
end;
$$;

create or replace function public.issue_pack(p_pack_id text, p_operations jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pack public.packs%rowtype;
  v_item jsonb;
  v_name text;
  v_sewer text;
  v_price numeric(12,2);
begin
  perform public.require_management_role();
  select * into v_pack from public.packs where id = p_pack_id for update;
  if not found then raise exception 'Пачка не найдена'; end if;
  if v_pack.status <> 'new' then raise exception 'Выдать можно только новую пачку'; end if;
  if jsonb_typeof(p_operations) <> 'array' or jsonb_array_length(p_operations) = 0 then
    raise exception 'Не указаны операции';
  end if;
  for v_item in select value from jsonb_array_elements(p_operations) loop
    v_name := nullif(trim(v_item->>'operationName'), '');
    v_sewer := nullif(trim(v_item->>'sewerName'), '');
    if v_name is null or v_sewer is null then raise exception 'Для каждой операции укажите швею'; end if;
    select sewer_price into v_price from public.operation_catalog
      where model = v_pack.model and operation_name = v_name and active;
    if not found then raise exception 'Операция % не найдена для модели %', v_name, v_pack.model; end if;
    insert into public.pack_operations(pack_id, operation_name, sewer_name, issued_qty, accepted_qty, issued_at, sewer_price)
    values (v_pack.id, v_name, v_sewer, v_pack.quantity, 0, now(), v_price)
    on conflict(pack_id, operation_name) do update set sewer_name=excluded.sewer_name,
      issued_qty=excluded.issued_qty, accepted_qty=0, issued_at=excluded.issued_at,
      accepted_at=null, sewer_price=excluded.sewer_price;
  end loop;
  update public.packs set status='issued', version=version+1, updated_at=now() where id=v_pack.id;
  insert into public.pack_events(pack_id,event_type,actor_id,payload)
  values(v_pack.id,'Выдано',auth.uid(),jsonb_build_object('operations',p_operations,'quantity',v_pack.quantity));
  return jsonb_build_object('success',true,'message','Пачка выдана в пошив');
end;
$$;

create or replace function public.accept_pack(p_pack_id text, p_operations jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pack public.packs%rowtype;
  v_item jsonb;
  v_name text;
  v_qty integer;
  v_status public.pack_status;
begin
  perform public.require_management_role();
  select * into v_pack from public.packs where id=p_pack_id for update;
  if not found then raise exception 'Пачка не найдена'; end if;
  if v_pack.status not in ('issued','partially_accepted') then raise exception 'Пачка не выдана в пошив'; end if;
  if jsonb_typeof(p_operations) <> 'array' or jsonb_array_length(p_operations)=0 then raise exception 'Не указано количество приёмки'; end if;
  for v_item in select value from jsonb_array_elements(p_operations) loop
    v_name := nullif(trim(v_item->>'operationName'), '');
    v_qty := coalesce((v_item->>'acceptedQty')::integer, 0);
    if v_qty <= 0 then raise exception 'Количество приёмки должно быть больше нуля'; end if;
    update public.pack_operations set accepted_qty=accepted_qty+v_qty,
      accepted_at=case when accepted_qty+v_qty=issued_qty then now() else accepted_at end
      where pack_id=v_pack.id and operation_name=v_name and accepted_qty+v_qty<=issued_qty;
    if not found then raise exception 'Операция % не найдена или количество превышает выданное', v_name; end if;
  end loop;
  if exists(select 1 from public.pack_operations where pack_id=v_pack.id and issued_qty>0 and accepted_qty<issued_qty) then
    v_status := 'partially_accepted';
  else
    v_status := 'accepted';
  end if;
  update public.packs set status=v_status,version=version+1,updated_at=now() where id=v_pack.id;
  insert into public.pack_events(pack_id,event_type,actor_id,payload)
  values(v_pack.id,'Принято',auth.uid(),jsonb_build_object('operations',p_operations,'status',v_status));
  return jsonb_build_object('success',true,'message',case when v_status='accepted' then 'Пачка полностью принята' else 'Приёмка сохранена' end);
end;
$$;

create or replace function public.cancel_pack_issue(p_pack_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_pack public.packs%rowtype;
begin
  perform public.require_management_role();
  select * into v_pack from public.packs where id=p_pack_id for update;
  if not found then raise exception 'Пачка не найдена'; end if;
  if v_pack.status not in ('issued','partially_accepted') then raise exception 'Пачка не находится в пошиве'; end if;
  if exists(select 1 from public.pack_operations where pack_id=p_pack_id and accepted_qty>0) then
    raise exception 'Нельзя отменить выдачу после приёмки ОТК';
  end if;
  delete from public.pack_operations where pack_id=p_pack_id;
  update public.packs set status='new',version=version+1,updated_at=now() where id=p_pack_id;
  insert into public.pack_events(pack_id,event_type,actor_id,payload) values(p_pack_id,'Отмена выдачи',auth.uid(),'{}');
  return jsonb_build_object('success',true,'message','Выдача отменена');
end; $$;

create or replace function public.edit_pack(
  p_pack_id text,p_cut_date date,p_model text,p_size text,p_quantity integer,p_passport_no text,p_color text
) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform public.require_management_role();
  if p_quantity<=0 or nullif(trim(p_model),'') is null or nullif(trim(p_size),'') is null then raise exception 'Проверьте данные паспорта'; end if;
  update public.packs set cut_date=p_cut_date,model=trim(p_model),size=trim(p_size),quantity=p_quantity,
    passport_no=coalesce(nullif(trim(p_passport_no),''),passport_no),color=coalesce(trim(p_color),''),version=version+1,updated_at=now()
    where id=p_pack_id and status='new';
  if not found then raise exception 'Изменять можно только новую пачку'; end if;
  insert into public.pack_events(pack_id,event_type,actor_id,payload) values(p_pack_id,'Изменение паспорта',auth.uid(),'{}');
  return jsonb_build_object('success',true,'message','Паспорт изменён');
end; $$;

create or replace function public.annul_pack(p_pack_id text,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform public.require_management_role();
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'Укажите причину аннулирования'; end if;
  update public.packs set status='annulled',annul_reason=trim(p_reason),version=version+1,updated_at=now()
    where id=p_pack_id and status='new';
  if not found then raise exception 'Аннулировать можно только новую пачку'; end if;
  insert into public.pack_events(pack_id,event_type,actor_id,payload)
    values(p_pack_id,'Аннулирована',auth.uid(),jsonb_build_object('reason',trim(p_reason)));
  return jsonb_build_object('success',true,'message','Паспорт аннулирован');
end; $$;

revoke all on function public.require_management_role() from public, anon;
revoke all on function public.create_pack(text,text,integer,text,text) from public, anon;
revoke all on function public.issue_pack(text,jsonb) from public, anon;
revoke all on function public.accept_pack(text,jsonb) from public, anon;
revoke all on function public.cancel_pack_issue(text) from public, anon;
revoke all on function public.edit_pack(text,date,text,text,integer,text,text) from public, anon;
revoke all on function public.annul_pack(text,text) from public, anon;
grant execute on function public.create_pack(text,text,integer,text,text) to authenticated;
grant execute on function public.issue_pack(text,jsonb) to authenticated;
grant execute on function public.accept_pack(text,jsonb) to authenticated;
grant execute on function public.cancel_pack_issue(text) to authenticated;
grant execute on function public.edit_pack(text,date,text,text,integer,text,text) to authenticated;
grant execute on function public.annul_pack(text,text) to authenticated;
