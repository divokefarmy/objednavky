# Provisioning an admin user

After this branch is merged, the only way to access the admin overlay is to log in as a Supabase user whose JWT carries `app_metadata.role = 'admin'`. There is no shared password anymore.

This is a **one-time setup per admin person**. The steps below need the Supabase service-role key (only the project owner has it via the dashboard) — that's the whole point: regular users cannot self-promote.

## Prerequisite: apply the RLS migration

Open the Supabase SQL editor for the project and run [`supabase/migrations/01_admin_rls.sql`](../supabase/migrations/01_admin_rls.sql) once. This creates `public.is_admin()` and locks down `product_state`, `orders` (writes), and `delivery_notes` (everything) to admins only.

**Do not skip this step.** Without it, the new login gate only changes the UI; the anon key still has full write access at the API level.

## Make a user admin (Supabase dashboard)

1. Have the user sign up through the app's "Registrovat" link (or create them in Supabase → Authentication → Users → "Add user").
2. In the Supabase dashboard go to **Authentication → Users** and click the user.
3. Edit **Raw User App Meta Data** (the `app_metadata` field — *not* `user_metadata`, which the user can edit themselves).
4. Set it to:
   ```json
   { "role": "admin" }
   ```
   If there's already content in `app_metadata`, merge in `"role": "admin"` without removing the rest.
5. Save. The user must log out and back in for the new JWT to include the claim.

That's it — they can now click "⚙ Správa skladu", be sent through the login modal, and the admin overlay opens.

## Verify it actually works

After setting the flag and re-logging:

1. Click "⚙ Správa skladu" in the topbar — admin overlay should open without any password prompt.
2. Open DevTools → Application → Local Storage → find the Supabase auth entry. Decode the JWT (e.g. paste the access token at jwt.io). The payload should contain `"app_metadata": { "role": "admin", … }`.
3. As a non-admin (different account or logged out), call `openAdmin()` from the DevTools console. The UI opens — that's expected — but try to save anything: the request should fail with a Postgres RLS error like *"new row violates row-level security policy for table product_state"*. That's the actual security boundary doing its job.

## Revoking admin

Edit the same user's `app_metadata` and remove `"role": "admin"` (or set it to anything else). Force the user to re-login to get a fresh JWT — until they do, their existing token still has admin claims for up to the token TTL (default 1 hour).

For an emergency revoke, also delete the user's sessions in **Authentication → Users → [user] → Sessions**.
