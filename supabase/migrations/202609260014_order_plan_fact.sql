alter table public.packs add column if not exists production_order_id bigint references public.production_orders(id) on delete set null;
create index if not exists packs_production_order_idx on public.packs(production_order_id);

create or replace function public.assign_packs_to_order(p_order_id bigint,p_pack_ids text[])
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_order public.production_orders; v_count integer;
begin
  if public.current_app_role() not in ('admin','accountant') then raise exception 'Недостаточно прав'; end if;
  select * into v_order from public.production_orders where id=p_order_id;
  if not found then raise exception 'Заказ не найден'; end if;
  if exists(select 1 from public.packs where id=any(p_pack_ids) and model<>v_order.model) then
    raise exception 'Все пачки должны соответствовать модели заказа';
  end if;
  if exists(select 1 from public.packs where id=any(p_pack_ids) and production_order_id is not null and production_order_id<>p_order_id) then
    raise exception 'Одна из пачек уже относится к другому заказу';
  end if;
  update public.packs set production_order_id=p_order_id,updated_at=now() where id=any(p_pack_ids) and status<>'annulled';
  get diagnostics v_count=row_count;
  return jsonb_build_object('success',true,'message','К заказу привязано пачек: '||v_count);
end; $$;

create or replace function public.unassign_pack_from_order(p_order_id bigint,p_pack_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if public.current_app_role() not in ('admin','accountant') then raise exception 'Недостаточно прав'; end if;
  update public.packs set production_order_id=null,updated_at=now() where id=p_pack_id and production_order_id=p_order_id;
  return jsonb_build_object('success',true,'message','Пачка отвязана от заказа');
end; $$;

create or replace function public.get_production_order_report(p_order_id bigint)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_role public.app_role; v_order public.production_orders; v_stats jsonb; v_linked jsonb; v_candidates jsonb;
begin
  select public.current_app_role() into v_role;
  if v_role not in ('admin','accountant') then raise exception 'Недостаточно прав'; end if;
  select * into v_order from public.production_orders where id=p_order_id;
  if not found then raise exception 'Заказ не найден'; end if;

  select jsonb_build_object(
    'packCount',count(*),'cutQty',coalesce(sum(quantity),0),
    'issuedPacks',count(*) filter(where status in ('issued','partially_accepted','accepted')),
    'issuedQty',coalesce(sum(quantity) filter(where status in ('issued','partially_accepted','accepted')),0),
    'inWorkPacks',count(*) filter(where status in ('issued','partially_accepted')),
    'inWorkQty',coalesce(sum(quantity) filter(where status in ('issued','partially_accepted')),0),
    'acceptedPacks',count(*) filter(where status='accepted'),
    'acceptedQty',coalesce(sum(quantity) filter(where status='accepted'),0),
    'remainingQty',greatest(v_order.order_qty-coalesce(sum(quantity) filter(where status='accepted'),0),0)
  ) into v_stats from public.packs where production_order_id=p_order_id and status<>'annulled';

  v_stats:=v_stats||coalesce((select jsonb_build_object(
    'operationRevenue',coalesce(sum(po.accepted_qty*po.client_price),0),
    'sewerAccrued',coalesce(sum(po.accepted_qty*po.sewer_price),0),
    'sewerPaid',coalesce(sum(po.paid_qty*po.sewer_price),0),
    'clientPaid',coalesce(sum(po.client_paid_qty*po.client_price),0),
    'acceptedOperationQty',coalesce(sum(po.accepted_qty),0)
  ) from public.pack_operations po join public.packs p on p.id=po.pack_id where p.production_order_id=p_order_id),'{}'::jsonb);

  select coalesce(jsonb_agg(jsonb_build_object('id',id,'passport',passport_no,'dateCut',cut_date,'size',size,'qty',quantity,
    'status',status) order by cut_date desc,id desc),'[]'::jsonb) into v_linked
    from public.packs where production_order_id=p_order_id and status<>'annulled';
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'passport',passport_no,'dateCut',cut_date,'size',size,'qty',quantity,
    'status',status) order by cut_date desc,id desc),'[]'::jsonb) into v_candidates
    from (select * from public.packs where production_order_id is null and model=v_order.model and status<>'annulled' order by cut_date desc,id desc limit 200) p;

  return jsonb_build_object('success',true,'order',jsonb_build_object('id',v_order.id,'name',v_order.name,'model',v_order.model,
    'qty',v_order.order_qty,'clientPrice',v_order.client_price_gross,'unitCost',v_order.unit_cost,'plannedDays',v_order.planned_days,
    'plannedProfit',v_order.net_profit,'plannedMargin',v_order.margin_percent),'stats',v_stats,'linkedPacks',v_linked,'candidatePacks',v_candidates);
end; $$;

revoke all on function public.assign_packs_to_order(bigint,text[]) from public,anon;
revoke all on function public.unassign_pack_from_order(bigint,text) from public,anon;
revoke all on function public.get_production_order_report(bigint) from public,anon;
grant execute on function public.assign_packs_to_order(bigint,text[]) to authenticated;
grant execute on function public.unassign_pack_from_order(bigint,text) to authenticated;
grant execute on function public.get_production_order_report(bigint) to authenticated;
