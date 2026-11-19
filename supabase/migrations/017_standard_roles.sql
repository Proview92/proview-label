-- 017 (owner, 20 Nov 2026): the standard Proview roles and sign-in check, the same in every Proview app.
--   Roles of a business: admin, manager, staff (nothing else). The Proview master stays the master (pl_masters).
--   "owner" is gone: every owner becomes admin, and an admin can do everything an owner could. Label gains "staff":
--   a login like a manager (ticked locations, feature switches), shown as Staff. Device staff (PIN users on the
--   handhelds) are a separate thing and are not changed.
--   Sign-in check (sso_entitled), as Proview WiFi's rules, with account wording:
--     on hold -> "This Proview Label account is on hold. Contact Proview."
--     master, or a member of a business (paused or not) -> let in (a missing login is made)
--     anyone else -> "No Proview Label account for this email."
-- Safe to run more than once.

-- 1) data
update public.pl_members set role = 'admin' where lower(role) = 'owner';

-- 2) only admin / manager / staff
do $c$
declare r record;
begin
  for r in select conname from pg_constraint where conrelid = 'public.pl_members'::regclass and contype = 'c'
            and pg_get_constraintdef(oid) ~* 'role' loop
    execute format('alter table public.pl_members drop constraint %I', r.conname);
  end loop;
  alter table public.pl_members add constraint pl_members_role_check check (role in ('admin', 'manager', 'staff'));
end $c$;

-- 3) the two pl_members policies that knew 'owner'
drop policy if exists "members admin write" on public.pl_members;
create policy "members admin write" on public.pl_members for insert
  with check (pl_is_org_admin(org_id));
drop policy if exists "members admin update" on public.pl_members;
create policy "members admin update" on public.pl_members for update
  using (pl_is_org_admin(org_id)) with check (pl_is_org_admin(org_id));

-- 4) every function that knew 'owner' now reads 'admin'; staff is scoped like a manager (texts reworded)
do $f$
declare r record; d text; n text;
begin
  for r in select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace
            where s.nspname in ('public', 'hub_private') and p.prokind = 'f' and p.prosrc ~* 'owner|manager' loop
    d := pg_get_functiondef(r.oid); n := d;
    -- the role list the licence portal shows: Admin / Manager / Staff
    n := replace(n, '{"value": "owner", "label": "Owner"}, ', '');
    n := replace(n, '{"value": "manager", "label": "Manager"}]', '{"value": "manager", "label": "Manager"}, {"value": "staff", "label": "Staff"}]');
    -- link ranking
    n := replace(n, '{"owner":3,"admin":2,"manager":1}', '{"admin":3,"manager":2,"staff":1}');
    -- unlink: staff logins are scoped like managers
    n := replace(n, 'case when m.role = ''manager'' then array[s.id]', 'case when m.role in (''manager'', ''staff'') then array[s.id]');
    n := replace(n, '(m.role <> ''manager'' or s.id = any(m.site_ids))', '(m.role not in (''manager'', ''staff'') or s.id = any(m.site_ids))');
    n := replace(n, 'where org_id = a.id and role = ''manager'' and s.id = any(site_ids)', 'where org_id = a.id and role in (''manager'', ''staff'') and s.id = any(site_ids)');
    -- messages
    n := replace(n, 'This is the only owner of the business. Add another owner first.', 'This is the only admin of the business. Add another admin first.');
    n := replace(n, 'Enter the owner''''s name.', 'Enter the admin''''s name.');
    -- the role itself
    n := replace(n, '''owner''', '''admin''');
    if n <> d then execute n; end if;
  end loop;
end $f$;

-- 5) the standard sign-in check
create or replace function public.sso_entitled(p_email text) returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare uid uuid; ban timestamptz; em text := lower(trim(p_email));
begin
  select id, banned_until into uid, ban from auth.users
   where lower(email) = em and not coalesce(is_anonymous, false) order by created_at limit 1;
  if ban > now() then return jsonb_build_object('ok', false, 'reason', 'This Proview Label account is on hold. Contact Proview.'); end if;
  if exists (select 1 from public.pl_masters where email = em) or exists (select 1 from public.pl_members where email = em) then
    return jsonb_build_object('ok', true, 'user_id', uid, 'create', uid is null);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'No Proview Label account for this email.');
end $$;
revoke execute on function public.sso_entitled(text) from public, anon, authenticated;
grant execute on function public.sso_entitled(text) to service_role;
