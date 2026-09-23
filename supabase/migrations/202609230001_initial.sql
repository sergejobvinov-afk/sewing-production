create extension if not exists pgcrypto;

do $$ begin create type public.app_role as enum ('admin', 'master', 'sewer', 'accountant');
exception when duplicate_object then null; end $$;
do $$ begin create type public.pack_status as enum ('new', 'issued', 'partially_accepted', 'accepted', 'annulled');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  display_name text not null,
  role public.app_role not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.packs (
  id text primary key,
  cut_date date not null,
  model text not null,
  size text not null,
  quantity integer not null check (quantity > 0),
  passport_no text not null,
  color text not null default '',
  status public.pack_status not null default 'new',
  annul_reason text,
  version integer not null default 1,
  created_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint annul_reason_required check (status <> 'annulled' or length(trim(annul_reason)) >= 3)
);

create table if not exists public.operation_catalog (
  id bigint generated always as identity primary key,
  model text not null,
  operation_name text not null,
  sequence_no integer not null default 0,
  sewer_price numeric(12,2) not null default 0 check (sewer_price >= 0),
  client_price numeric(12,2) not null default 0 check (client_price >= 0),
  active boolean not null default true,
  unique (model, operation_name)
);

create table if not exists public.pack_operations (
  id bigint generated always as identity primary key,
  pack_id text not null references public.packs(id) on delete restrict,
  catalog_operation_id bigint references public.operation_catalog(id) on delete restrict,
  operation_name text not null,
  sewer_id uuid references public.profiles(id) on delete restrict,
  sewer_name text,
  issued_qty integer not null default 0 check (issued_qty >= 0),
  accepted_qty integer not null default 0 check (accepted_qty >= 0 and accepted_qty <= issued_qty),
  issued_at timestamptz,
  accepted_at timestamptz,
  sewer_price numeric(12,2) not null default 0 check (sewer_price >= 0),
  unique (pack_id, operation_name)
);

create table if not exists public.pack_events (
  id bigint generated always as identity primary key,
  pack_id text not null references public.packs(id) on delete restrict,
  event_type text not null,
  actor_id uuid references public.profiles(id) on delete restrict,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists packs_cut_date_idx on public.packs (cut_date desc);
create index if not exists packs_status_idx on public.packs (status);
create index if not exists packs_model_idx on public.packs (model);
create index if not exists pack_operations_pack_idx on public.pack_operations (pack_id);
create index if not exists pack_operations_sewer_idx on public.pack_operations (sewer_id);
create index if not exists pack_events_pack_time_idx on public.pack_events (pack_id, created_at desc);

create or replace function public.current_app_role()
returns public.app_role language sql stable security definer set search_path = public
as $$ select role from public.profiles where id = auth.uid() and active = true $$;

alter table public.profiles enable row level security;
alter table public.packs enable row level security;
alter table public.operation_catalog enable row level security;
alter table public.pack_operations enable row level security;
alter table public.pack_events enable row level security;

drop policy if exists profiles_read_self_or_management on public.profiles;
create policy profiles_read_self_or_management on public.profiles for select to authenticated
using (id = auth.uid() or public.current_app_role() in ('admin','master'));
drop policy if exists packs_read_authenticated on public.packs;
create policy packs_read_authenticated on public.packs for select to authenticated using (true);
drop policy if exists catalog_read_authenticated on public.operation_catalog;
create policy catalog_read_authenticated on public.operation_catalog for select to authenticated using (true);
drop policy if exists operations_read_authenticated on public.pack_operations;
create policy operations_read_authenticated on public.pack_operations for select to authenticated
using (public.current_app_role() in ('admin','master','accountant') or sewer_id = auth.uid());
drop policy if exists events_read_management on public.pack_events;
create policy events_read_management on public.pack_events for select to authenticated
using (public.current_app_role() in ('admin','master'));

revoke insert, update, delete, truncate on public.profiles, public.packs, public.operation_catalog, public.pack_operations, public.pack_events from anon, authenticated;
grant select on public.profiles, public.packs, public.operation_catalog, public.pack_operations, public.pack_events to authenticated;

create or replace view public.pack_kpi with (security_invoker = true) as
select p.id, p.cut_date, p.model, p.size, p.quantity, p.passport_no, p.color, p.status,
  coalesce(sum(po.issued_qty), 0)::integer as issued_operations_qty,
  coalesce(sum(po.accepted_qty), 0)::integer as accepted_operations_qty,
  p.updated_at
from public.packs p left join public.pack_operations po on po.pack_id = p.id
group by p.id;
grant select on public.pack_kpi to authenticated;
