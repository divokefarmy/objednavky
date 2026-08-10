-- Gated "Maso" category: permissioned category + configurable meat products.
-- Apply in the Supabase SQL editor after 01_admin_rls.sql.
--
-- Design: category access is a general, scalable table
-- (user_category_permissions) rather than a single boolean, so future
-- restricted categories reuse the same mechanism. Meat products/marinades
-- live in their own tables (not the hardcoded `P` array in js/app.js)
-- specifically so RLS can hide them server-side from users without access —
-- the static array is shipped to every browser and can't be gated.

-- ── user_category_permissions ──────────────────────────────────────────
create table if not exists public.user_category_permissions (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null,
  enabled boolean not null default true,
  granted_by uuid references auth.users(id),
  granted_at timestamptz not null default now(),
  unique(user_id, category)
);

alter table public.user_category_permissions enable row level security;

drop policy if exists "ucp admin all" on public.user_category_permissions;
create policy "ucp admin all"
  on public.user_category_permissions for all
  using (public.is_admin())
  with check (public.is_admin());

-- A signed-in user can read their own grants (client uses this to decide
-- whether to unlock a category).
drop policy if exists "ucp read own" on public.user_category_permissions;
create policy "ucp read own"
  on public.user_category_permissions for select
  using (auth.uid() = user_id);

-- Helper: does the current request have access to a given category?
-- Admins implicitly have access to everything.
create or replace function public.has_category_access(cat text)
returns boolean
language sql stable
as $$
  select coalesce(
    public.is_admin()
    or exists(
      select 1 from public.user_category_permissions ucp
      where ucp.user_id = auth.uid() and ucp.category = cat and ucp.enabled
    ),
    false
  );
$$;

-- ── meat_products ───────────────────────────────────────────────────────
-- Analogous to an entry in the `P` catalog array, but stored server-side so
-- it can be select-gated. Priced per kg only (no per-piece VOC) — Maso is
-- sold by weight. voc_kg defaults to 0; prices are TBD, set later via admin.
create table if not exists public.meat_products (
  id bigint generated always as identity primary key,
  name text not null,
  voc_kg numeric not null default 0,
  active boolean not null default true,
  sort int not null default 0
);

alter table public.meat_products enable row level security;

drop policy if exists "meat_products read gated" on public.meat_products;
create policy "meat_products read gated"
  on public.meat_products for select
  using (public.has_category_access('maso'));

drop policy if exists "meat_products admin write" on public.meat_products;
create policy "meat_products admin write"
  on public.meat_products for all
  using (public.is_admin())
  with check (public.is_admin());

insert into public.meat_products (name, sort)
select v.name, v.sort from (values
  ('Krkovice', 1), ('Kotleta', 2), ('Bok', 3), ('Žebra', 4),
  ('Plec', 5), ('Kýta', 6), ('Panenka', 7)
) as v(name, sort)
where not exists (select 1 from public.meat_products);

-- ── marinades ────────────────────────────────────────────────────────────
-- Admin-managed list (not hardcoded in app.js), gated the same as the
-- category itself.
create table if not exists public.marinades (
  id bigint generated always as identity primary key,
  name text not null,
  active boolean not null default true,
  sort int not null default 0
);

alter table public.marinades enable row level security;

drop policy if exists "marinades read gated" on public.marinades;
create policy "marinades read gated"
  on public.marinades for select
  using (public.has_category_access('maso'));

drop policy if exists "marinades admin write" on public.marinades;
create policy "marinades admin write"
  on public.marinades for all
  using (public.is_admin())
  with check (public.is_admin());

insert into public.marinades (name, sort)
select v.name, v.sort from (values
  ('Marináda 1', 1), ('Marináda 2', 2), ('Marináda 3', 3), ('Marináda 4', 4)
) as v(name, sort)
where not exists (select 1 from public.marinades);

-- ── admin_list_users RPC ──────────────────────────────────────────────────
-- The client can't query auth.users directly. This security-definer RPC
-- exposes just enough (id/email/created_at + granted categories) for the
-- admin "Uživatelé" tab, and is itself gated by is_admin() inside the query
-- body — a non-admin caller gets zero rows even though the function runs
-- with elevated privileges.
create or replace function public.admin_list_users()
returns table(id uuid, email text, created_at timestamptz, categories text[])
language sql
security definer
set search_path = public
as $$
  select u.id, u.email, u.created_at,
    coalesce(array_agg(ucp.category) filter (where ucp.enabled), '{}') as categories
  from auth.users u
  left join public.user_category_permissions ucp on ucp.user_id = u.id
  where public.is_admin()
  group by u.id, u.email, u.created_at
  order by u.created_at desc;
$$;

revoke all on function public.admin_list_users() from public;
grant execute on function public.admin_list_users() to authenticated;

-- ── orders: server-side guard for Maso items ──────────────────────────────
-- Defense in depth: even if the UI were bypassed, an order containing an
-- item tagged cat:'Maso' can only be inserted by a user with access.
create or replace function public.check_meat_order_permission()
returns trigger
language plpgsql
as $$
declare
  has_meat boolean;
begin
  select exists(
    select 1 from jsonb_array_elements(coalesce(new.items, '[]'::jsonb)) it
    where (it->>'cat') = 'Maso'
  ) into has_meat;

  if has_meat and not public.has_category_access('maso') then
    raise exception 'No permission for category Maso';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_check_meat_order on public.orders;
create trigger trg_check_meat_order
  before insert on public.orders
  for each row execute function public.check_meat_order_permission();
