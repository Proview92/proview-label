-- 009: a licence per LOCATION, set from the licence portal, plus "Buy online" (LABEL_LICENCE_SPEC + owner's correction,
-- PER_LOCATION_LICENCE_SPEC, 11 Nov 2026: "A licence does not cover the whole business; additional locations require an
-- additional licence").
--
-- Before (007): one licence per business (pl_orgs.licensed + an optional end date in pl_orgs.trial_ends_at). The licence
-- portal could not see or set it (008's hub 'list' sent no units, 'set' was refused).
--
-- Now:
-- * public.pl_site_licences: one row per location (the pl_records kind='sites' row), with licence_type, licence_starts_at,
--   licence_expires_at and notes. Types: the portal's set (m1, m3, m6, m12, m24, m36, lifetime, custom) plus 'trial'
--   (Label's own trial, set by hand by the master). Every type except lifetime has an end date.
--   A separate table, not a field in the site's jsonb: owners and admins write their pl_records 'sites' rows through sync,
--   so a licence kept there could be self-granted or overwritten. Nobody can write this table directly; only the master's
--   functions and the licence portal's hub_call (token) change it.
-- * A location is OPEN when the business isn't suspended, the location isn't deleted, and it has a licence that is
--   lifetime or ends in the future. Otherwise it is locked: no writes for that location (pl_can_write), its handhelds
--   lock (pl_whoami reports the location's state to the handheld) and pairing a handheld there is refused. Other
--   locations of the same business keep working.
-- * Business-wide data (records with no location, the business's own row, adding / renaming locations) can be written
--   while at least one of the business's locations is open. pl_org_locked(org) now means "suspended, or no location open".
-- * A new location (owner's + Add location, pl_add_business, pl_start_trial, hub 'add_business') has no row here, so it
--   starts with no licence (NO_TRIAL_SPEC).
-- * Existing locations: every live location of a business that is licensed today with no end date becomes LIFETIME;
--   one licensed with an end date (a trial set by hand) becomes 'trial' ending on that date; a business with no licence
--   gets nothing. Done once, when the table is created, so a re-run never licenses a location added later.
-- * pl_orgs.licensed and pl_orgs.trial_ends_at (migrations 003 / 007) are RETIRED: nothing decides anything from them
--   any more. The columns stay (and pl_orgs_guard still protects them) so older code that writes them keeps working.
--   pl_whoami still reports licensed / no_licence / trial_ends_at / trial_expired / locked per business, now DERIVED from
--   the locations (see pl_whoami below), so every reader of those fields keeps working.
-- * pl_set_licence(org, ...) and pl_set_trial(org, ...) (older back-office builds) now apply to every live location of
--   the business. The new per-location button calls pl_set_site_licence.
-- * Licence portal: hub_call 'list' returns one unit per location (kind 'location', account_id = the business);
--   'set' sets a location's licence; 'add_business' (008) is unchanged. hub_plans stores the prices the portal sends;
--   pl_plans() lets the back-office show "Buy online" (Stripe client_reference_id pvl__<site id>__<plan>).
-- Safe to run more than once.

-- 1) per-location licences, and the one-off conversion of today's business licences
do $m$
declare n_life int := 0; n_trial int := 0; n_none int := 0;
begin
  if to_regclass('public.pl_site_licences') is null then
    create table public.pl_site_licences(
      site_id text primary key,
      org_id text not null references public.pl_orgs(id) on delete cascade,
      licence_type text check (licence_type in ('trial','m1','m3','m6','m12','m24','m36','lifetime','custom')),
      licence_starts_at timestamptz,
      licence_expires_at timestamptz,
      notes text,
      updated_at timestamptz not null default now(),
      check (licence_type is null or licence_type = 'lifetime' or licence_expires_at is not null));
    create index pl_site_licences_org on public.pl_site_licences(org_id);

    insert into public.pl_site_licences(site_id, org_id, licence_type, licence_starts_at, licence_expires_at, notes)
    select r.id, r.org_id,
           case when o.trial_ends_at is null then 'lifetime' else 'trial' end,
           now(), o.trial_ends_at, 'Licensed before per-location licences (migration 009)'
      from public.pl_records r join public.pl_orgs o on o.id = r.org_id
     where r.kind = 'sites' and not r.deleted and o.licensed
    on conflict (site_id) do nothing;
    select count(*) filter (where licence_type = 'lifetime'), count(*) filter (where licence_type = 'trial')
      into n_life, n_trial from public.pl_site_licences;
    select count(*) into n_none from public.pl_records r
     where r.kind = 'sites' and not r.deleted and not exists (select 1 from public.pl_site_licences l where l.site_id = r.id);
    raise notice 'pl_site_licences created: % location(s) lifetime, % on a trial, % with no licence', n_life, n_trial, n_none;
  end if;
end $m$;
alter table public.pl_site_licences enable row level security;
revoke all on table public.pl_site_licences from public, anon, authenticated;
comment on table public.pl_site_licences is
  'Licence of each location (pl_records kind=sites). No row / null licence_type = no licence. Written only by pl_set_site_licence (master) and hub_call (licence portal).';
comment on column public.pl_orgs.licensed is
  'RETIRED by migration 009 (licences are per location, pl_site_licences). Not read by any check; pl_whoami derives licensed from the locations.';
comment on column public.pl_orgs.trial_ends_at is
  'RETIRED by migration 009 (licences are per location, pl_site_licences). Not read by any check.';

-- 2) is a location open? (business not suspended, location live, licence lifetime or not yet ended)
create or replace function public.pl_site_open(p_org text, p_site text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pl_records r
                   join public.pl_orgs o on o.id = r.org_id
                   join public.pl_site_licences l on l.site_id = r.id
                  where r.id = p_site and r.kind = 'sites' and not r.deleted and r.org_id = p_org and not o.suspended
                    and l.licence_type is not null and (l.licence_type = 'lifetime' or l.licence_expires_at > now())) $$;

-- the business: locked when suspended or none of its locations is open
create or replace function public.pl_org_locked(p_org text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pl_orgs o where o.id = p_org
                   and (o.suspended or not exists (select 1 from public.pl_records r where r.org_id = o.id and r.kind = 'sites'
                                                     and not r.deleted and public.pl_site_open(o.id, r.id)))) $$;

-- 3) writes: a locked location can't be changed; business-wide data needs at least one open location
create or replace function public.pl_can_write(p_org text, p_site text, p_kind text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare m public.pl_members; d public.pl_devices; f text;
begin
  if auth.uid() is null then return false; end if;
  if public.pl_is_master() then return public.pl_master_in(p_org); end if;
  d := public.pl_device_me();
  if d.id is not null then   -- a handheld: only while its own location is open
    if not public.pl_site_open(d.org_id, d.site_id) then return false; end if;
    return p_org = d.org_id and p_kind <> 'sites' and (p_site is null or p_site = d.site_id);
  end if;
  if p_site is not null and p_kind <> 'sites' then
    if not public.pl_site_open(p_org, p_site) then return false; end if;   -- this location: no licence / ended
  elsif public.pl_org_locked(p_org) then
    return false;                                                          -- business-wide: suspended or nothing open
  end if;
  m := public.pl_member(p_org);
  if m.id is null then return false; end if;
  if m.role in ('owner','admin') then return true; end if;
  if p_kind = 'sites' then return false; end if;
  f := public.pl_write_feature(p_kind);
  if f is not null and not coalesce((m.features ->> f)::boolean, true) then return false; end if;
  return p_site is null or p_site = any(m.site_ids);
end $$;

-- 4) one location's licence as the apps and the portal see it
create or replace function hub_private.pl_site_lic_json(p_site text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', r.id, 'name', coalesce(r.data->>'name', ''),
           'licence_type', l.licence_type, 'licence_starts_at', l.licence_starts_at, 'licence_expires_at', l.licence_expires_at,
           'licensed', public.pl_site_open(r.org_id, r.id),
           'no_licence', l.licence_type is null,
           'expired', l.licence_type is not null and l.licence_type <> 'lifetime' and l.licence_expires_at <= now(),
           'locked', not public.pl_site_open(r.org_id, r.id))
    from public.pl_records r left join public.pl_site_licences l on l.site_id = r.id
   where r.id = p_site and r.kind = 'sites' $$;
revoke all on function hub_private.pl_site_lic_json(text) from public, anon, authenticated;

-- 5) set a location's licence (used by the master's button and by the portal). type null = remove the licence.
--    Like the other apps: extend adds the time to a licence that is still running; custom needs an end date;
--    trial = 3 days, or until p_expires when given (the master's "trial set by hand").
create or replace function hub_private.pl_apply_site_licence(p_site text, p_type text, p_extend boolean, p_expires timestamptz, p_notes text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.pl_records; cur public.pl_site_licences; base timestamptz; new_exp timestamptz; t text := nullif(trim(coalesce(p_type, '')), '');
  nt text := nullif(trim(coalesce(p_notes, '')), '');
begin
  select * into r from public.pl_records where id = p_site and kind = 'sites' and not deleted;
  if r.id is null then raise exception 'Location not found'; end if;
  insert into public.pl_site_licences(site_id, org_id) values (r.id, r.org_id) on conflict (site_id) do nothing;
  select * into cur from public.pl_site_licences where site_id = r.id for update;
  if t is null then
    update public.pl_site_licences set licence_type = null, licence_starts_at = null, licence_expires_at = null,
           notes = coalesce(nt, notes), updated_at = now() where site_id = r.id;
  else
    if t = 'lifetime' then new_exp := null;
    elsif t = 'custom' then
      if p_expires is null then raise exception 'Choose an end date.'; end if;
      new_exp := p_expires;
    elsif t = 'trial' and p_expires is not null then new_exp := p_expires;
    else
      base := case when coalesce(p_extend, false) and cur.licence_type is distinct from 'lifetime' and cur.licence_expires_at > now()
                   then cur.licence_expires_at else now() end;
      new_exp := base + case t when 'trial' then interval '3 days' when 'm1' then interval '1 month' when 'm3' then interval '3 months'
        when 'm6' then interval '6 months' when 'm12' then interval '12 months' when 'm24' then interval '24 months'
        when 'm36' then interval '36 months' else null end;
      if new_exp is null then raise exception 'Unknown licence type %', t; end if;
    end if;
    update public.pl_site_licences set licence_type = t,
           licence_starts_at = case when coalesce(p_extend, false) and licence_starts_at is not null then licence_starts_at else now() end,
           licence_expires_at = new_exp, notes = coalesce(nt, notes), updated_at = now()
     where site_id = r.id;
  end if;
  select * into cur from public.pl_site_licences where site_id = r.id;
  return jsonb_build_object('id', r.id, 'kind', 'location', 'license_type', cur.licence_type, 'starts_at', cur.licence_starts_at,
                            'expires_at', cur.licence_expires_at, 'notes', cur.notes);
end $$;
revoke all on function hub_private.pl_apply_site_licence(text, text, boolean, timestamptz, text) from public, anon, authenticated;

-- master (Locations → Licence… on each location)
create or replace function public.pl_set_site_licence(p_site text, p_type text, p_expires timestamptz default null,
  p_extend boolean default false, p_notes text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.pl_is_master() then raise exception 'Only a Proview master can change a licence.'; end if;
  return hub_private.pl_apply_site_licence(p_site, p_type, p_extend, p_expires, p_notes);
end $$;

-- older back-office builds: the business's licence = every live location of it
create or replace function public.pl_set_licence(p_org text, p_licensed boolean, p_ends timestamptz default null) returns void
language plpgsql security definer set search_path = public as $$
declare s text;
begin
  if not public.pl_is_master() then raise exception 'Only a Proview master can change a licence.'; end if;
  if not exists (select 1 from public.pl_orgs where id = p_org) then raise exception 'Business not found.'; end if;
  for s in select id from public.pl_records where org_id = p_org and kind = 'sites' and not deleted loop
    perform hub_private.pl_apply_site_licence(s, case when not coalesce(p_licensed, false) then null when p_ends is null then 'lifetime' else 'trial' end,
                                              false, p_ends, null);
  end loop;
end $$;
create or replace function public.pl_set_trial(p_org text, p_ends timestamptz) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.pl_is_master() then raise exception 'Only a Proview master can change a trial.'; end if;
  perform public.pl_set_licence(p_org, true, p_ends);
end $$;

-- 6) whoami: each business with its locations' licences. The business-level fields are derived from the locations:
--    licensed = at least one location open; locked = suspended or none open. A HANDHELD gets its own location's state in
--    those same fields (so its lock screen, unchanged, locks exactly when its location is locked).
create or replace function public.pl_whoami() returns jsonb language plpgsql security definer set search_path = public as $$
declare em text; is_m boolean; d public.pl_devices; dl jsonb;
begin
  if auth.uid() is null then return null; end if;
  d := public.pl_device_me();
  if d.id is not null then
    dl := coalesce(hub_private.pl_site_lic_json(d.site_id), jsonb_build_object('licensed', false, 'no_licence', true, 'expired', false));
    return jsonb_build_object('email', null, 'master', false, 'trial_used', false,
      'device', jsonb_build_object('id', d.id, 'name', d.name, 'mode', d.mode, 'site_id', d.site_id, 'org_id', d.org_id),
      'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 -- an ended licence reads as an ended trial on older handheld builds (same lock, same "Check again")
                 'trial_ends_at', case when (dl->>'expired')::boolean then dl->>'licence_expires_at' end,
                 'trial_expired', coalesce((dl->>'expired')::boolean, false),
                 'licensed', not coalesce((dl->>'no_licence')::boolean, true), 'no_licence', coalesce((dl->>'no_licence')::boolean, true),
                 'locked', o.suspended or not public.pl_site_open(o.id, d.site_id),
                 'sites', jsonb_build_array(dl),
                 'role', 'device', 'site_ids', jsonb_build_array(d.site_id), 'member_id', null, 'features', '{}'::jsonb))
               from public.pl_orgs o where o.id = d.org_id), '[]'::jsonb));
  end if;
  em := public.pl_my_email();
  if em is not null then perform public.pl_link(auth.uid(), em); end if;
  is_m := public.pl_is_master();
  return jsonb_build_object('email', em, 'master', is_m,
    'trial_used', false,   -- kept so older app builds still offer "Set up your business"; no longer used
    'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'settings', o.settings, 'suspended', o.suspended,
                 -- derived: no location open and at least one had a licence that ended = "ended" (older builds: trial ended);
                 -- no location open and none ever licensed = "no licence"
                 'trial_ends_at', case when x.locked and x.had then x.last_end end,
                 'trial_expired', x.locked and x.had,
                 'licensed', not x.locked or (o.suspended and x.had), 'no_licence', x.locked and not o.suspended and not x.had,
                 'locked', x.locked,
                 'sites', coalesce((select jsonb_agg(hub_private.pl_site_lic_json(r.id) order by lower(coalesce(r.data->>'name', '')))
                                      from public.pl_records r where r.org_id = o.id and r.kind = 'sites' and not r.deleted
                                       and (is_m or m.role in ('owner','admin') or r.id = any(coalesce(m.site_ids, '{}')))), '[]'::jsonb),
                 'role', case when is_m then 'master' else m.role end, 'site_ids', coalesce(m.site_ids, '{}'), 'member_id', m.id,
                 'features', case when is_m or m.role in ('owner','admin') then '{}'::jsonb else coalesce(m.features, '{}'::jsonb) end) order by o.name)
               from public.pl_orgs o left join public.pl_members m on m.org_id = o.id and m.user_id = auth.uid()
               cross join lateral (select public.pl_org_locked(o.id) as locked,
                   exists (select 1 from public.pl_site_licences l join public.pl_records r on r.id = l.site_id and not r.deleted
                            where l.org_id = o.id and l.licence_type is not null) as had,
                   (select max(l.licence_expires_at) from public.pl_site_licences l join public.pl_records r on r.id = l.site_id and not r.deleted
                     where l.org_id = o.id and l.licence_type is not null) as last_end) x
               where is_m or m.id is not null), '[]'::jsonb));
end $$;

-- 7) licence portal: 'list' (accounts + one unit per location) and 'set' (a location). 'add_business' stays in
--    public.hub_call (008), which passes every other action to this base.
create or replace function hub_private.hub_call_base(p_token text, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare k text := nullif(p_args->>'kind', '');
begin
  if p_token is null or encode(extensions.digest(p_token, 'sha256'), 'hex') is distinct from (select token_sha256 from hub_private.config where id = 1) then
    raise exception 'not authorised';
  end if;
  if p_action = 'list' then
    return jsonb_build_object(
      'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name,
                    'contact_email', (select lower(m.email) from public.pl_members m where m.org_id = o.id and m.role in ('owner', 'manager')
                                       order by m.role = 'owner' desc, m.created_at limit 1),
                    'created_at', o.created_at, 'self_signup', o.trial_email is not null, 'suspended', o.suspended)
                  order by lower(o.name)) from public.pl_orgs o), '[]'::jsonb),
      'units', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'kind', 'location', 'account_id', r.org_id,
                    'name', coalesce(r.data->>'name', ''), 'detail', o.name,
                    'license_type', l.licence_type, 'starts_at', l.licence_starts_at, 'expires_at', l.licence_expires_at,
                    'notes', l.notes, 'last_seen', null, 'archived', false)
                  order by lower(coalesce(r.data->>'name', '')), r.id)
                  from public.pl_records r join public.pl_orgs o on o.id = r.org_id
                  left join public.pl_site_licences l on l.site_id = r.id
                 where r.kind = 'sites' and not r.deleted), '[]'::jsonb));
  elsif p_action = 'set' then
    if k is not null and k <> 'location' then raise exception 'Proview Label only has location licences (kind %).', k; end if;
    return hub_private.pl_apply_site_licence(p_args->>'unit', nullif(p_args->>'type', ''), coalesce((p_args->>'extend')::boolean, false),
                                             nullif(p_args->>'expires', '')::timestamptz, p_args->>'notes');
  else
    raise exception 'unknown action %', p_action;
  end if;
end $$;
revoke all on function hub_private.hub_call_base(text, text, jsonb) from public, anon, authenticated;

-- prices sent by the licence portal (Stripe Payment Links), shown to owners as "Buy online"
create or replace function public.hub_plans(p_token text, p_plans jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_token is null or encode(extensions.digest(p_token, 'sha256'), 'hex') is distinct from (select token_sha256 from hub_private.config where id = 1) then
    raise exception 'not authorised';
  end if;
  update hub_private.config set plans = coalesce(p_plans, '{}'::jsonb) where id = 1;
  return jsonb_build_object('ok', true, 'plans', (select count(*) from jsonb_object_keys(coalesce(p_plans, '{}'::jsonb))));
end $$;
create or replace function public.pl_plans() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select plans from hub_private.config where id = 1), '{}'::jsonb) $$;

revoke all on function public.hub_plans(text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.hub_plans(text, jsonb) to anon, authenticated;
revoke all on function public.pl_site_open(text, text), public.pl_set_site_licence(text, text, timestamptz, boolean, text), public.pl_plans() from public, anon;
grant execute on function public.pl_site_open(text, text), public.pl_set_site_licence(text, text, timestamptz, boolean, text), public.pl_plans() to authenticated;
revoke execute on function public.pl_org_locked(text), public.pl_set_licence(text, boolean, timestamptz), public.pl_set_trial(text, timestamptz) from public, anon;
grant execute on function public.pl_org_locked(text), public.pl_set_licence(text, boolean, timestamptz), public.pl_set_trial(text, timestamptz) to authenticated;
