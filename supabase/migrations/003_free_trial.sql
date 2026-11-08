-- Proview Label: 3-day free trial for people who sign up on their own (owner decision, 8 Nov 2026).
--
--  * pl_orgs.trial_ends_at: null = normal (licensed) business. Set = trial; after that moment the business is
--    treated exactly like a suspended one (pl_can_write blocks every write, the apps show "Trial ended").
--  * pl_trials: one row per email that has ever started a trial. Kept even if the business is deleted,
--    so the same email can't start a second trial.
--  * pl_start_trial(p_business, p_site): server-side self sign-up. Creates the business, makes the caller its
--    Owner, creates the first site record, starts a 3-day trial.
--  * pl_set_trial(p_org, p_ends): master only. Extend (new date) or clear (null = no longer a trial).
--  * Only the master (or the backend / service role) can change suspended / trial fields: owners could
--    previously update their own pl_orgs row, which would have let them clear their own trial.

alter table public.pl_orgs add column if not exists trial_ends_at timestamptz;
alter table public.pl_orgs add column if not exists trial_email text;

create table if not exists public.pl_trials (
  email text primary key check (email = lower(email)),
  org_id text,
  user_id uuid,
  started_at timestamptz not null default now()
);
alter table public.pl_trials enable row level security;
revoke all on public.pl_trials from public, anon, authenticated;
grant all on public.pl_trials to service_role;

-- true when the business can't be changed: suspended, or its trial has ended
create or replace function public.pl_org_locked(p_org text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pl_orgs where id = p_org and (suspended or (trial_ends_at is not null and trial_ends_at < now()))) $$;

create or replace function public.pl_can_write(p_org text, p_site text, p_kind text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare m public.pl_members; f text;
begin
  if auth.uid() is null then return false; end if;
  if public.pl_is_master() then return true; end if;
  if public.pl_org_locked(p_org) then return false; end if;    -- suspended or trial ended
  m := public.pl_member(p_org);
  if m.id is null then return false; end if;
  if m.role in ('owner','admin') then return true; end if;
  if p_kind = 'sites' then return false; end if;              -- managers can't add or edit sites
  f := public.pl_write_feature(p_kind);
  if f is not null and not coalesce((m.features ->> f)::boolean, true) then return false; end if;
  return p_site is null or p_site = any(m.site_ids);
end $$;

-- Owners/admins may rename their business and change its settings, but never its licence/trial state.
create or replace function public.pl_orgs_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or public.pl_is_master() then return new; end if;   -- backend / service role, or master
  if new.suspended is distinct from old.suspended or new.trial_ends_at is distinct from old.trial_ends_at
     or new.trial_email is distinct from old.trial_email then
    raise exception 'Only Proview can change a business''s licence or trial.';
  end if;
  return new;
end $$;
drop trigger if exists pl_orgs_guard on public.pl_orgs;
create trigger pl_orgs_guard before update on public.pl_orgs for each row execute function public.pl_orgs_guard();

-- Blocked trial-ended businesses also can't rename or change settings (same as a write).
drop policy if exists "orgs admin update" on public.pl_orgs;
create policy "orgs admin update" on public.pl_orgs for update to authenticated
  using (public.pl_is_master() or (public.pl_is_org_admin(id) and not public.pl_org_locked(id)))
  with check (public.pl_is_master() or (public.pl_is_org_admin(id) and not public.pl_org_locked(id)));

create or replace function public.pl_start_trial(p_business text, p_site text default null) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare em text; uid uuid := auth.uid(); oid text; sid text; bn text := trim(coalesce(p_business,'')); sn text := trim(coalesce(p_site,'')); ends timestamptz;
begin
  if uid is null then raise exception 'Sign in first.'; end if;
  em := public.pl_my_email();
  if em is null then raise exception 'Confirm your email first: open the link we emailed you.'; end if;
  if public.pl_is_master() or exists (select 1 from public.pl_masters where email = em) then raise exception 'The Proview master doesn''t need a trial.'; end if;
  if exists (select 1 from public.pl_members where user_id = uid or email = em) then
    raise exception 'ALREADY_MEMBER: Your login is already linked to a business. Sign in again to open it.'; end if;
  if length(bn) < 1 or length(bn) > 120 then raise exception 'Enter your business name.'; end if;
  if sn = '' then sn := bn; end if;
  if length(sn) > 120 then raise exception 'Keep the site name under 120 characters.'; end if;
  -- one trial per email (primary key also stops two at once)
  begin
    insert into public.pl_trials(email, user_id) values (em, uid);
  exception when unique_violation then
    raise exception 'TRIAL_USED: The free trial for % has already been used. Buy a licence at https://license.proviewcrm.co.uk or contact Proview on 020 8935 5495 / info@proviewtechgroup.co.uk.', em;
  end;
  ends := now() + interval '3 days';
  insert into public.pl_orgs(name, trial_ends_at, trial_email) values (bn, ends, em) returning id into oid;
  update public.pl_trials set org_id = oid where email = em;
  insert into public.pl_members(org_id, email, user_id, name, role)
    values (oid, em, uid, coalesce((select raw_user_meta_data->>'name' from auth.users where id = uid), ''), 'owner');
  sid := 'site_' || substr(replace(gen_random_uuid()::text,'-',''), 1, 12);
  insert into public.pl_records(id, org_id, site_id, kind, data)
    values (sid, oid, sid, 'sites', jsonb_build_object('id', sid, 'orgId', oid, 'name', sn, 'address', '', 'region', ''));
  return jsonb_build_object('org_id', oid, 'site_id', sid, 'trial_ends_at', ends);
end $$;

create or replace function public.pl_set_trial(p_org text, p_ends timestamptz) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.pl_is_master() then raise exception 'Only a Proview master can change a trial.'; end if;
  update public.pl_orgs set trial_ends_at = p_ends where id = p_org;
  if not found then raise exception 'Business not found.'; end if;
end $$;

-- whoami: also each business's trial end + whether it is locked, and whether this email can still start a trial
create or replace function public.pl_whoami() returns jsonb language plpgsql security definer set search_path = public as $$
declare em text; is_m boolean;
begin
  if auth.uid() is null then return null; end if;
  em := public.pl_my_email();
  if em is not null then perform public.pl_link(auth.uid(), em); end if;
  is_m := public.pl_is_master();
  return jsonb_build_object('email', em, 'master', is_m,
    'trial_used', em is not null and exists (select 1 from public.pl_trials t where t.email = em),
    'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 'trial_ends_at', o.trial_ends_at,
                 'trial_expired', o.trial_ends_at is not null and o.trial_ends_at < now(),
                 'locked', o.suspended or (o.trial_ends_at is not null and o.trial_ends_at < now()),
                 'role', case when is_m then 'master' else m.role end, 'site_ids', coalesce(m.site_ids, '{}'), 'member_id', m.id,
                 'features', case when is_m or m.role in ('owner','admin') then '{}'::jsonb else coalesce(m.features, '{}'::jsonb) end) order by o.name)
               from public.pl_orgs o left join public.pl_members m on m.org_id = o.id and m.user_id = auth.uid()
               where is_m or m.id is not null), '[]'::jsonb));
end $$;

-- "Sign in with Proview account": also let in someone with no business yet who hasn't used their trial,
-- so they reach the "Start your free 3-day trial" screen. Trial-ended members can still sign in (they see the message).
create or replace function public.sso_entitled(p_email text) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare uid uuid; em text := lower(trim(p_email));
begin
  select id into uid from auth.users where lower(email) = em order by created_at limit 1;
  if exists (select 1 from public.pl_masters where email = em)
     or exists (select 1 from public.pl_members m join public.pl_orgs o on o.id = m.org_id where m.email = em and not o.suspended)
     or (not exists (select 1 from public.pl_members where email = em) and not exists (select 1 from public.pl_trials where email = em)) then
    return jsonb_build_object('ok', true, 'user_id', uid, 'create', uid is null);
  end if;
  if exists (select 1 from public.pl_trials where email = em) and not exists (select 1 from public.pl_members where email = em) then
    return jsonb_build_object('ok', false, 'reason', 'Your free trial has already been used. Buy a licence at license.proviewcrm.co.uk or contact Proview.');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'No Proview Label account for this email.');
end $$;

revoke execute on function public.pl_orgs_guard(), public.sso_entitled(text) from public, anon, authenticated;
grant execute on function public.sso_entitled(text) to service_role;
revoke execute on function public.pl_org_locked(text), public.pl_start_trial(text, text), public.pl_set_trial(text, timestamptz) from public, anon;
grant execute on function public.pl_org_locked(text), public.pl_start_trial(text, text), public.pl_set_trial(text, timestamptz) to authenticated;
