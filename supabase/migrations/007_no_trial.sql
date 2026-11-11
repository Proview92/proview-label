-- 007: no free trials. Every new business starts with no licence (NO_TRIAL_SPEC, owner 11 Nov 2026).
--
-- Owner: "make all businesses start with inactive, they must purchase a license" / "No trials at all".
--
-- Before (003): self sign-up (pl_start_trial) gave a 3-day trial (pl_orgs.trial_ends_at), once per email
-- (pl_trials). Businesses the master added (pl_add_business, pl_create_org, and the licence portal's
-- hub_call 'add_business', which runs pl_add_business) had trial_ends_at null, i.e. fully open.
--
-- Now:
-- * pl_orgs.licensed: false = "no licence yet". Existing businesses get true (unchanged); the column then
--   defaults to false, so EVERY new business, however it is inserted, starts with no licence.
-- * pl_org_locked: suspended, OR not licensed, OR trial ended. So a business with no licence gets the existing
--   locked behaviour: no writes (pl_can_write), back-office shows the lock banner, and the handheld shows its
--   full lock screen (printing and syncing paused). The master still works inside it (x-pl-org, migration 004).
-- * pl_whoami reports licensed / no_licence, and locked now includes "no licence". trial_used is always false:
--   the one-trial-per-email record (pl_trials) is no longer written or checked (the table is left in place).
-- * pl_start_trial ("Set up your business", name kept so the app keeps working): business + first location +
--   the caller as Owner, with no licence and no trial.
-- * sso_entitled: "Sign in with Proview account" no longer refuses an email because it had a trial before.
-- * The master grants or removes the licence: pl_set_licence(org, licensed, trial_ends). pl_set_trial (the
--   old Trial... button) still works and now also grants the licence, as clearing/setting a trial did before.
-- * Only Proview can change licensed (pl_orgs_guard), as for suspended / trial_ends_at.
-- Existing businesses are NOT changed: anything on a trial today keeps its trial_ends_at.
-- A Label licence belongs to the business, so a location added later has no licence of its own to give.

alter table public.pl_orgs add column if not exists licensed boolean not null default true;   -- existing: unchanged
alter table public.pl_orgs alter column licensed set default false;                          -- new: no licence
comment on column public.pl_orgs.licensed is
  'false = no licence yet (locked like an ended licence). Default for every business created after migration 007 (no trials). Set by the Proview master only.';

create or replace function public.pl_org_locked(p_org text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pl_orgs where id = p_org
                   and (suspended or not licensed or (trial_ends_at is not null and trial_ends_at < now()))) $$;

create or replace function public.pl_orgs_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or public.pl_is_master() then return new; end if;   -- backend / service role, or master
  if new.suspended is distinct from old.suspended or new.trial_ends_at is distinct from old.trial_ends_at
     or new.trial_email is distinct from old.trial_email or new.licensed is distinct from old.licensed then
    raise exception 'Only Proview can change a business''s licence or trial.';
  end if;
  return new;
end $$;

-- "Set up your business" (self sign-up): business, first location, the caller as Owner. No licence, no trial.
create or replace function public.pl_start_trial(p_business text, p_site text default null) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare em text; uid uuid := auth.uid(); oid text; sid text; bn text := trim(coalesce(p_business,'')); sn text := trim(coalesce(p_site,''));
begin
  if uid is null then raise exception 'Sign in first.'; end if;
  em := public.pl_my_email();
  if em is null then raise exception 'Confirm your email first: open the link we emailed you.'; end if;
  if public.pl_is_master() or exists (select 1 from public.pl_masters where email = em) then raise exception 'The Proview master adds businesses from Locations.'; end if;
  if exists (select 1 from public.pl_members where user_id = uid or email = em) then
    raise exception 'ALREADY_MEMBER: Your login is already linked to a business. Sign in again to open it.'; end if;
  if length(bn) < 1 or length(bn) > 120 then raise exception 'Enter your business name.'; end if;
  if sn = '' then sn := bn; end if;
  if length(sn) > 120 then raise exception 'Keep the site name under 120 characters.'; end if;
  -- trial_email marks a self sign-up (the licence portal's list reports it as self_signup)
  insert into public.pl_orgs(name, licensed, trial_ends_at, trial_email) values (bn, false, null, em) returning id into oid;
  insert into public.pl_members(org_id, email, user_id, name, role)
    values (oid, em, uid, coalesce((select raw_user_meta_data->>'name' from auth.users where id = uid), ''), 'owner');
  sid := 'site_' || substr(replace(gen_random_uuid()::text,'-',''), 1, 12);
  insert into public.pl_records(id, org_id, site_id, kind, data)
    values (sid, oid, sid, 'sites', jsonb_build_object('id', sid, 'orgId', oid, 'name', sn, 'address', '', 'region', ''));
  return jsonb_build_object('org_id', oid, 'site_id', sid, 'trial_ends_at', null, 'licensed', false);
end $$;

-- Master: give (licensed = true, optionally with an end date, which works like a trial end) or remove the licence.
create or replace function public.pl_set_licence(p_org text, p_licensed boolean, p_ends timestamptz default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.pl_is_master() then raise exception 'Only a Proview master can change a licence.'; end if;
  update public.pl_orgs set licensed = coalesce(p_licensed, false),
         trial_ends_at = case when coalesce(p_licensed, false) then p_ends else null end
   where id = p_org;
  if not found then raise exception 'Business not found.'; end if;
end $$;

-- Master (older Trial... button): set an end date, or clear it. Either way the business is licensed.
create or replace function public.pl_set_trial(p_org text, p_ends timestamptz) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.pl_is_master() then raise exception 'Only a Proview master can change a trial.'; end if;
  update public.pl_orgs set trial_ends_at = p_ends, licensed = true where id = p_org;
  if not found then raise exception 'Business not found.'; end if;
end $$;

create or replace function public.pl_whoami() returns jsonb language plpgsql security definer set search_path = public as $$
declare em text; is_m boolean; d public.pl_devices;
begin
  if auth.uid() is null then return null; end if;
  d := public.pl_device_me();
  if d.id is not null then
    return jsonb_build_object('email', null, 'master', false, 'trial_used', false,
      'device', jsonb_build_object('id', d.id, 'name', d.name, 'mode', d.mode, 'site_id', d.site_id, 'org_id', d.org_id),
      'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 'trial_ends_at', o.trial_ends_at,
                 'trial_expired', o.trial_ends_at is not null and o.trial_ends_at < now(),
                 'licensed', o.licensed, 'no_licence', not o.licensed,
                 'locked', o.suspended or not o.licensed or (o.trial_ends_at is not null and o.trial_ends_at < now()),
                 'role', 'device', 'site_ids', jsonb_build_array(d.site_id), 'member_id', null, 'features', '{}'::jsonb))
               from public.pl_orgs o where o.id = d.org_id), '[]'::jsonb));
  end if;
  em := public.pl_my_email();
  if em is not null then perform public.pl_link(auth.uid(), em); end if;
  is_m := public.pl_is_master();
  return jsonb_build_object('email', em, 'master', is_m,
    'trial_used', false,   -- kept so older app builds still offer "Set up your business"; no longer used
    'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 'trial_ends_at', o.trial_ends_at,
                 'trial_expired', o.trial_ends_at is not null and o.trial_ends_at < now(),
                 'licensed', o.licensed, 'no_licence', not o.licensed,
                 'locked', o.suspended or not o.licensed or (o.trial_ends_at is not null and o.trial_ends_at < now()),
                 'role', case when is_m then 'master' else m.role end, 'site_ids', coalesce(m.site_ids, '{}'), 'member_id', m.id,
                 'features', case when is_m or m.role in ('owner','admin') then '{}'::jsonb else coalesce(m.features, '{}'::jsonb) end) order by o.name)
               from public.pl_orgs o left join public.pl_members m on m.org_id = o.id and m.user_id = auth.uid()
               where is_m or m.id is not null), '[]'::jsonb));
end $$;

-- "Sign in with Proview account": masters, members of a business that isn't suspended (even with no licence, so the
-- owner reaches the licence message), and anyone with no business yet (so they reach "Set up your business").
create or replace function public.sso_entitled(p_email text) returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare uid uuid; em text := lower(trim(p_email));
begin
  select id into uid from auth.users where lower(email) = em order by created_at limit 1;
  if exists (select 1 from public.pl_masters where email = em)
     or exists (select 1 from public.pl_members m join public.pl_orgs o on o.id = m.org_id where m.email = em and not o.suspended)
     or not exists (select 1 from public.pl_members where email = em) then
    return jsonb_build_object('ok', true, 'user_id', uid, 'create', uid is null);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'No Proview Label account for this email.');
end $$;

revoke execute on function public.pl_orgs_guard(), public.sso_entitled(text) from public, anon, authenticated;
grant execute on function public.sso_entitled(text) to service_role;
revoke execute on function public.pl_org_locked(text), public.pl_start_trial(text, text), public.pl_set_trial(text, timestamptz),
  public.pl_set_licence(text, boolean, timestamptz) from public, anon;
grant execute on function public.pl_org_locked(text), public.pl_start_trial(text, text), public.pl_set_trial(text, timestamptz),
  public.pl_set_licence(text, boolean, timestamptz) to authenticated;
