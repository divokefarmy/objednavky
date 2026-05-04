-- Admin RLS policies. Apply this in the Supabase SQL editor BEFORE merging
-- the feat/admin-supabase-auth branch. Without these policies the new auth
-- gate is purely cosmetic — anyone with the anon key can still write.
--
-- Admin identity: a user whose JWT has app_metadata.role = 'admin'.
-- app_metadata is only writable by the service role (i.e. through the
-- Supabase dashboard or with the service-role key), so users cannot
-- self-promote. See docs/admin-setup.md for how to flip this flag.

-- Helper: is the current request authenticated as an admin?
create or replace function public.is_admin()
returns boolean
language sql stable
as $$
  select coalesce(
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin',
    false
  );
$$;

-- ── product_state ───────────────────────────────────────────────────
-- Anyone can read (the customer form needs availability/prices).
-- Only admins can write.
alter table public.product_state enable row level security;

drop policy if exists "product_state read" on public.product_state;
create policy "product_state read"
  on public.product_state for select
  using (true);

drop policy if exists "product_state admin write" on public.product_state;
create policy "product_state admin write"
  on public.product_state for all
  using (public.is_admin())
  with check (public.is_admin());

-- ── orders ──────────────────────────────────────────────────────────
-- Anyone (incl. anon) can create an order via the form.
-- The signed-in customer can read their own orders. Admin reads everything.
-- Only admin can update/delete (status changes, archiving, soft-delete).
alter table public.orders enable row level security;

drop policy if exists "orders insert any" on public.orders;
create policy "orders insert any"
  on public.orders for insert
  with check (true);

drop policy if exists "orders read own or admin" on public.orders;
create policy "orders read own or admin"
  on public.orders for select
  using (
    public.is_admin()
    or (auth.uid() is not null and auth.uid() = user_id)
  );

drop policy if exists "orders admin update" on public.orders;
create policy "orders admin update"
  on public.orders for update
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "orders admin delete" on public.orders;
create policy "orders admin delete"
  on public.orders for delete
  using (public.is_admin());

-- ── delivery_notes ──────────────────────────────────────────────────
-- Internal document — admin only for everything.
alter table public.delivery_notes enable row level security;

drop policy if exists "delivery_notes admin all" on public.delivery_notes;
create policy "delivery_notes admin all"
  on public.delivery_notes for all
  using (public.is_admin())
  with check (public.is_admin());
