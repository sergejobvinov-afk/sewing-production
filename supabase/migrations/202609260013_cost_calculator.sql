create table if not exists public.cost_settings (
  id boolean primary key default true check (id),
  vat_rate numeric(8,6) not null default 0.05 check (vat_rate >= 0 and vat_rate < 1),
  tax_rate numeric(8,6) not null default 0.06 check (tax_rate >= 0 and tax_rate < 1),
  rent_monthly numeric(14,2) not null default 326392 check (rent_monthly >= 0),
  electricity_monthly numeric(14,2) not null default 15000 check (electricity_monthly >= 0),
  parking_monthly numeric(14,2) not null default 7500 check (parking_monthly >= 0),
  staff_salary_monthly numeric(14,2) not null default 550000 check (staff_salary_monthly >= 0),
  workdays_monthly integer not null default 22 check (workdays_monthly > 0),
  total_sewers integer not null default 9 check (total_sewers > 0),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

insert into public.cost_settings(id) values(true) on conflict(id) do nothing;

create table if not exists public.production_orders (
  id bigint generated always as identity primary key,
  name text not null,
  model text not null,
  order_qty integer not null check (order_qty > 0),
  client_price_gross numeric(14,2) not null check (client_price_gross >= 0),
  assigned_sewers integer not null check (assigned_sewers > 0),
  productivity_per_sewer integer not null check (productivity_per_sewer > 0),
  materials_per_item numeric(14,2) not null default 0 check (materials_per_item >= 0),
  vat_rate numeric(8,6) not null,
  tax_rate numeric(8,6) not null,
  piecework_per_item numeric(14,2) not null,
  planned_days integer not null,
  fixed_cost_share numeric(14,2) not null,
  total_cost numeric(14,2) not null,
  unit_cost numeric(14,2) not null,
  net_revenue numeric(14,2) not null,
  tax_amount numeric(14,2) not null,
  net_profit numeric(14,2) not null,
  margin_percent numeric(10,2) not null,
  status text not null default 'draft' check(status in ('draft','planned','in_production','completed','cancelled')),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id)
);

alter table public.cost_settings enable row level security;
alter table public.production_orders enable row level security;

create or replace function public.get_cost_calculator_data()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_role public.app_role; v_settings jsonb; v_models jsonb; v_orders jsonb;
begin
  select public.current_app_role() into v_role;
  if v_role not in ('admin','accountant') then raise exception 'Недостаточно прав'; end if;
  select to_jsonb(s)-'id'-'updated_by' into v_settings from public.cost_settings s where id=true;
  select coalesce(jsonb_agg(jsonb_build_object('model',model,'sewerPrice',sewer_price,'clientPrice',client_price) order by model),'[]'::jsonb)
    into v_models from (select model,round(sum(sewer_price),2) sewer_price,round(sum(client_price),2) client_price
      from public.operation_catalog where active=true group by model) x;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'model',model,'qty',order_qty,'clientPrice',client_price_gross,
    'unitCost',unit_cost,'profit',net_profit,'margin',margin_percent,'days',planned_days,'status',status,'createdAt',created_at)
    order by created_at desc),'[]'::jsonb) into v_orders from (select * from public.production_orders order by created_at desc limit 20) o;
  return jsonb_build_object('success',true,'settings',v_settings,'models',v_models,'orders',v_orders);
end; $$;

create or replace function public.save_cost_settings(p_settings jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if public.current_app_role()<>'admin' then raise exception 'Только администратор может изменять расходы'; end if;
  update public.cost_settings set
    vat_rate=(p_settings->>'vatRate')::numeric,
    tax_rate=(p_settings->>'taxRate')::numeric,
    rent_monthly=(p_settings->>'rentMonthly')::numeric,
    electricity_monthly=(p_settings->>'electricityMonthly')::numeric,
    parking_monthly=(p_settings->>'parkingMonthly')::numeric,
    staff_salary_monthly=(p_settings->>'staffSalaryMonthly')::numeric,
    workdays_monthly=(p_settings->>'workdaysMonthly')::integer,
    total_sewers=(p_settings->>'totalSewers')::integer,
    updated_at=now(),updated_by=auth.uid() where id=true;
  return jsonb_build_object('success',true,'message','Настройки расходов сохранены');
end; $$;

create or replace function public.save_production_order(p_order jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id bigint;
begin
  if public.current_app_role() not in ('admin','accountant') then raise exception 'Недостаточно прав'; end if;
  insert into public.production_orders(name,model,order_qty,client_price_gross,assigned_sewers,productivity_per_sewer,
    materials_per_item,vat_rate,tax_rate,piecework_per_item,planned_days,fixed_cost_share,total_cost,unit_cost,
    net_revenue,tax_amount,net_profit,margin_percent)
  values(trim(p_order->>'name'),trim(p_order->>'model'),(p_order->>'qty')::integer,(p_order->>'clientPrice')::numeric,
    (p_order->>'assignedSewers')::integer,(p_order->>'productivity')::integer,(p_order->>'materials')::numeric,
    (p_order->>'vatRate')::numeric,(p_order->>'taxRate')::numeric,(p_order->>'piecework')::numeric,
    (p_order->>'days')::integer,(p_order->>'fixedShare')::numeric,(p_order->>'totalCost')::numeric,
    (p_order->>'unitCost')::numeric,(p_order->>'netRevenue')::numeric,(p_order->>'taxAmount')::numeric,
    (p_order->>'netProfit')::numeric,(p_order->>'margin')::numeric) returning id into v_id;
  return jsonb_build_object('success',true,'message','Расчёт заказа сохранён','id',v_id);
end; $$;

revoke all on function public.get_cost_calculator_data() from public,anon;
revoke all on function public.save_cost_settings(jsonb) from public,anon;
revoke all on function public.save_production_order(jsonb) from public,anon;
grant execute on function public.get_cost_calculator_data() to authenticated;
grant execute on function public.save_cost_settings(jsonb) to authenticated;
grant execute on function public.save_production_order(jsonb) to authenticated;
