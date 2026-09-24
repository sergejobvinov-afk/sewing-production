-- Массовое создание пачек мастером с автоматическими ID и номерами паспортов.
create or replace function public.create_packs_bulk(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_item jsonb; v_number integer; v_id text; v_passport text; v_model text; v_size text;
  v_color text; v_qty integer; v_cut_date date; v_created jsonb:='[]'::jsonb; v_operations jsonb;
begin
  perform public.require_management_role();
  if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)=0 then raise exception 'Добавьте хотя бы одну строку'; end if;
  if jsonb_array_length(p_rows)>100 then raise exception 'За один раз можно создать не более 100 пачек'; end if;
  perform pg_advisory_xact_lock(hashtext('public.packs.sequence'));
  select coalesce(max((regexp_match(id,'(\d+)$'))[1]::integer),0) into v_number from public.packs;
  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    v_model:=nullif(trim(v_item->>'model'),''); v_size:=nullif(trim(v_item->>'size'),'');
    v_color:=coalesce(trim(v_item->>'color'),''); v_qty:=coalesce((v_item->>'qty')::integer,0);
    v_cut_date:=coalesce(nullif(v_item->>'cutDate','')::date,current_date);
    if v_model is null or v_size is null or v_qty<=0 then raise exception 'Проверьте модель, размер и количество во всех строках'; end if;
    if not exists(select 1 from public.operation_catalog where model=v_model and active) then raise exception 'Модель % не найдена в справочнике',v_model; end if;
    v_number:=v_number+1;
    v_id:='KR-'||extract(year from v_cut_date)::integer||'-'||lpad(v_number::text,6,'0');
    v_passport:='П-'||lpad(v_number::text,3,'0');
    select coalesce(jsonb_agg(operation_name order by sequence_no,id),'[]'::jsonb) into v_operations
      from public.operation_catalog where model=v_model and active;
    insert into public.packs(id,cut_date,model,size,quantity,passport_no,color,created_by)
      values(v_id,v_cut_date,v_model,v_size,v_qty,v_passport,v_color,auth.uid());
    insert into public.pack_events(pack_id,event_type,actor_id,payload)
      values(v_id,'Новая',auth.uid(),jsonb_build_object('source','bulk','quantity',v_qty));
    v_created:=v_created||jsonb_build_array(jsonb_build_object('success',true,'id',v_id,'dateCut',v_cut_date,
      'model',v_model,'size',v_size,'qty',v_qty,'passport',v_passport,'color',v_color,'status','Новая','operations',v_operations));
  end loop;
  return jsonb_build_object('success',true,'message','Создано пачек: '||jsonb_array_length(v_created),'packs',v_created);
end; $$;

revoke all on function public.create_packs_bulk(jsonb) from public,anon;
grant execute on function public.create_packs_bulk(jsonb) to authenticated;
