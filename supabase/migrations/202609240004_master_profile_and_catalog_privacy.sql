-- Профиль мастера и запрет чтения цены клиента из браузера.
insert into public.profiles(id,display_name,role,active)
values ('383bb4e1-c19a-4c4f-bf85-c6cbcb754c1b','Виктория','master',true)
on conflict(id) do update set display_name=excluded.display_name,role=excluded.role,active=true,updated_at=now();

revoke select on public.operation_catalog from authenticated;
grant select(id,model,operation_name,sequence_no,sewer_price,active) on public.operation_catalog to authenticated;
